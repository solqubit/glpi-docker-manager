#!/usr/bin/env python3
"""Administration dashboard: grouped actions, live status line and descriptions."""
from datetime import datetime, timezone
import os
from pathlib import Path
import json
import shutil
import sys
from service_view import access_url, records, state
from terminal_ui import Terminal, curses, translations

# Two balanced columns; every action has a menu_* label and a desc_* line.
GROUPS = [
    ('help_group_service', [('status', 'menu_status'), ('start', 'menu_start'),
                            ('stop', 'menu_stop'), ('logs', 'menu_logs')]),
    # Update GLPI also lists newer releases and a refreshed image of the same
    # version; Create backup also offers the final backup for a server move.
    ('dash_group_updates', [('update', 'menu_update'), ('db-update', 'menu_database_update'),
                            ('proxy-update', 'menu_proxy_update')]),
    ('help_group_manager', [('diagnose', 'menu_diagnose'), ('self-update', 'menu_self_update'),
                            ('uninstall', 'menu_uninstall'), ('quit', 'ui_exit')]),
    ('help_group_data', [('backup', 'menu_backup'), ('backups', 'menu_backups'),
                         ('restore', 'menu_restore'), ('schedule', 'menu_schedule'),
                         ('cleanup', 'menu_cleanup')]),
    ('help_group_settings', [('address', 'menu_address'), ('certificates', 'menu_certificates'),
                             ('db-exposure', 'menu_exposure'), ('credentials', 'menu_credentials'),
                             ('language', 'menu_language'), ('agent-setup', 'menu_agent_setup')]),
]
STYLES = {'uninstall': 'warning', 'quit': 'accent'}
# Result of the previous action (Bash menu_done): "level<TAB>text".
NOTICE_STYLES = {'success': ('[+] ', 'ok'), 'warning': ('[!] ', 'warning'), 'error': ('[✗] ', 'error')}


def age(ui, moment):
    minutes = max(0, int((datetime.now(timezone.utc).timestamp() - moment) // 60))
    if minutes >= 2880:
        return ui.t('dash_age_days', minutes // 1440)
    if minutes >= 120:
        return ui.t('dash_age_hours', minutes // 60)
    return ui.t('dash_age_minutes', minutes)


def status_line(ui, config, state_folder):
    """Most important first; the line is truncated to the terminal width."""
    style = 'accent'
    parts = [access_url(config)]
    days = os.environ.get('GDM_DASH_CERT_DAYS', '')
    if config['tls'] == 'off':
        parts.append(ui.t('dash_tls_off'))
    elif days.lstrip('-').isdigit():
        parts.append(ui.t('dash_tls_days', ui.t('ui_tls_short_' + config['tls']), days))
        if int(days) < 30:
            style = 'warning'
    else:
        parts.append(ui.t('dash_tls', ui.t('ui_tls_short_' + config['tls'])))
    parts.append(ui.t('dash_db_public' if config.get('expose_db') else 'dash_db_private'))
    backups = sorted((state_folder / 'backups').glob('glpi-*.tar.gz'), key=lambda p: p.stat().st_mtime)
    if backups:
        if '-auto-' in backups[-1].name:
            origin = 'auto'
        elif '-pre-' in backups[-1].name:
            origin = 'pre'
        else:
            origin = 'manual'
        kind = ui.t('backup_origin_' + origin)
        parts.append(ui.t('dash_backup', age(ui, backups[-1].stat().st_mtime), kind))
    else:
        parts.append(ui.t('dash_backup_none'))
        style = 'warning'
    # Problems go first so they survive truncation: low disk, failed maintenance.
    try:
        usage = shutil.disk_usage(state_folder)
        if usage.free < 5 * 1024 ** 3 or usage.free < usage.total // 10:
            parts.insert(1, ui.t('dash_disk_low', f'{usage.free / 1024 ** 3:.1f}'))
            style = 'warning'
    except OSError:
        pass
    try:
        last = json.loads((state_folder / 'maintenance-last.json').read_text(encoding='utf-8'))
        moment = datetime.fromisoformat(last.get('time', '').replace('Z', '+00:00')).timestamp()
        stale = datetime.now(timezone.utc).timestamp() - moment > 6 * 3600
        if last.get('status') == 'running' and stale:
            parts.insert(1, ui.t('dash_maintenance_failed', age(ui, moment)))
            style = 'warning'
        elif last.get('status') == 'warning':
            parts.insert(1, ui.t('dash_maintenance_warning', age(ui, moment)))
            style = 'warning'
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    updates = os.environ.get('GDM_DASH_UPDATES', '')
    if updates:
        parts.insert(1, ui.t('dash_updates', updates))
        style = 'warning'
    previous = os.environ.get('GDM_DASH_PREVIOUS', '0')
    if previous.isdigit() and int(previous) > 0:
        parts.insert(1, ui.t('dash_previous', previous))
        style = 'warning'
    maintenance = os.environ.get('GDM_DASH_MAINTENANCE', '')
    if maintenance.startswith('on:'):
        parts.append(ui.t('dash_auto_on', maintenance[3:]))
    elif maintenance == 'off':
        parts.append(ui.t('dash_auto_off'))
    elif maintenance == 'missing':
        parts.append(ui.t('dash_maintenance_missing'))
        style = 'warning'
    return ' · '.join(parts), style


def layout(ui, hidden=()):
    """Cells (value, label, column, row) and group headers for the current width."""
    columns = [GROUPS[:3], GROUPS[3:]] if ui.width >= 66 else [GROUPS]
    cells, headers = [], []
    for column, groups in enumerate(columns):
        row = 0
        for title, actions in groups:
            headers.append((column, row, ui.t(title)))
            row += 1
            for value, label in actions:
                if value in hidden:
                    continue
                cells.append(dict(value=value, label=ui.t(label), column=column, row=row))
                row += 1
    return cells, headers, len(columns)


def move(cells, index, step):
    """Next action in the same column (wrapping)."""
    column = [i for i, cell in enumerate(cells) if cell['column'] == cells[index]['column']]
    return column[(column.index(index) + step) % len(column)]


def switch(cells, index, columns):
    """Closest action by row in the neighbouring column."""
    target = (cells[index]['column'] + 1) % columns
    options = [i for i, cell in enumerate(cells) if cell['column'] == target]
    return min(options, key=lambda i: abs(cells[i]['row'] - cells[index]['row'])) if options else index


def dashboard(ui, config, services, state_folder):
    current = state(config, services)
    key = {'running': 'ui_status_running', 'starting': 'ui_status_starting',
           'unhealthy': 'ui_status_unhealthy'}.get(current, 'ui_status_stopped')
    ui.context = f"GLPI {config['glpi_version']} · MySQL {config['mysql_version']} · {ui.t(key)}"
    # Without HTTPS there is no proxy to update.
    hidden = ('proxy-update',) if config.get('tls') == 'off' else ()
    values = [value for _, actions in GROUPS for value, _ in actions if value not in hidden]
    # Back on the action just used, so a repeated task is one Enter away.
    last = os.environ.get('GDM_DASH_LAST', '')
    initial = last if last in values and last != 'quit' else 'start' if current in ('stopped', 'missing') else 'status'
    status, status_style = status_line(ui, config, state_folder)
    level, _, result = os.environ.get('GDM_DASH_NOTICE', '').partition('\t')
    if ui.screen is None:
        rows = [(value, ui.t(title) + ' · ' + ui.t(label), STYLES.get(value, ''))
                for title, actions in GROUPS for value, label in actions if value not in hidden]
        selected = next(i for i, row in enumerate(rows) if row[0] == initial)
        return ui.menu(ui.t('ui_menu_prompt'), rows, selected,
                       notice=(result + ' · ' if result else '') + status) or 'quit'
    selected = None
    while True:
        # The status is truncated to one line, so the width must be known first.
        ui.measure()
        top, height = ui.frame(ui.t('ui_menu_prompt'), status[:ui.width - 4], status_style)
        cells, headers, columns = layout(ui, hidden)
        if selected is None or selected >= len(cells):
            selected = next(i for i, cell in enumerate(cells) if cell['value'] == initial)
        width = ui.width // columns
        visible = max(1, height - top - 3)
        offset = max(0, cells[selected]['row'] - visible + 1)
        for column, row, title in headers:
            if offset <= row < offset + visible:
                ui.put(top + row - offset, ui.left + column * width, ('─ ' + title + ' ').ljust(width - 2, '─'), 'title')
        for index, cell in enumerate(cells):
            if offset <= cell['row'] < offset + visible:
                active = index == selected
                text = ('> ' if active else '  ') + cell['label']
                ui.put(top + cell['row'] - offset, ui.left + cell['column'] * width,
                       text[:width - 2].ljust(width - 2), 'selected' if active else STYLES.get(cell['value'], ''))
        if result:
            # The previous action's result stays until the first key press.
            marker, style = NOTICE_STYLES.get(level, ('[*] ', 'accent'))
            ui.put(height - 2, ui.left, (marker + result)[:ui.width - 2], style)
        else:
            ui.put(height - 2, ui.left, '[*] ' + ui.t('desc_' + cells[selected]['value']), 'dim')
        ui.put(height - 1, ui.left, ui.t('menu_all_options' if columns > 1 else 'menu_keys_single'), 'accent')
        ui.screen.refresh()
        key = ui.key()
        result = ''
        if key in ('\n', '\r', curses.KEY_ENTER): return cells[selected]['value']
        if key == '\x1b': return 'quit'
        if key == curses.KEY_DOWN: selected = move(cells, selected, 1)
        elif key == curses.KEY_UP: selected = move(cells, selected, -1)
        elif key in (curses.KEY_RIGHT, curses.KEY_LEFT): selected = switch(cells, selected, columns)
        elif key == '\t': selected = (selected + 1) % len(cells)
        elif key == curses.KEY_BTAB: selected = (selected - 1) % len(cells)
        elif key == curses.KEY_HOME: selected = 0
        elif key == curses.KEY_END: selected = next(i for i, cell in enumerate(cells) if cell['value'] == 'quit')


def main():
    os.umask(0o077)
    config_path, services_path, language, output = sys.argv[1:]
    config = json.loads(Path(config_path).read_text(encoding='utf-8'))
    services = records(Path(services_path).read_text(encoding='utf-8'))
    ui = Terminal(translations(Path(__file__).resolve().parents[1], language))
    state_folder = Path(config_path).parent.parent
    action = ui.run(lambda: dashboard(ui, config, services, state_folder))
    Path(output).write_text(action + '\n')


if __name__ == '__main__':
    try: main()
    except (KeyboardInterrupt, EOFError): raise SystemExit(130)

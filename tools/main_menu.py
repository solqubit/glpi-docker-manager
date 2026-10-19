#!/usr/bin/env python3
"""All administration actions in a responsive two-column dashboard."""
import json
import os
from pathlib import Path
import sys
from service_view import access_url, records, state
from terminal_ui import Terminal, curses, translations

ACTIONS = [('status', 'menu_status'), ('start', 'menu_start'),
           ('stop', 'menu_stop'), ('logs', 'menu_logs'),
           ('update', 'menu_update'), ('check-updates', 'menu_versions'),
           ('backup', 'menu_backup'), ('restore', 'menu_restore'),
           ('address', 'menu_address'), ('https', 'menu_https'),
           ('db-exposure', 'menu_exposure'), ('credentials', 'menu_credentials'),
           ('transfer', 'menu_transfer'), ('db-update', 'menu_database_update'),
           ('language', 'menu_language'), ('diagnose', 'menu_diagnose'),
           ('refresh-image', 'menu_refresh'), ('recover', 'menu_recover'),
           ('backups', 'menu_backups'), ('quit', 'ui_exit')]


def dashboard(ui, config, services, state_folder):
    current = state(config, services)
    key = {'running': 'ui_status_running', 'starting': 'ui_status_starting',
           'unhealthy': 'ui_status_unhealthy'}.get(current, 'ui_status_stopped')
    ui.context = f"GLPI {config['glpi_version']} · MySQL {config['mysql_version']} · {ui.t(key)}"
    rows = [(action, ui.t(label), '') for action, label in ACTIONS]
    selected = 1 if current in ('stopped', 'missing') else 0
    if ui.screen is None:
        return ui.menu(ui.t('ui_menu_prompt'), rows, selected,
                       notice=ui.t('setup_access', access_url(config))) or 'quit'
    while True:
        top, height = ui.frame(ui.t('ui_menu_prompt'), ui.t('setup_access', access_url(config)))
        columns = 2 if ui.width >= 66 else 1
        visible = max(1, height - top - 6)
        offset = max(0, selected // columns - visible + 1)
        cell = ui.width // columns
        for index, (_, label, _) in enumerate(rows):
            row, column = divmod(index, columns)
            if offset <= row < offset + visible:
                text = ('> ' if index == selected else '  ') + label
                ui.put(top + row - offset, ui.left + column * cell,
                       text[:cell - 1].ljust(cell - 1), 'selected' if index == selected else '')
        ui.put(height - 5, ui.left, ui.t('menu_state_path', str(state_folder)))
        ui.put(height - 4, ui.left, ui.t('menu_backups_path', str(state_folder / 'backups')))
        ui.put(height - 3, ui.left, ui.t('menu_all_options'), 'accent')
        ui.put(height - 1, ui.left, ui.t('setup_keys'), 'accent')
        ui.screen.refresh()
        key = ui.key()
        if key in ('\n', '\r', curses.KEY_ENTER): return rows[selected][0]
        if key == '\x1b': return 'quit'
        if key == curses.KEY_DOWN: selected = (selected + columns) % len(rows)
        elif key == curses.KEY_UP: selected = (selected - columns) % len(rows)
        elif key in (curses.KEY_RIGHT, '\t'): selected = (selected + 1) % len(rows)
        elif key in (curses.KEY_LEFT, curses.KEY_BTAB): selected = (selected - 1) % len(rows)
        elif key == curses.KEY_HOME: selected = 0
        elif key == curses.KEY_END: selected = len(rows) - 1


def main():
    os.umask(0o077)
    config_path, services_path, language, output = sys.argv[1:]
    config = json.loads(Path(config_path).read_text())
    services = records(Path(services_path).read_text())
    ui = Terminal(translations(Path(__file__).resolve().parents[1], language))
    state_folder = Path(config_path).parent.parent
    action = ui.run(lambda: dashboard(ui, config, services, state_folder))
    Path(output).write_text(action + '\n')


if __name__ == '__main__':
    try: main()
    except (KeyboardInterrupt, EOFError): raise SystemExit(130)

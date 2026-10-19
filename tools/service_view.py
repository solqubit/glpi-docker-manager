#!/usr/bin/env python3
"""Human-readable service status and scrollable logs, without environment dumps."""
import json
from pathlib import Path
import re
import sys

from terminal_ui import Terminal, clean, translations


def records(text):
    result = []
    decoder = json.JSONDecoder()
    while text.strip():
        value, offset = decoder.raw_decode(text.lstrip())
        text = text.lstrip()[offset:]
        result.extend(value if isinstance(value, list) else [value])
    return result


def state(config, services):
    by_service = {item.get('Service'): item for item in services}
    expected = ['glpi', 'db'] + (['proxy'] if config['tls'] != 'off' else [])
    if any(name not in by_service for name in expected):
        return 'missing'
    if any(by_service[name].get('State') != 'running' for name in expected):
        return 'stopped'
    if any(by_service[name].get('Health') == 'unhealthy' for name in expected):
        return 'unhealthy'
    if any(by_service[name].get('Health') == 'starting' for name in expected):
        return 'starting'
    return 'running'


def access_url(config):
    secure = config['tls'] != 'off'
    port = config['https_port' if secure else 'http_port']
    suffix = '' if port == (443 if secure else 80) else f':{port}'
    return f"{'https' if secure else 'http'}://{config['hostname']}{suffix}"


def status_rows(config, services, ui):
    by_service = {item.get('Service'): item for item in services}
    rows = [(None, ui.t('setup_access', access_url(config)), 'accent')]
    versions = {'glpi': config['glpi_version'], 'db': config['mysql_version'],
                'proxy': config['caddy_image'].split('@')[0].split(':')[-1]}
    names = {'glpi': 'GLPI', 'db': 'MySQL', 'proxy': 'Caddy / HTTPS'}
    for name in ['glpi', 'db'] + (['proxy'] if config['tls'] != 'off' else []):
        item = by_service.get(name)
        if not item:
            rows.append((None, names[name] + ' · ' + ui.t('ui_service_missing'), 'warning'))
            continue
        active = item.get('State') == 'running'
        health = item.get('Health') or ''
        label = ui.t('ui_status_running' if active else 'ui_status_stopped')
        style = 'warning' if active and health == 'starting' else 'ok' if active and health != 'unhealthy' else 'error'
        marker = '✓' if style == 'ok' else '!'
        rows.append((None, f"{marker} {names[name]} {versions[name]} · {label}", style))
        if health:
            translated = {'healthy': ui.t('ui_health_ok'), 'starting': ui.t('ui_status_starting'),
                          'unhealthy': ui.t('ui_status_unhealthy')}.get(health, health)
            rows.append((None, f"    {ui.t('ui_service_health')}: {translated}", style))
        mappings = []
        for publisher in item.get('Publishers') or []:
            if publisher.get('PublishedPort'):
                mappings.append(f"{publisher['PublishedPort']} → {publisher['TargetPort']}/{publisher.get('Protocol', 'tcp')}")
        if not mappings:
            mappings = [f'{host} → {target}/tcp' for host, target in
                        re.findall(r':([0-9]+)->([0-9]+)/tcp', item.get('Ports', ''))]
        ports = ', '.join(dict.fromkeys(mappings)) or ui.t('ui_service_internal')
        rows.append((None, f"    {ui.t('ui_service_ports')}: {ports}", ''))
    return rows


def main():
    config_path, data_path, language, mode, interactive = sys.argv[1:]
    config = json.loads(Path(config_path).read_text())
    root = Path(__file__).resolve().parents[1]
    ui = Terminal(translations(root, language),
                  f"GLPI {config['glpi_version']} · MySQL {config['mysql_version']}")
    if mode in ('status', 'state'):
        services = records(Path(data_path).read_text())
        if mode == 'state':
            print(state(config, services))
            return 0
        rows = status_rows(config, services, ui)
        title = ui.t('ui_status_details')
    else:
        rows = [(None, clean(line), '') for line in Path(data_path).read_text(errors='replace').splitlines()]
        title = ui.t('ui_logs_details')
    if interactive == 'true' and sys.stdin.isatty() and sys.stdout.isatty():
        ui.run(lambda: ui.menu(title, rows + [('back', ui.t('ui_status_back'), 'accent')],
                              help_text=ui.t('setup_keys')))
    else:
        print(title + '\n')
        for _, label, _ in rows:
            print(label)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (KeyboardInterrupt, EOFError):
        raise SystemExit(130)

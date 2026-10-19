#!/usr/bin/env python3
"""Editable, reversible installation form. Lifecycle commands remain in Bash."""
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sys
import tempfile

from terminal_ui import Terminal, translations

FIELDS = [
    ('hostname', 'setup_host', 'hostname', None),
    ('http_port', 'setup_http', 'port', 80),
    ('https_port', 'setup_https', 'port', 443),
    ('timezone', 'setup_timezone', 'timezone', 'UTC'),
    ('tls', 'setup_tls', 'tls', 'off'),
    ('expose_db', 'setup_exposure', 'exposure', False),
    ('db_name', 'setup_database', 'identifier', 'glpi'),
    ('db_user', 'setup_user', 'db-user', 'glpi'),
    ('db_password', 'ui_app_password', 'secret', ''),
    ('root_password', 'ui_root_password', 'secret', ''),
]


def timezones():
    result = {'UTC'}
    for name in ('zone1970.tab', 'zone.tab'):
        path = Path('/usr/share/zoneinfo') / name
        if path.exists():
            for line in path.read_text().splitlines():
                if line and not line.startswith('#'):
                    result.add(line.split('\t')[2])
    return sorted(result)


def validate(field, value, data):
    if field in ('db_password', 'root_password'):
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            return 'bad_password'
        if field == 'root_password' and any(char in value for char in "'\"\\"):
            return 'bad_root_password'
    elif field in ('http_port', 'https_port'):
        if not re.fullmatch(r'[0-9]{1,5}', value) or not 1 <= int(value) <= 65535:
            return 'ui_bad_port'
        other = 'https_port' if field == 'http_port' else 'http_port'
        if int(value) == int(data[other]) or (data['expose_db'] and int(value) == 3306):
            return 'setup_port_conflict'
    elif field in ('db_name', 'db_user'):
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,31}', value):
            return 'ui_bad_identifier'
        if field == 'db_user' and value == 'root':
            return 'ui_bad_db-user'
    elif field == 'hostname':
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', value):
            return 'ui_bad_hostname'
        if re.fullmatch(r'[0-9.]+', value):
            try:
                ipaddress.IPv4Address(value)
            except ValueError:
                return 'ui_bad_hostname'
        if data['tls'] == 'acme' and ('.' not in value or
                re.fullmatch(r'[0-9.]+', value) or value.endswith(('.local', '.localhost'))):
            return 'setup_public_domain'
    elif field == 'timezone':
        path = Path('/usr/share/zoneinfo') / value
        if '..' in value or not path.is_file():
            return 'ui_bad_timezone'
    return ''


def form_errors(data):
    errors = []
    for field, label, _, _ in FIELDS:
        if field.endswith('password') and not data.get(field):
            errors.append((field, label, 'setup_password_required'))
        else:
            error = validate(field, str(data[field]), data)
            if error:
                errors.append((field, label, error))
    if data['tls'] == 'acme' and (data['http_port'], data['https_port']) != (80, 443):
        errors.append(('tls', 'setup_tls', 'acme_ports'))
    return errors


def port_errors(data):
    ports = [data['http_port']]
    if data['tls'] != 'off':
        ports.append(data['https_port'])
    if data['expose_db']:
        ports.append(3306)
    for port in ports:
        if port in data.get('_active_ports', []):
            continue
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.bind(('0.0.0.0', port))
        except OSError:
            return port
    return None


class Setup:
    def __init__(self, path, messages):
        self.path = path
        self.data = json.loads(path.read_text())
        self.access_only = self.data.get('_access_only', False)
        self.fields = FIELDS[:6] if self.access_only else FIELDS
        self.ui = Terminal(messages, self.context())
        self.selected = 0
        self.notice = self.data.pop('_notice', '') or self.ui.t('setup_access_intro' if self.access_only else 'setup_intro')
        self.notice_style = 'accent'
        self.defaults = {'hostname': self.data.get('_detected_host', 'localhost')}
        self.defaults.update({key: default for key, _, _, default in FIELDS if default is not None})

    def context(self):
        return f"GLPI {self.data['glpi_version']} · MySQL {self.data['mysql_version']} · db:3306"

    def save(self):
        handle, temporary = tempfile.mkstemp(prefix='.setup-', dir=self.path.parent)
        try:
            with os.fdopen(handle, 'w') as stream:
                json.dump(self.data, stream, ensure_ascii=False)
                stream.write('\n')
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def display(self, key):
        value = self.data[key]
        if key.endswith('password'):
            return self.ui.t('setup_secret_set' if value else 'setup_secret_empty')
        if key == 'tls':
            return self.ui.t('ui_tls_' + value)
        if key == 'expose_db':
            return self.ui.t('ui_db_public' if value else 'ui_db_private')
        return str(value)

    def rows(self):
        rows = []
        for key, label, _, _ in self.fields:
            pending = key.endswith('password') and not self.data[key]
            invalid = bool(validate(key, str(self.data[key]), self.data))
            default = not pending and not key.endswith('password') and self.data[key] == self.defaults[key]
            state = self.ui.t('setup_pending' if pending else 'setup_invalid' if invalid else 'setup_default' if default else 'setup_valid')
            marker = '!' if pending or invalid else '✓'
            value = self.display(key)
            # Keep the state before long values so it remains visible on narrow terminals.
            rows.append((key, f'{marker} {self.ui.t(label).split(" · ")[0]} [{state}]  {value}',
                         'warning' if pending else 'error' if invalid else 'ok'))
        rows += [('review', self.ui.t('setup_continue'), 'accent')]
        if not self.access_only:
            rows.append(('version', self.ui.t('setup_version_back'), ''))
        rows += [('ports-default', self.ui.t('setup_standard_ports'), ''),
                 ('cancel', self.ui.t('setup_cancel'), '')]
        return rows

    def timezone(self):
        zones = timezones()
        while True:
            areas = sorted({zone.split('/')[0] for zone in zones if '/' in zone})
            area = self.ui.menu(self.ui.t('setup_timezone_area'),
                                [('UTC', 'UTC', 'accent')] + [(a, a, '') for a in areas],
                                search=True, help_text=self.ui.t('setup_timezone_help'))
            if area is None or area == 'UTC':
                return area
            choices = [(zone, zone, '') for zone in zones if zone.startswith(area + '/')]
            current = next((i for i, row in enumerate(choices) if row[0] == self.data['timezone']), 0)
            zone = self.ui.menu(self.ui.t('setup_timezone_city'), choices, current,
                                search=True, help_text=self.ui.t('setup_timezone_help'))
            if zone is not None:
                return zone

    def edit(self, key):
        field = next(row for row in self.fields if row[0] == key)
        _, label, kind, _ = field
        value = None
        if kind == 'timezone':
            value = self.timezone()
        elif kind == 'tls':
            values = ['off', 'self-signed', 'acme', 'custom']
            value = self.ui.menu(self.ui.t('setup_tls'),
                                 [(v, self.ui.t('ui_tls_' + v), '') for v in values],
                                 values.index(self.data[key]), help_text=self.ui.t('setup_tls_help'))
            if value == 'acme':
                self.data['http_port'], self.data['https_port'] = 80, 443
        elif kind == 'exposure':
            value = self.ui.menu(self.ui.t('expose_prompt'),
                                 [(False, self.ui.t('ui_db_expose_no'), 'ok'),
                                  (True, self.ui.t('ui_db_expose_yes'), 'warning')],
                                 int(self.data[key]), notice=self.ui.t('ui_db_access_body'),
                                 help_text=self.ui.t('ui_db_access_later'))
        else:
            def validator(text):
                error = validate(key, text, self.data)
                return self.ui.t(error) if error else ''
            hint = self.ui.t('password_prompt' if kind == 'secret' else 'setup_edit_hint')
            if key == 'hostname':
                hint = self.ui.t('setup_network_hint', self.data.get('_detected_host', 'localhost'))
            value = self.ui.edit(self.ui.t(label), self.data[key], hint, validator, kind == 'secret')
            if value is not None:
                if kind == 'port':
                    value = int(value)
                elif kind == 'secret' and not value:
                    value = secrets.token_hex(24)
        if value is not None:
            self.data[key] = value
            self.save()
            self.notice = self.ui.t('setup_saved', self.ui.t(label).split(' · ')[0])
            self.notice_style = 'ok'
            if key == 'tls' and value == 'custom':
                folder = Path(self.data['cert_dir']) / 'custom'
                self.notice = self.ui.t('cert_instructions', str(folder / 'fullchain.pem'), str(folder / 'privkey.pem'))
                self.notice_style = 'warning'

    def ready(self):
        errors = form_errors(self.data)
        if errors:
            key, label, error = errors[0]
            self.selected = next((i for i, row in enumerate(self.fields) if row[0] == key), 0)
            self.notice = self.ui.t(label).split(' · ')[0] + ': ' + self.ui.t(error)
            self.notice_style = 'error'
            return False
        busy = port_errors(self.data)
        if busy:
            self.notice = self.ui.t('port_busy', busy)
            self.notice_style = 'error'
            return False
        if self.data['tls'] == 'custom':
            folder = Path(self.data['cert_dir']) / 'custom'
            if not all((folder / filename).is_file() for filename in ('fullchain.pem', 'privkey.pem')):
                self.notice = self.ui.t('cert_instructions', str(folder / 'fullchain.pem'), str(folder / 'privkey.pem'))
                self.notice_style = 'error'
                self.selected = 4
                return False
        return True

    def review(self):
        secure = self.data['tls'] != 'off'
        port = self.data['https_port' if secure else 'http_port']
        suffix = '' if port == (443 if secure else 80) else f':{port}'
        url = f"{'https' if secure else 'http'}://{self.data['hostname']}{suffix}"
        details = [f'GLPI {self.data["glpi_version"]} / MySQL {self.data["mysql_version"]}',
                   self.ui.t('setup_access', url)]
        for key, label, _, _ in self.fields:
            details.append(self.ui.t(label).split(' · ')[0] + ': ' + self.display(key))
        rows = [('deploy', self.ui.t('setup_apply' if self.access_only else 'setup_deploy'), 'ok'),
                ('edit', self.ui.t('setup_return_edit'), 'accent')]
        if not self.access_only:
            rows.append(('version', self.ui.t('setup_version_back'), ''))
        rows.append(('cancel', self.ui.t('setup_cancel'), ''))
        # The review is scrollable; selecting any data row returns to that field.
        rows = [(key, line, '') for key, line in zip(['edit', 'hostname'] + [f[0] for f in self.fields], details)] + rows
        choice = self.ui.menu(self.ui.t('ui_summary'), rows, len(details),
                              notice=self.ui.t('setup_access', url) + ' · ' + self.ui.t('setup_access_review_hint' if self.access_only else 'setup_review_hint'),
                              help_text=self.ui.t('setup_access_review_keys' if self.access_only else 'setup_review_keys'))
        if choice in {f[0] for f in self.fields}:
            self.selected = next(i for i, row in enumerate(self.fields) if row[0] == choice)
            return 'edit'
        return choice or 'edit'

    def run(self):
        while True:
            rows = self.rows()
            choice = self.ui.menu(self.ui.t('setup_access_title' if self.access_only else 'setup_title'), rows, self.selected,
                                  notice=self.notice, notice_style=self.notice_style,
                                  help_text=self.ui.t('setup_form_help'))
            if choice is None or choice == 'cancel':
                decision = self.ui.menu(self.ui.t('setup_cancel_confirm'),
                                        [('stay', self.ui.t('setup_return_edit'), 'accent'),
                                         ('cancel', self.ui.t('setup_cancel'), 'warning')])
                if decision == 'cancel':
                    return 10
                continue
            if choice == 'version':
                self.save()
                return 20
            if choice == 'ports-default':
                self.data['http_port'], self.data['https_port'] = 80, 443
                self.save()
                self.notice = self.ui.t('setup_standard_ports')
                self.notice_style = 'ok'
                continue
            if choice == 'review':
                if self.ready():
                    decision = self.review()
                    if decision == 'deploy' and self.ready():
                        self.save()
                        return 0
                    if decision == 'version':
                        return 20
                    if decision == 'cancel':
                        return 10
                continue
            self.selected = next(i for i, row in enumerate(self.fields) if row[0] == choice)
            self.edit(choice)


def main():
    os.umask(0o077)
    path = Path(sys.argv[1])
    language = sys.argv[2]
    root = Path(__file__).resolve().parents[1]
    setup = Setup(path, translations(root, language))
    return setup.ui.run(setup.run)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (KeyboardInterrupt, EOFError):
        raise SystemExit(130)

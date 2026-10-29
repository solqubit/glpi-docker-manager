#!/usr/bin/env python3
"""Validate the editable form's boundaries and secret-free presentation."""
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
from unittest.mock import Mock

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
from setup import Setup, form_errors, port_errors, timezones, validate
from service_view import access_url, records, state, status_rows
from terminal_ui import Terminal, clean, translations
from main_menu import status_line

data = dict(hostname='192.168.0.33', http_port=80, https_port=443, timezone='UTC',
            tls='off', expose_db=False, db_name='glpi', db_user='glpi',
            db_password='abc', root_password='1', glpi_version='11.0.10',
            mysql_version='8.4.11', caddy_image='caddy:2.11.1@sha256:fixture',
            cert_dir='/opt/glpi-docker-manager/certs')
assert not form_errors(data)
assert validate('http_port', '443', data)
assert validate('http_port', '65536', data)
assert validate('hostname', '999.2.3.4', data)
assert validate('root_password', "quote'", data)
assert not validate('db_password', "quote'", data)
assert validate('db_password', 'line\nfeed', data)
assert validate('timezone', '../../etc/passwd', data)
assert not validate('timezone', 'America/Guayaquil', data)
assert 'America/Guayaquil' in timezones()
assert validate('hostname', '192.168.0.33', dict(data, tls='acme'))
assert access_url(data) == 'http://192.168.0.33'
assert access_url(dict(data, tls='self-signed')) == 'https://192.168.0.33'
assert access_url(dict(data, tls='self-signed', https_port=8443)).endswith(':8443')
with socket.socket() as listener:
    listener.bind(('0.0.0.0', 0)); listener.listen()
    assert port_errors(dict(data, http_port=listener.getsockname()[1])) == listener.getsockname()[1]
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'draft.json'
    path.write_text(json.dumps(data))
    form = Setup(path, translations(root, 'es'))
    assert 'abc' not in repr(form.rows())
    assert form.display('db_password') == form.ui.t('setup_secret_set')
    with socket.socket() as listener:
        listener.bind(('0.0.0.0', 0)); listener.listen()
        form.data['http_port'] = listener.getsockname()[1]
        assert not form.ready()
        row = next(row for row in form.rows() if row[0] == 'http_port')
        assert row[2] == 'error' and '[✗]' in row[1][0][0]
    assert form.ready() and not form.invalid_field
    form.data['http_port'] = data['http_port']
    form.data['timezone'] = 'America/Guayaquil'; form.save()
    assert json.loads(path.read_text())['timezone'] == 'America/Guayaquil'
    assert path.stat().st_mode & 0o077 == 0
    plain = subprocess.run([sys.executable, str(root / 'tools/setup.py'), str(path), 'en'],
                           input='14\n2\n', capture_output=True, text=True)
    assert plain.returncode == 10, plain.stderr
    assert 'abc' not in plain.stdout + plain.stderr
    form.data['db_password'] = ''
    assert form_errors(form.data)
services = records('[{"Service":"glpi","State":"running","Health":"healthy"}]\n'
                   '{"Service":"db","State":"running","Health":"healthy"}')
assert state(data, services) == 'running'
assert state(dict(data, tls='self-signed'), services) == 'missing'
services[0]['State'] = 'exited'
assert state(data, services) == 'stopped'
ui = Terminal(translations(root, 'es'))
assert 'sha256' not in repr(status_rows(data, services, ui))
assert 'abc' not in repr(status_rows(data, services, ui))
assert clean('\x1b[31mtest\x1b[0m') == 'test'
# Optional help must also work in a rendered menu, and choosing False must not
# be confused with cancellation (None).
menu = Terminal(translations(root, 'en'))
menu.screen = Mock()
menu.screen.getmaxyx.return_value = (24, 80)
menu.left, menu.width = 2, 72
menu.frame = Mock(return_value=(4, 24))
menu.put = Mock()
menu.draw_label = Mock()
menu.key = Mock(return_value='\n')
assert menu.menu('MySQL', [(False, 'Private', 'ok')], help_text=None) is False
with tempfile.TemporaryDirectory() as directory:
    folder = Path(directory)
    (folder / 'backups').mkdir()
    for language in ('en', 'es'):
        ui = Terminal(translations(root, language))
        for tag, origin in (('', 'manual'), ('auto-', 'auto'), ('pre-', 'pre')):
            archive = folder / 'backups' / f'glpi-11.0.11-20261019T000000-{tag}abc123.tar.gz'
            archive.touch()
            line, _ = status_line(ui, data, folder)
            assert '(' + ui.t('backup_origin_' + origin) + ')' in line, line
            archive.unlink()
print('PASS: editable settings validation, time zones, secret privacy, ports, URLs and service states')

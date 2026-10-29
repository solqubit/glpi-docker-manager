#!/usr/bin/env python3
"""Drive actual curses forms through a controlling terminal; inspect saved results."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[1]
down = b'\x1b[B'
home = b'\x1b[H'
end = b'\x1b[F'


def drive(script, arguments, keys, expected_code=0, extra_env=None):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    before = termios.tcgetattr(slave)
    def session():
        os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    environment = dict(os.environ, TERM='xterm-256color', LC_ALL='C.UTF-8')
    if extra_env: environment.update(extra_env)
    process = subprocess.Popen(['python3', str(root / 'tools' / script)] + arguments,
                               stdin=slave, stdout=slave, stderr=slave,
                               preexec_fn=session, env=environment)
    captured = bytearray()
    try:
        deadline = time.monotonic() + 15
        while b'GLPI Docker Manager' not in captured and process.poll() is None:
            assert time.monotonic() < deadline
            if select.select([master], [], [], .1)[0]: captured.extend(os.read(master, 65536))
        # A short human-like delay lets each modal complete its terminal update.
        for key in keys:
            time.sleep(.08)
            os.write(master, key)
            while select.select([master], [], [], 0)[0]: captured.extend(os.read(master, 65536))
        while process.poll() is None:
            assert time.monotonic() < deadline, captured.decode(errors='replace')[-3000:]
            if select.select([master], [], [], .1)[0]: captured.extend(os.read(master, 65536))
        while select.select([master], [], [], 0)[0]: captured.extend(os.read(master, 65536))
        assert process.returncode == expected_code, captured.decode(errors='replace')[-3000:]
        assert termios.tcgetattr(slave) == before, 'Terminal settings were not restored'
        return bytes(captured)
    finally:
        if process.poll() is None: process.kill(); process.wait()
        os.close(master); os.close(slave)


with tempfile.TemporaryDirectory() as directory:
    folder = Path(directory)
    data = dict(hostname='192.0.2.30', _detected_host='192.0.2.30', http_port=80,
                https_port=443, timezone='UTC', tls='off', expose_db=False,
                db_name='glpi', db_user='glpi', db_password='', root_password='',
                glpi_version='11.0.10', mysql_version='8.4.11',
                caddy_image='caddy:2.11.1@sha256:fixture', cert_dir=str(folder / 'certs'))
    draft = folder / 'draft.json'
    draft.write_text(json.dumps(data))
    output = drive('setup.py', [str(draft), 'es'], [
        down * 3 + b'\n', b'America\n', b'Guayaquil\n',
        down + b'\n', down + b'\n',
        down * 4 + b'\n', b'abc\n', down + b'\n', b'1\n',
        down + b'\n', down + b'\n',
        home + down + b'\n', b'\x1518081\n',
        home + down * 10 + b'\n', b'\n'])
    saved = json.loads(draft.read_text())
    assert saved['timezone'] == 'America/Guayaquil' and saved['http_port'] == 18081
    assert saved['tls'] == 'self-signed' and saved['db_password'] == 'abc' and saved['root_password'] == '1'
    assert draft.stat().st_mode & 0o077 == 0
    assert 'por defecto'.encode() in output and 'pendiente'.encode() in output
    draft.write_text(json.dumps(data))
    drive('setup.py', [str(draft), 'en'], [down + b'\n', b'\x150\n', b'\x1b',
                                         b'\x1b', down + b'\n'], expected_code=10)
    assert json.loads(draft.read_text())['http_port'] == 80
    drive('setup.py', [str(draft), 'es'], [home + down * 11 + b'\n'],
          expected_code=20, extra_env={'NO_COLOR': '1'})
    data['db_password'] = 'abc'; data['root_password'] = '1'
    draft.write_text(json.dumps(data))
    # Installed access settings: edit MySQL exposure in its nested selector,
    # reverse the change, cancel the selector and leave without applying.
    access_draft = folder / 'access.json'
    for language in ('es', 'en'):
        access_data = dict(data, _access_only=True)
        access_draft.write_text(json.dumps(access_data))
        exposure = drive('setup.py', [str(access_draft), language], [
            home + down * 5 + b'\n', down + b'\n',
            b'\n', home + b'\n', b'\n', b'\x1b', b'\x1b'], expected_code=10)
        assert b'Traceback' not in exposure
        saved_access = json.loads(access_draft.read_text())
        for key in ('expose_db', 'hostname', 'http_port', 'https_port', 'db_password', 'root_password'):
            assert saved_access[key] == access_data[key], key
    services = folder / 'services.json'
    services.write_text(json.dumps([{'Service': name, 'State': 'running', 'Health': 'healthy'}
                                    for name in ('glpi', 'db')]))
    action = folder / 'action'
    dashboard = drive('main_menu.py', [str(draft), str(services), 'es', str(action)], [end + b'\n'])
    assert action.read_text().strip() == 'quit'
    for label in ('Actualizar GLPI', 'Restaurar un respaldo', 'Cambiar idioma', 'Administrar respaldos',
                  'Liberar espacio', 'HTTPS y certificados'):
        assert label.encode() in dashboard, label
    drive('service_view.py', [str(draft), str(services), 'es', 'status', 'true'], [b'\n'])
    archive = folder / 'glpi-11.0.10-20261019T000000-abc.tar.gz'
    archive.write_bytes(b'fixture selected before actual archive validation')
    selection = folder / 'selected'
    drive('backup_picker.py', [str(folder), 'es', str(selection)], [b'\n'])
    assert selection.read_text().strip() == str(archive)
    from test_backups import make_backup
    state = folder / 'managed'
    selected_backup = make_backup(state / 'backups', origin='update')
    import sys
    sys.path.insert(0, str(root / 'tools'))
    import backup_ops
    backup_ops.inspect(state, selected_backup, verify=True)
    drive('backup_manager.py', [str(state), 'es', str(action)], [b'\n'])
    assert json.loads(action.read_text())['action'] == 'inspect'
    drive('backup_manager.py', [str(state), 'es', str(action), str(selected_backup)], [b'\n'])
    assert json.loads(action.read_text())['action'] == 'verify'
    drive('backup_manager.py', [str(state), 'es', str(action), str(selected_backup)],
          [down * 3 + b'\n', b'\x1b', b'\x1b', b'\x1b'])
    assert json.loads(action.read_text())['action'] == 'back' and selected_backup.exists()
    drive('backup_manager.py', [str(state), 'es', str(action), str(selected_backup)],
          [down * 3 + b'\n', b'DELETE\n'])
    assert json.loads(action.read_text())['action'] == 'delete' and selected_backup.exists()
print('PASS: real editable form, region/city selection, review Back, cancel, version Back, dashboard and backup picker')

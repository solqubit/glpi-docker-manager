#!/usr/bin/env python3
"""Opt-in first-run keyboard wizard with disposable real Docker resources."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import termios
import time
import uuid

if os.environ.get('GDM_INTEGRATION') != '1':
    raise SystemExit('Set GDM_INTEGRATION=1 to authorize the Docker wizard test')
root = Path(__file__).resolve().parents[1]
defaults = os.environ.get('GDM_WIZARD_DEFAULTS') == '1'
http_port, https_port = (80, 443) if defaults else (18081, 18444)
state = root / 'tests/.runtime' / ('wizard-' + uuid.uuid4().hex)
state.mkdir(mode=0o700, parents=True)
test_projects = []
environment = dict(os.environ, GDM_CERT_DIR=str(state / 'certs'),
                   TERM='xterm-256color', LC_ALL='C.UTF-8')
command = ['bash', str(root / 'start.sh'), '--lang', 'es', '--state-dir', str(state)]
locale = dict(line.split('\t', 1) for line in (root / 'locales/es.tsv').read_text().splitlines())


def drive(arguments, events, log_name):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    def session():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    process = subprocess.Popen(command + arguments, stdin=slave, stdout=slave,
                               stderr=slave, env=environment, preexec_fn=session)
    os.close(slave)
    captured = bytearray()
    event_index = offset = 0
    deadline = time.monotonic() + 600
    try:
        while process.poll() is None:
            if time.monotonic() > deadline:
                raise TimeoutError('Wizard timeout at event ' + str(event_index))
            if select.select([master], [], [], 0.1)[0]:
                try:
                    captured.extend(os.read(master, 65536))
                except OSError:
                    break
            if event_index < len(events):
                key, answer = events[event_index]
                needle = locale[key].split(' [')[0][:36].encode()
                found = captured.find(needle, offset)
                if found >= 0:
                    offset = found + len(needle)
                    for stroke in answer if isinstance(answer, list) else [answer]:
                        time.sleep(0.12)
                        os.write(master, stroke)
                        while select.select([master], [], [], 0)[0]:
                            captured.extend(os.read(master, 65536))
                    event_index += 1
        process.wait(timeout=30)
        while select.select([master], [], [], 0)[0]:
            try:
                captured.extend(os.read(master, 65536))
            except OSError:
                break
        log = state / log_name
        log.write_bytes(captured)
        log.chmod(0o600)
        assert process.returncode == 0, captured[-6000:].decode(errors='replace')
        assert event_index == len(events), (event_index, len(events), captured[-3000:])
        return captured
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=30)
        os.close(master)


down, home = b'\x1b[B', b'\x1b[H'
form_keys = ([] if defaults else [
    home + down + b'\n', b'\x15' + str(http_port).encode() + b'\n',
    down + b'\n', b'\x15' + str(https_port).encode() + b'\n',
    home + down * 6 + b'\n', b'\x15glpi_wizard\n',
]) + [
    home + down * 4 + b'\n', down + b'\n',
    home + down * 8 + b'\n', b'abc\n', down + b'\n', b'1\n',
    down + b'\n', down + b'\n',  # review, then Back to the editable form
    home + down * 10 + b'\n', b'\n',
]

try:
    output = drive([], [
        ('first_action', b'\n'),
        ('major_prompt', down + b'\n'),
        ('choose_version', b'\n'),
        ('ui_release_prompt', b'\n'),
        ('setup_title', form_keys),
        ('ui_continue', b'\n'),
        ('ui_menu_prompt', b'\x1b[F\n'),
    ], 'wizard.log')
    config = json.loads((state / 'current/config.json').read_text())
    test_projects.append(config['project'])
    assert config['status'] == 'ready' and config['language'] == 'es'
    assert config['db_name'] == ('glpi' if defaults else 'glpi_wizard') and config['tls'] == 'self-signed'
    assert config['db_user'] == 'glpi'
    assert config['http_port'] == http_port and config['https_port'] == https_port
    assert config['db_password'] == 'abc' and config['root_password'] == '1'
    assert 'mode' not in config
    assert config['storage'] == 'directory' and config['cert_dir'] == str(state / 'certs')
    assert (state / 'manager/start.sh').is_file() and (state / 'start.sh').is_file()
    for role in ('glpi_data', 'db_data'):
        directory = state / 'data' / config['id'] / role
        assert directory.is_dir()
        device = subprocess.check_output(['docker', 'volume', 'inspect', '--format',
                                           '{{index .Options "device"}}', config['project'] + '_' + role]).decode().strip()
        assert device == str(directory), (role, device)
    assert ('[+] ' + locale['ui_install_success'].removeprefix('✓ ')).encode() in output
    url = 'https://' + config['hostname'] + ('' if https_port == 443 else ':' + str(https_port))
    assert config['hostname'] != 'localhost', 'LAN address was not detected'
    assert b'[8/8]' in output and url.encode() in output
    assert b'\x1b[?1049h' in output, 'The editable terminal UI was not used'
    dotenv = (state / 'current/.env').read_text()
    assert 'GLPI_DB_HOST="db"' in dotenv and 'GLPI_DB_PORT="3306"' in dotenv
    assert 'GLPI_DB_NAME="' + config['db_name'] + '"' in dotenv
    assert 'GLPI_DB_USER="glpi"' in dotenv
    assert locale['recovery_notice'].split('%s')[0].encode() not in output
    assert not list(state.glob('.password.*')), 'Temporary secrets were not cleaned up'
    before = hashlib.sha256((state / 'current/config.json').read_bytes()).digest()
    repeat = subprocess.run(command + ['install', config['glpi_version']], capture_output=True, env=environment)
    assert repeat.returncode != 0
    assert hashlib.sha256((state / 'current/config.json').read_bytes()).digest() == before
    status = subprocess.run(command + ['status'], capture_output=True, env=environment)
    assert status.returncode == 0, status.stderr
    assert b'sha256:' not in status.stdout
    assert config['db_password'].encode() not in status.stdout
    probe = os.environ.get('GDM_PROBE_HOST', '127.0.0.1')
    # An IP-literal TLS URL sends no SNI. Trust the generated IP SAN certificate.
    response = subprocess.check_output([
        'curl', '--fail', '--silent', '--show-error', '--noproxy', '*',
        '--cacert', str(state / 'current/tls/fullchain.pem'),
        '--connect-to', f"{config['hostname']}:{https_port}:{probe}:{https_port}",
        '--output', '/dev/null', '--write-out', '%{http_code}', url + '/'])
    assert response.decode() in ('200', '301', '302', '303'), response
    headers = subprocess.check_output([
        'curl', '--silent', '--show-error', '--noproxy', '*', '--head',
        '--connect-to', f"{config['hostname']}:{http_port}:{probe}:{http_port}",
        f"http://{config['hostname']}:{http_port}/"])
    assert ('location: ' + url + '/').encode() in headers.lower(), headers
    print('PASS: first-run Spanish arrow-key wizard, typed fields, review, eight stages and verified success screen')
    print('PASS: short manual credentials, ' + ('default' if defaults else 'custom') +
          ' settings, fixed pages, self-signed HTTPS and idempotent repeat')
    print('PASS: detected LAN IP, trusted HTTPS without SNI, correct HTTP redirect and compact status')
    print('PASS: manager code, credentials, certificates and actual GLPI/MySQL data are inside one root')
    subprocess.run(['docker', 'exec', config['project'] + '-glpi-1', 'sh', '-c',
                    'printf before-backup > /var/glpi/files/gdm-wizard-marker'], check=True)

    drive(['transfer'], [('transfer_confirm', b'\x1b[A\n')], 'transfer.log')
    for service, expected in (('glpi', False), ('proxy', False), ('db', True)):
        running = subprocess.check_output([
            'docker', 'inspect', '--format', '{{.State.Running}}',
            config['project'] + '-' + service + '-1']).decode().strip()
        assert running == str(expected).lower(), (service, running)
    archives = list((state / 'backups').glob('glpi-*.tar.gz'))
    assert len(archives) == 1
    subprocess.run(['python3', str(root / 'tools/archive.py'), 'extract',
                    str(archives[0]), str(state / 'verified-transfer')], check=True)
    resumed = subprocess.run(command + ['start'], capture_output=True, env=environment)
    assert resumed.returncode == 0, resumed.stderr[-4000:]
    print('PASS: keyboard-confirmed transfer, verified archive and explicit restart')
    if os.environ.get('GDM_WIZARD_EXTENDED') == '1':
        drive(['address'], [('setup_access_title', [
            home + down * 3 + b'\n', b'America\n', b'Guayaquil\n',
            home + down * 6 + b'\n', b'\n'])], 'address.log')
        changed = json.loads((state / 'current/config.json').read_text())
        assert changed['timezone'] == 'America/Guayaquil'
        assert changed['project'] == config['project']
        assert changed['db_password'] == config['db_password']
        subprocess.run(['docker', 'exec', config['project'] + '-glpi-1', 'sh', '-c',
                        'printf after-backup > /var/glpi/files/gdm-wizard-marker'], check=True)
        drive(['restore'], [('backup_pick_prompt', b'\n'), ('destructive', b'RESTORE\n')], 'restore.log')
        restored = json.loads((state / 'current/config.json').read_text())
        test_projects.append(restored['project'])
        assert restored['project'] != config['project'] and restored['status'] == 'ready'
        assert restored['timezone'] == 'UTC'
        marker = subprocess.check_output(['docker', 'exec', restored['project'] + '-glpi-1',
                                          'cat', '/var/glpi/files/gdm-wizard-marker'])
        assert marker == b'before-backup'
        subprocess.run(['docker', 'volume', 'inspect', config['project'] + '_glpi_data'],
                       check=True, stdout=subprocess.DEVNULL)
        print('PASS: existing-installation access editor, backup picker, typed RESTORE and fresh-volume recovery')
    print('Private evidence:', state)
finally:
    if (state / 'current/config.json').exists():
        config = json.loads((state / 'current/config.json').read_text())
        test_projects.append(config['project'])
    for project in set(test_projects):
        for resource, command_parts in (
            ('container', ['docker', 'ps', '-aq']),
            ('network', ['docker', 'network', 'ls', '-q']),
        ):
            ids = subprocess.check_output(command_parts + ['--filter', 'label=com.docker.compose.project=' + project]).decode().split()
            if ids:
                subprocess.run(['docker', resource, 'rm'] + (['-f'] if resource == 'container' else []) + ids, check=True, stdout=subprocess.DEVNULL)
        for role in ('glpi_data', 'db_data', 'plugins', 'marketplace', 'caddy_data', 'caddy_config'):
            subprocess.run(['docker', 'volume', 'rm', project + '_' + role], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

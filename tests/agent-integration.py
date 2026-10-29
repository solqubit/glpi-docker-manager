#!/usr/bin/env python3
"""Opt-in Linux agent bootstrap against real disposable GLPI/MySQL containers.

Run on a Docker host (also works with Docker Desktop):
  GDM_AGENT_INTEGRATION=1 python3 tests/agent-integration.py
Only uniquely named containers/network created here are removed. Logs stay in
ignored tests/.runtime/. No socket, host filesystem or privileged mode on clients.
"""
import os
from pathlib import Path
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
if os.environ.get('GDM_AGENT_INTEGRATION') != '1':
    raise SystemExit('Set GDM_AGENT_INTEGRATION=1 to run disposable agent tests.')
PREFIX = 'gdm_agent_' + uuid.uuid4().hex[:10]
FOLDER = ROOT / 'tests' / '.runtime' / PREFIX
FOLDER.mkdir(parents=True)
LOG = FOLDER / 'results.log'
CONTAINERS = []
GLPI = os.environ.get('GDM_AGENT_TEST_GLPI', 'glpi/glpi:11.0.11')
MYSQL = os.environ.get('GDM_AGENT_TEST_MYSQL', 'mysql:8.4.13')
CADDY = os.environ.get('GDM_AGENT_TEST_CADDY', 'caddy:2.11.7')


def run(*args, check=True, timeout=600):
    result = subprocess.run(['docker', *map(str, args)], text=True, encoding='utf-8',
                            errors='replace', stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    with LOG.open('a', encoding='utf-8') as out:
        out.write('docker ' + ' '.join(map(str, args)) + '\n' + result.stdout + '\n')
    if check and result.returncode:
        raise RuntimeError(result.stdout[-9000:])
    return result


def start(role, image, *options, command=()):
    name = PREFIX + '_' + role
    CONTAINERS.append(name)
    run('run', '-d', '--name', name, '--network', PREFIX, *options, image, *command)
    return name


def bind(path, target):
    return ('--mount', f'type=bind,source={path},target={target},readonly')


def render():
    script = r'''
set -Eeuo pipefail
export GDM_ROOT=/workspace GDM_STATE_DIR=/work
for module in core system config tls; do source "$GDM_ROOT/lib/$module.sh"; done
source "$GDM_ROOT/tests/helpers.sh"
tr_load
test_config /work/base.json
mkdir -p /work/revisions
for mode in off self-signed custom acme; do
    host=gdm-agent.test; [[ $mode != off ]] || host=glpi
    [[ $mode != acme ]] || host=glpi.example.com
    jq --arg mode "$mode" --arg host "$host" '.agent_enabled=true | .tls=$mode | .hostname=$host |
        .http_port=80 | .https_port=443' /work/base.json > /work/input.json
    if [[ $mode == custom ]]; then
        mkdir -p "$CERT_ROOT/custom"
        cp "$CERT_ROOT/self-signed/fullchain.pem" "$CERT_ROOT/self-signed/privkey.pem" "$CERT_ROOT/custom/"
        cp "$CERT_ROOT/self-signed/ca/gdm-ca.pem" "$CERT_ROOT/custom/agent-ca.pem"
    fi
    config_render /work/input.json "/work/revisions/$mode"
    tls_prepare /work/input.json "/work/revisions/$mode"
    agent_prepare /work/input.json "/work/revisions/$mode"
    ln -sfn "revisions/$mode" /work/current
    CONFIG=/work/current/config.json; cfg_cache
    agent_command --once > "/work/$mode-command.sh"
    agent_command '' > "/work/$mode-service-command.sh"
done
'''
    run('run', '--rm', *bind(ROOT, '/workspace'), '--mount',
        f'type=bind,source={FOLDER},target=/work', 'gdm-tests', 'bash', '-c', script)


def sql(statement):
    return run('exec', '-e', 'MYSQL_PWD=gdm_agent_test_root', PREFIX + '_db', 'mysql', '-uroot',
               '-Nse', statement, 'glpi').stdout.strip()


def inventory(client, mode):
    command = (FOLDER / f'{mode}-command.sh').read_text().removeprefix('sudo ')
    run('exec', client, 'bash', '-c', command, timeout=900)
    assert int(sql('SELECT COUNT(*) FROM glpi_computers')) >= 1
    run('exec', client, 'test', '!', '-e', '/dev/fuse')
    assert run('exec', client, 'bash', '-c', 'command -v fusermount || true').stdout.strip() == ''
    print(f'OK: {mode} installation and inventory imported; no FUSE', flush=True)


def main():
    run('network', 'create', PREFIX)
    render()
    db = start('db', MYSQL, '-e', 'MYSQL_ROOT_PASSWORD=gdm_agent_test_root',
               '-e', 'MYSQL_DATABASE=glpi', '-e', 'MYSQL_USER=glpi',
               '-e', 'MYSQL_PASSWORD=gdm_agent_test_password', '--network-alias', 'db')
    for _ in range(90):
        if run('exec', '-e', 'MYSQL_PWD=gdm_agent_test_password', db, 'mysql', '-uglpi',
               '-Nse', 'SELECT 1', 'glpi', check=False).returncode == 0:
            break
        time.sleep(2)
    else:
        raise RuntimeError('MySQL did not become ready')
    glpi = start('glpi', GLPI, '--network-alias', 'glpi',
                 '-e', 'GLPI_DB_HOST=db', '-e', 'GLPI_DB_PORT=3306', '-e', 'GLPI_DB_NAME=glpi', '-e', 'GLPI_DB_USER=glpi',
                 '-e', 'GLPI_DB_PASSWORD=gdm_agent_test_password', '-e', 'GLPI_SKIP_AUTOINSTALL=false',
                 '-e', 'GLPI_SKIP_AUTOUPDATE=true', '-e', 'GLPI_CRONTAB_ENABLED=0',
                 *bind(FOLDER / 'revisions/off/public/agent', '/var/www/glpi/public/agent'))
    for _ in range(120):
        if run('exec', glpi, 'php', '-r',
               'exit(@file_get_contents("http://127.0.0.1/") === false ? 1 : 0);',
               check=False).returncode == 0 and run('exec', '-e', 'MYSQL_PWD=gdm_agent_test_root', db, 'mysql', '-uroot',
                   '-Nse', 'SELECT COUNT(*) FROM glpi_configs',
                   'glpi', check=False).returncode == 0:
            break
        time.sleep(2)
    else:
        raise RuntimeError('GLPI did not become ready')
    sql("UPDATE glpi_configs SET value='1' WHERE context='inventory' AND name='enabled_inventory'")
    sql("UPDATE glpi_configs SET value='none' WHERE context='inventory' AND name='auth_required'")
    run('exec', glpi, 'php', 'bin/console', 'cache:clear', '--no-interaction')
    for base, name in [('ubuntu:24.04', 'ubuntu'), ('debian:12', 'debian'), ('rockylinux:9', 'rocky')]:
        run('build', '-t', PREFIX + ':' + name, '--build-arg', 'BASE=' + base,
            '-f', ROOT / 'tests/agent-client.Dockerfile', ROOT / 'tests', timeout=900)
    ubuntu = start('ubuntu', PREFIX + ':ubuntu', '--hostname', PREFIX + '-ubuntu')
    inventory(ubuntu, 'off')
    identity = sql('SELECT deviceid FROM glpi_agents ORDER BY id')
    inventory(ubuntu, 'off')
    assert sql('SELECT deviceid FROM glpi_agents ORDER BY id') == identity
    assert sql('SELECT COUNT(*) FROM glpi_computers') == '1'
    print('OK: repeated command preserves identity', flush=True)
    # Exercise the persistent-service branch without granting cgroups/privileged
    # access to a client container. The manager below is explicitly a test double;
    # this checks service registration and error recovery, not a real system boot.
    run('exec', ubuntu, 'bash', '-c', '''mkdir -p /run/systemd/system
cat > /usr/local/bin/systemctl <<'STUB'
#!/bin/sh
echo "$*" >> /tmp/systemctl-calls
exit 0
STUB
chmod 755 /usr/local/bin/systemctl''')
    command = (FOLDER / 'off-service-command.sh').read_text().removeprefix('sudo ')
    run('exec', ubuntu, 'bash', '-c', command)
    unit = run('exec', ubuntu, 'cat', '/etc/systemd/system/glpi-agent.service').stdout
    assert 'ExecStart=/usr/local/bin/glpi-agent --daemon --no-fork' in unit
    assert 'enable --now glpi-agent' in run('exec', ubuntu, 'cat', '/tmp/systemctl-calls').stdout
    sql("UPDATE glpi_configs SET value='0' WHERE context='inventory' AND name='enabled_inventory'")
    run('exec', glpi, 'php', 'bin/console', 'cache:clear', '--no-interaction')
    run('exec', ubuntu, 'rm', '/tmp/systemctl-calls')
    result = run('exec', ubuntu, 'bash', '-c', command, check=False)
    assert result.returncode != 0 and '403 Forbidden' in result.stdout
    assert '[+] Agent configured' not in result.stdout
    assert 'enable --now glpi-agent' in run('exec', ubuntu, 'cat', '/tmp/systemctl-calls').stdout
    sql("UPDATE glpi_configs SET value='1' WHERE context='inventory' AND name='enabled_inventory'")
    run('exec', glpi, 'php', 'bin/console', 'cache:clear', '--no-interaction')
    print('OK: service registration and failed-inventory handling (controlled systemctl)', flush=True)
    for mode, base in [('self-signed', 'debian'), ('custom', 'rocky')]:
        revision = FOLDER / 'revisions' / mode
        proxy = start('proxy_' + mode, CADDY, '--network-alias', 'gdm-agent.test',
                      *bind(revision / 'Caddyfile', '/etc/caddy/Caddyfile'),
                      *bind(revision / 'tls', '/etc/gdm/tls'),
                      *bind(revision / 'public', '/etc/gdm/public'))
        client = start(base, PREFIX + ':' + base, '--hostname', PREFIX + '-' + base)
        inventory(client, mode)
        downloaded = run('exec', client, 'cat', '/etc/glpi-agent/certs/gdm-ca.pem').stdout
        assert downloaded == (revision / 'public/agent/ca.pem').read_text()
        # Tamper the CA without changing the trusted command/script hash. The
        # second run must reject it before modifying the existing agent config.
        ca_file = revision / 'public/agent/ca.pem'
        original = ca_file.read_bytes()
        config_before = run('exec', client, 'cat', '/etc/glpi-agent/conf.d/99-gdm.cfg').stdout
        try:
            ca_file.write_bytes(original + b'\nTAMPERED\n')
            command = (FOLDER / f'{mode}-command.sh').read_text().removeprefix('sudo ')
            result = run('exec', client, 'bash', '-c', command, check=False)
            assert result.returncode != 0 and 'SHA-256' in result.stdout
            assert run('exec', client, 'cat', '/etc/glpi-agent/conf.d/99-gdm.cfg').stdout == config_before
        finally:
            ca_file.write_bytes(original)
        print('OK: CA tampering rejected; installed configuration preserved', flush=True)
        run('rm', '-fv', proxy)
    # Tampered executable must never be run even though bootstrap uses HTTP.
    installer = FOLDER / 'revisions/off/public/agent/install.sh'
    original = installer.read_bytes()
    try:
        installer.write_bytes(original + b'\ntouch /tmp/UNSAFE_EXECUTION\n')
        command = (FOLDER / 'off-command.sh').read_text().removeprefix('sudo ')
        assert run('exec', ubuntu, 'bash', '-c', command, check=False).returncode != 0
        run('exec', ubuntu, 'test', '!', '-e', '/tmp/UNSAFE_EXECUTION')
    finally:
        installer.write_bytes(original)
    print('OK: installer tampering rejected before execution', flush=True)
    print('Imported computers: ' + sql('SELECT COUNT(*) FROM glpi_computers'), flush=True)


try:
    main()
finally:
    for container in reversed(CONTAINERS):
        run('rm', '-fv', container, check=False)
    run('network', 'rm', PREFIX, check=False)
    for name in ('ubuntu', 'debian', 'rocky'):
        run('image', 'rm', PREFIX + ':' + name, check=False)
    print('Evidence: ' + str(LOG), flush=True)

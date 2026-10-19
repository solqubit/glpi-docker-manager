#!/usr/bin/env python3
"""Backup integrity, safe administration and pre-stop capacity checks."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
import backup_ops
from archive import VOLUMES


def make_backup(folder, suffix='abcdef', origin='manual'):
    folder.mkdir(parents=True, exist_ok=True)
    payload = {'config.json': json.dumps({'db_password': 'SECRET_NOT_FOR_DISPLAY'}).encode(),
               'metadata.json': json.dumps(dict(format=1, glpi_version='11.0.10', mysql_server_version='8.4.11',
                                               created_at='2026-10-18T00:00:00Z', origin=origin)).encode(),
               'mysql.sql': b'CREATE TABLE fixture(id INTEGER);'}
    for role in VOLUMES:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz') as snapshot:
            entry = tarfile.TarInfo('marker'); entry.size = 4
            snapshot.addfile(entry, io.BytesIO(b'data'))
        payload[role + '.tar.gz'] = buffer.getvalue()
    payload['checksums.sha256'] = ''.join(hashlib.sha256(value).hexdigest() + '  ' + name + '\n'
                                         for name, value in payload.items()).encode()
    archive = folder / f'glpi-11.0.10-20261018T000000-{suffix}.tar.gz'
    with tarfile.open(archive, 'w:gz') as stream:
        for name, value in payload.items():
            entry = tarfile.TarInfo(name); entry.size = len(value)
            stream.addfile(entry, io.BytesIO(value))
    return archive


def rejected(action):
    try: action()
    except (OSError, ValueError): return
    raise AssertionError('Unsafe backup action was accepted')


def tests():
    with tempfile.TemporaryDirectory() as directory:
        state = Path(directory)
        archive = make_backup(state / 'backups')
        value = backup_ops.inspect(state, archive)
        assert value['origin'] == 'manual' and not value.get('verified_at')
        value = backup_ops.inspect(state, archive, verify=True)
        assert value['verified_at'] and not value['error']
        assert 'SECRET_NOT_FOR_DISPLAY' not in repr(value)
        assert not list((state / 'backups').glob('.restore-*'))
        exported = state / 'export.tar.gz'
        backup_ops.export(state, archive, exported)
        assert exported.read_bytes() == archive.read_bytes()
        assert exported.stat().st_mode & 0o077 == 0
        rejected(lambda: backup_ops.export(state, archive, exported))
        rejected(lambda: backup_ops.delete(state, exported))
        linked = state / 'backups/glpi-11.0.10-20261018T000000-aabbcc.tar.gz'
        linked.symlink_to(exported)
        rejected(lambda: backup_ops.delete(state, linked))
        (state / 'recovery-backup').write_text(str(archive) + '\n')
        (state / 'operation.json').write_text('{}')
        rejected(lambda: backup_ops.delete(state, archive))
        assert archive.is_file()
        (state / 'operation.json').unlink()
        backup_ops.delete(state, archive)
        assert not archive.exists() and exported.exists() and not (state / 'recovery-backup').exists()
        damaged = make_backup(state / 'backups', 'aabbdd')
        damaged.write_bytes(b'damaged')
        assert backup_ops.inspect(state, damaged, verify=True)['error'] == 'invalid'
        rejected(lambda: backup_ops.export(state, damaged, state / 'bad-export.tar.gz'))
        assert not (state / 'bad-export.tar.gz').exists()
        for mode, free, expected in [('low', '100', 1), ('enough', '8192', 77)]:
            work = state / mode
            result = subprocess.run(['bash', str(root / 'tests/backup-space-driver.sh'), str(work)],
                                    env=dict(os.environ, GDM_TEST_FREE_MIB=free), capture_output=True)
            assert result.returncode == expected, result.stderr.decode()
            assert (work / 'stopped').exists() == (mode == 'enough')
            assert not list((work / 'backups').glob('.work-*')) if mode == 'low' else True
    print('PASS: streaming backup verification, metadata privacy, export, protected deletion and capacity before stopping GLPI')


if __name__ == '__main__': tests()

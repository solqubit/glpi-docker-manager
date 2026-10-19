#!/usr/bin/env python3
"""Bounded backup inspection, streaming verification, export and single-file removal."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tarfile
import tempfile

from archive import members, verify_archive

ORIGINS = {'manual', 'update', 'migrate', 'db-update', 'refresh-image', 'transfer'}


def managed(root, path):
    root, path = Path(root), Path(path)
    folder = root / 'backups'
    if (folder.is_symlink() or not path.is_absolute() or path.parent != folder
            or not re.fullmatch(r'glpi-[0-9]+\.[0-9]+\.[0-9]+-[0-9]{8}T[0-9]{6}-[a-f0-9]+\.tar\.gz', path.name)
            or not stat.S_ISREG(path.lstat().st_mode)):
        raise ValueError('Unmanaged backup path')
    return path


def fingerprint(path):
    info = path.stat()
    return [info.st_size, info.st_mtime_ns, info.st_ino]


def cached(root, path):
    try:
        file = Path(root) / 'backups' / '.index' / (path.name + '.json')
        value = json.loads(file.read_text())
        return value if value.get('fingerprint') == fingerprint(path) else {}
    except (OSError, ValueError, TypeError):
        return {}


def save(root, path, value):
    folder = Path(root) / 'backups' / '.index'
    if folder.is_symlink(): raise ValueError('Unsafe index path')
    folder.mkdir(mode=0o700, exist_ok=True)
    value['fingerprint'] = fingerprint(path)
    handle, name = tempfile.mkstemp(dir=folder, prefix='.index-')
    try:
        with os.fdopen(handle, 'w') as stream:
            json.dump(value, stream); stream.write('\n')
        os.replace(name, folder / (path.name + '.json'))
    finally:
        if os.path.exists(name): os.unlink(name)


def public_metadata(data):
    def version(key):
        value = str(data.get(key, ''))
        return value if re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value) else ''
    return dict(glpi_version=version('glpi_version'), mysql_version=version('mysql_server_version'),
                created_at=str(data.get('created_at', ''))[:40],
                origin=data.get('origin') if data.get('origin') in ORIGINS else 'unknown',
                target=version('target_version'))


def inspect(root, path, verify=False):
    path = managed(root, path)
    before = fingerprint(path)
    value = cached(root, path)
    try:
        if verify:
            data = verify_archive(path)
            value.update(public_metadata(data))
            value.update(verified_at=datetime.now(timezone.utc).isoformat(), error='')
        else:
            with tarfile.open(path, 'r:gz') as archive:
                for member, name in members(archive, outer=True, max_size=1024 ** 4):
                    if name == 'metadata.json':
                        if member.size > 65536: raise ValueError('Oversized metadata')
                        data = json.load(archive.extractfile(member))
                        value.update(public_metadata(data))
                        break
                else: raise ValueError('Missing metadata')
        if fingerprint(path) != before: raise ValueError('Backup changed during inspection')
    except (ValueError, OSError, tarfile.TarError, KeyError, TypeError, EOFError):
        value.update(verified_at='', error='invalid')
    save(root, path, value)
    return value


def delete(root, path):
    path = managed(root, path)
    if (Path(root) / 'backups' / '.index').is_symlink(): raise ValueError('Unsafe index path')
    pointer = Path(root) / 'recovery-backup'
    recovery = pointer.read_text().strip() if pointer.exists() else ''
    if recovery == str(path) and (Path(root) / 'operation.json').exists():
        raise ValueError('Recovery backup is protected during an incomplete operation')
    path.unlink()
    index = Path(root) / 'backups' / '.index' / (path.name + '.json')
    if index.is_file(): index.unlink()
    if recovery == str(path): pointer.unlink()


def export(root, path, destination):
    path, destination = managed(root, path), Path(destination)
    if not destination.is_absolute() or not destination.parent.is_dir() or destination.is_symlink() or destination.exists():
        raise ValueError('Choose a new absolute destination file in an existing directory')
    value = inspect(root, path, verify=True)
    if not value.get('verified_at'): raise ValueError('Backup verification failed')
    space = os.statvfs(destination.parent)
    if space.f_bavail * space.f_frsize < path.stat().st_size + 1048576:
        raise ValueError('Not enough free space at the export destination')
    before = fingerprint(path)
    created = False
    try:
        with path.open('rb') as source, destination.open('xb') as target:
            created = True
            os.fchmod(target.fileno(), 0o600)
            digest = hashlib.sha256()
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(chunk); target.write(chunk)
            target.flush(); os.fsync(target.fileno())
        if fingerprint(path) != before: raise ValueError('Backup changed during export')
        copied = hashlib.sha256()
        with destination.open('rb') as target:
            for chunk in iter(lambda: target.read(1024 * 1024), b''): copied.update(chunk)
        if copied.digest() != digest.digest(): raise ValueError('Export verification failed')
    except BaseException:
        if created: destination.unlink()
        raise


def main():
    os.umask(0o077)
    action, root, path = sys.argv[1:4]
    if action in ('inspect', 'verify', 'check'):
        value = inspect(root, path, verify=action != 'inspect')
        if action == 'check' and not value.get('verified_at'): raise ValueError('Backup verification failed')
    elif action == 'delete': delete(root, path)
    elif action == 'export': export(root, path, sys.argv[4])
    else: raise ValueError('Unknown backup operation')


if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, tarfile.TarError) as error:
        print(str(error), file=sys.stderr); raise SystemExit(1)

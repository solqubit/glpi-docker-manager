#!/usr/bin/env python3
"""Inspect backups before extraction. Only the Python standard library is used."""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import sys
import tarfile

VOLUMES = ('glpi_data', 'plugins', 'marketplace', 'caddy_data', 'caddy_config')
REQUIRED = {'config.json', 'metadata.json', 'mysql.sql', 'checksums.sha256'} | {
    f'{v}.tar.gz' for v in VOLUMES
}
ALLOWED = REQUIRED | {'tls/fullchain.pem', 'tls/privkey.pem'}


def members(archive, outer=False, max_size=None):
    seen = set()
    total = 0
    for count, member in enumerate(archive):
        if count > 200000:
            raise ValueError('Too many archive members')
        name = member.name[2:] if member.name.startswith('./') else member.name
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name or '\x00' in name:
            raise ValueError('Unsafe archive path')
        if member.isdir():
            continue
        if not member.isfile():
            # Snapshot links are rejected rather than silently following them.
            raise ValueError('Links, devices and special archive entries are not supported')
        if name in seen or (outer and name not in ALLOWED):
            raise ValueError('Unexpected or duplicate archive member')
        seen.add(name)
        total += member.size
        if max_size is not None and total > max_size:
            raise ValueError('Archive exceeds available extraction budget')
        yield member, name
    if outer and not REQUIRED <= seen:
        raise ValueError('Incomplete backup')


def inspect_extract(source, destination):
    root = Path(destination)
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    free = os.statvfs(root).f_bavail * os.statvfs(root).f_frsize
    with tarfile.open(source, 'r:gz') as archive:
        entries = list(members(archive, outer=True, max_size=free // 2))
        for member, name in entries:
            target = root / name
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with archive.extractfile(member) as src, target.open('xb') as dst:
                chunk = src.read(1024 * 1024)
                while chunk:
                    dst.write(chunk)
                    chunk = src.read(1024 * 1024)
            target.chmod(0o600)
    verify(root)


def verify(root):
    root = Path(root)
    expected = {}
    for line in (root / 'checksums.sha256').read_text().splitlines():
        digest, name = line.split('  ', 1)
        if name not in ALLOWED - {'checksums.sha256'} or len(digest) != 64 or name in expected:
            raise ValueError('Invalid checksum manifest')
        expected[name] = digest
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
    if set(expected) != actual - {'checksums.sha256'} or not REQUIRED <= actual:
        raise ValueError('Checksum coverage is incomplete')
    for name, digest in expected.items():
        h = hashlib.sha256()
        with (root / name).open('rb') as src:
            for chunk in iter(lambda: src.read(1024 * 1024), b''):
                h.update(chunk)
        if h.hexdigest() != digest:
            raise ValueError(f'Checksum mismatch: {name}')
    metadata = json.loads((root / 'metadata.json').read_text())
    if metadata.get('format') != 1:
        raise ValueError('Unsupported backup format')
    if (root / 'mysql.sql').stat().st_size == 0:
        raise ValueError('Empty database dump')
    # Validate snapshots before any container is stopped or any volume restored.
    for role in VOLUMES:
        with tarfile.open(root / f'{role}.tar.gz', 'r:gz') as snapshot:
            list(members(snapshot, max_size=1024 ** 4))


def footprint(root):
    """Additional MiB for a restored DB/files copy and migration table rewrites."""
    root = Path(root)
    data = 0
    for role in VOLUMES:
        with tarfile.open(root / f'{role}.tar.gz', 'r:gz') as snapshot:
            data += sum(member.size for member, _ in members(snapshot, max_size=1024 ** 4))
    # SQL serialization differs from physical table size. Include DB baseline
    # files, index rebuilds and temporary tables; storage_preflight adds headroom.
    data += (root / 'mysql.sql').stat().st_size * 4 + 512 * 1024 ** 2
    return (data + 1024 ** 2 - 1) // 1024 ** 2


def checksum_manifest(text):
    expected = {}
    for line in text.splitlines():
        digest, name = line.split('  ', 1)
        if (name not in ALLOWED - {'checksums.sha256'} or len(digest) != 64
                or any(char not in '0123456789abcdef' for char in digest) or name in expected):
            raise ValueError('Invalid checksum manifest')
        expected[name] = digest
    return expected


class HashReader(io.RawIOBase):
    def __init__(self, source):
        self.source = source
        self.digest = hashlib.sha256()

    def read(self, size=-1):
        value = self.source.read(size)
        self.digest.update(value)
        return value


def verify_archive(path):
    """Verify nested snapshots/checksums as streams, without extracting to disk."""
    actual, metadata, expected = {}, None, None
    with tarfile.open(path, 'r:gz') as outer:
        for member, name in members(outer, outer=True, max_size=1024 ** 4):
            with outer.extractfile(member) as source:
                reader = HashReader(source)
                if name.endswith('.tar.gz'):
                    with tarfile.open(fileobj=reader, mode='r|gz') as snapshot:
                        list(members(snapshot, max_size=1024 ** 4))
                elif name in ('metadata.json', 'checksums.sha256'):
                    if member.size > 65536:
                        raise ValueError('Oversized metadata')
                    text = reader.read().decode('utf-8')
                    if name == 'metadata.json': metadata = json.loads(text)
                    else: expected = checksum_manifest(text)
                elif name == 'mysql.sql' and member.size == 0:
                    raise ValueError('Empty database dump')
                while reader.read(1024 * 1024):
                    pass
                if name != 'checksums.sha256': actual[name] = reader.digest.hexdigest()
    if not isinstance(metadata, dict) or metadata.get('format') != 1:
        raise ValueError('Unsupported backup format')
    if expected != actual or not REQUIRED - {'checksums.sha256'} <= actual.keys():
        raise ValueError('Checksum mismatch or incomplete coverage')
    return metadata


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'extract':
            inspect_extract(sys.argv[2], sys.argv[3])
        elif sys.argv[1] == 'verify':
            verify(sys.argv[2])
        elif sys.argv[1] == 'footprint':
            print(footprint(sys.argv[2]))
        else:
            raise ValueError('Unknown archive operation')
    except (ValueError, OSError, tarfile.TarError, KeyError, json.JSONDecodeError) as exc:
        print(f'Backup validation failed: {exc}', file=sys.stderr)
        sys.exit(1)

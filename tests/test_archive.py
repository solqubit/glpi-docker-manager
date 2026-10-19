#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile

spec = importlib.util.spec_from_file_location('archive', Path(__file__).parents[1] / 'tools' / 'archive.py')
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


def rejected(fn):
    try:
        fn()
    except (ValueError, OSError, tarfile.TarError):
        return
    raise AssertionError('Unsafe archive was accepted')


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    payload = root / 'payload'
    payload.mkdir()
    (payload / 'config.json').write_text('{}')
    (payload / 'metadata.json').write_text(json.dumps({'format': 1}))
    (payload / 'mysql.sql').write_text('CREATE TABLE demo (id INT);')
    for role in archive.VOLUMES:
        with tarfile.open(payload / (role + '.tar.gz'), 'w:gz') as tar:
            member = tarfile.TarInfo('config/example.txt')
            member.size = 4
            tar.addfile(member, io.BytesIO(b'data'))
    checksums = '\n'.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name
                          for p in sorted(payload.iterdir())) + '\n'
    (payload / 'checksums.sha256').write_text(checksums)
    archive.verify(payload)
    good = root / 'good.tar.gz'
    with tarfile.open(good, 'w:gz') as tar:
        for file in payload.iterdir():
            tar.add(file, arcname=file.name)
    archive.inspect_extract(good, root / 'restored')
    assert archive.verify_archive(good)['format'] == 1
    assert archive.footprint(root / 'restored') == 513
    (payload / 'mysql.sql').write_text('tampered')
    rejected(lambda: archive.verify(payload))
    for name in ('../escape', '/absolute', 'tls/../../escape'):
        bad = root / 'bad.tar.gz'
        with tarfile.open(bad, 'w:gz') as tar:
            member = tarfile.TarInfo(name)
            member.size = 1
            tar.addfile(member, io.BytesIO(b'x'))
        rejected(lambda: archive.inspect_extract(bad, root / ('out' + str(len(name)))))
    for member_type in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE):
        bad = root / 'link.tar.gz'
        with tarfile.open(bad, 'w:gz') as tar:
            member = tarfile.TarInfo('config.json')
            member.type = member_type
            member.linkname = '/etc/passwd'
            tar.addfile(member)
        with tarfile.open(bad) as tar:
            rejected(lambda: list(archive.members(tar, outer=True)))
    bad = root / 'duplicate.tar.gz'
    with tarfile.open(bad, 'w:gz') as tar:
        for _ in range(2):
            member = tarfile.TarInfo('config.json')
            member.size = 2
            tar.addfile(member, io.BytesIO(b'{}'))
    with tarfile.open(bad) as tar:
        rejected(lambda: list(archive.members(tar, outer=True)))
    rejected(lambda: archive.verify_archive(bad))

#!/usr/bin/env python3
"""Drive the real Bash backup browser through a PTY, using disposable archives."""
import fcntl
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

from test_backups import make_backup

if os.environ.get('GDM_INTEGRATION') != '1':
    raise SystemExit('Set GDM_INTEGRATION=1 to run the local-engine UI smoke test')
root = Path(__file__).resolve().parents[1]
state = root / 'tests/.runtime' / ('backup-ui-' + uuid.uuid4().hex)
archive = make_backup(state / 'backups')
destination = state / 'exported.tar.gz'
locale = dict(line.split('\t', 1) for line in (root / 'locales/es.tsv').read_text().splitlines())
down = b'\x1b[B'


def drive(events, log):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    def session():
        os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    process = subprocess.Popen(['bash', str(root / 'start.sh'), '--lang', 'es',
                                '--state-dir', str(state), 'backups'],
                               stdin=slave, stdout=slave, stderr=slave, preexec_fn=session,
                               env=dict(os.environ, TERM='xterm-256color', LC_ALL='C.UTF-8'))
    os.close(slave)
    captured = bytearray(); index = offset = 0
    deadline = time.monotonic() + 90
    try:
        while process.poll() is None:
            assert time.monotonic() < deadline, (index, captured[-1500:])
            if select.select([master], [], [], .1)[0]:
                try: captured.extend(os.read(master, 65536))
                except OSError: break
            if index < len(events):
                key, strokes = events[index]
                needle = locale[key].split('%s')[0][:30].encode()
                found = captured.find(needle, offset)
                if found >= 0:
                    offset = found + len(needle)
                    for stroke in strokes:
                        time.sleep(.15); os.write(master, stroke)
                        while select.select([master], [], [], 0)[0]: captured.extend(os.read(master, 65536))
                    index += 1
        process.wait(timeout=10)
        (state / log).write_bytes(captured)
        assert process.returncode == 0 and index == len(events), (process.returncode, index, captured[-3000:])
    finally:
        if process.poll() is None: process.kill(); process.wait()
        os.close(master)


drive([('backups_overview', [b'\n']), ('backups_details', [b'\n']),
       ('backups_check_done', [down * 2 + b'\n']),
       ('backups_export_hint', [str(destination).encode() + b'\n']),
       ('backups_exported', [b'\x1b', b'\x1b'])], 'verify-export.log')
assert destination.read_bytes() == archive.read_bytes()
index = json.loads((state / 'backups/.index' / (archive.name + '.json')).read_text())
assert index['verified_at'] and index['origin'] == 'manual'
drive([('backups_overview', [b'\n']), ('backups_details', [down * 3 + b'\n']),
       ('backups_delete_hint', [b'\x1b', b'\x1b', b'\x1b'])], 'cancel-delete.log')
assert archive.exists()
drive([('backups_overview', [b'\n']), ('backups_details', [down * 3 + b'\n']),
       ('backups_delete_hint', [b'DELETE\n']), ('backups_deleted', [b'\x1b'])], 'confirmed-delete.log')
assert not archive.exists() and destination.exists()
print('PASS: real Bash/curses backup browser, verify, export, cancellation and explicit per-file deletion')
print('Private evidence:', state)

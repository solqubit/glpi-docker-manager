#!/usr/bin/env python3
"""Exercise the actual terminal prompts, including Bash output-variable scoping."""
import os
from pathlib import Path
import pty
import subprocess

root = Path(__file__).parents[1]
for language, mode, answer, expected in (
    ('en', 'confirm', b'y\n', b'ACCEPTED'),
    ('es', 'confirm', b's\n', b'ACCEPTED'),
    ('en', 'confirm', b'\n', b'DECLINED'),
    ('en', 'ask', b'chosen\n', b'ASSIGNED'),
    ('en', 'secret', b'test_password_123456789\n', b'SECRET_ASSIGNED'),
    ('en', 'root', b"bad_root_password_123'\ntest_password_123456789\n", b'ROOT_ASSIGNED'),
):
    master, slave = pty.openpty()
    process = subprocess.Popen(['bash', str(root / 'tests/prompt-driver.sh'), mode],
                               stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=dict(os.environ, GDM_LANG=language, GDM_PASSWORD_VISIBILITY='hidden'))
    os.close(slave)
    os.write(master, answer)
    output, errors = process.communicate(timeout=15)
    os.close(master)
    assert process.returncode == 0, errors
    assert expected in output, (output, errors)
    assert b'test_password_123456789' not in output + errors

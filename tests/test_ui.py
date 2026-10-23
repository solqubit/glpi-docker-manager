#!/usr/bin/env python3
"""Drive the real ANSI interface through a terminal, including interruption."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[1]


def terminal_case(mode, keys, expected, language='es', columns=80, rows=24,
                  extra_env=None, expected_code=0, interrupt=False, followups=(),
                  ready=None, remain_open=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
    original = termios.tcgetattr(slave)
    environment = dict(os.environ, TERM='xterm-256color', LC_ALL='C.UTF-8', GDM_LANG=language)
    environment.pop('NO_COLOR', None)
    if extra_env:
        environment.update(extra_env)
    def terminal_session():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    process = subprocess.Popen(['bash', str(root / 'tests/ui-driver.sh'), mode],
                               stdin=slave, stdout=slave, stderr=slave, env=environment,
                               preexec_fn=terminal_session)
    captured = bytearray()
    try:
        deadline = time.monotonic() + 10
        # Input is sent only once the selector/field is ready, just like a user.
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                captured.extend(os.read(master, 65536))
            if (b'\x1b[?25l' in captured or b'> ' in captured or b'[1] ' in captured
                    or mode == 'fail' or ready and ready in captured):
                break
            if process.poll() is not None:
                break
        if interrupt:
            # Let the prompt finish switching terminal modes before the key.
            time.sleep(0.1)
            os.write(master, b'\x03')
        elif keys:
            os.write(master, keys)
        if remain_open:
            time.sleep(.2)
            assert process.poll() is None, 'A navigation key accepted the pause'
            os.write(master, b'\n')
        follow_index = 0
        follow_offset = len(captured)
        while process.poll() is None:
            assert time.monotonic() < deadline, captured.decode(errors='replace')
            if select.select([master], [], [], 0.1)[0]:
                captured.extend(os.read(master, 65536))
            if follow_index < len(followups):
                needle, answer = followups[follow_index]
                found = captured.find(needle, follow_offset)
                if found >= 0:
                    follow_offset = found + len(needle)
                    os.write(master, answer)
                    follow_index += 1
        while select.select([master], [], [], 0)[0]:
            captured.extend(os.read(master, 65536))
        process.wait(timeout=3)
        assert process.returncode == expected_code, captured.decode(errors='replace')
        assert expected in captured, captured.decode(errors='replace')
        assert termios.tcgetattr(slave) == original, 'Terminal settings leaked'
        if mode not in ('ask', 'ask-cancel', 'typed', 'pause', 'valid-port', 'fail', 'root-secret') and not mode.startswith('secret') and not extra_env:
            assert b'\x1b[?25h' in captured, 'Cursor remained hidden'
        return bytes(captured)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
        os.close(master)
        os.close(slave)


terminal_case('select', b'\x1b[B\n', b'RESULT=production')
terminal_case('select', b'\x1b[A\n', b'RESULT=custom', language='en')
terminal_case('select', b'\x1b[F\x1b[H\n', b'RESULT=test')
terminal_case('language', b'\x1b[B\n', b'RESULT=es', language='en')
terminal_case('confirm', b'\x1b[A\n', b'ACCEPTED')
terminal_case('confirm', b'\n', b'DECLINED')
terminal_case('cancel', b'\x1b', b'CANCELLED')
terminal_case('long', b'\x1b[F\n', b'RESULT=22')
terminal_case('long', b'\x1b[6~\n', b'RESULT=11')
terminal_case('select', b'\x1b[B\n', b'RESULT=production', columns=40)
uncolored = terminal_case('select', b'\x1b[B\n', b'RESULT=production', extra_env={'NO_COLOR': '1'})
assert re.search(rb'\x1b\[[0-9;]*m', uncolored) is None
terminal_case('select', b'production\n', b'RESULT=production', extra_env={'TERM': 'dumb'})
terminal_case('ask', b'1808\x1b[D0\n', b'RESULT=18008')
terminal_case('ask', b'12\t3\x1b[H\x1b[3~\x1b[F4\x01x\x05y\n', b'RESULT=x234y')
terminal_case('ask', b'old\x15new\n', b'RESULT=new')
terminal_case('ask-cancel', b'edited\x1b', b'CANCELLED')
terminal_case('typed', b'RESTORE\n', b'CONFIRMED')
terminal_case('typed', b'\x1b', b'Cancelado.', expected_code=1)
# A typo asks again instead of cancelling.
retyped = terminal_case('typed', b'restore\nRESTORE\n', b'CONFIRMED')
assert 'No coincide'.encode() in retyped
terminal_case('pause', b'\x1b[B', b'PAUSE_DONE', ready=b'Pulsa Enter', remain_open=True)
terminal_case('pause', b'\x1b', b'PAUSE_DONE', ready=b'Pulsa Enter')
terminal_case('valid-port', b'bad\n18080\n', b'RESULT=18080')
visible = terminal_case('secret', b'abc\n', b'SECRET_OK')
assert b'abc' in visible and b'\r\x1b[2K' in visible
hidden = terminal_case('secret-hidden', b'abc\n', b'SECRET_OK',
                       extra_env={'GDM_PASSWORD_VISIBILITY': 'hidden'})
assert b'abc' not in hidden and b'***' in hidden
toggled = terminal_case('secret-toggle', b'\tabc\t\x1b[D\x1b[D\x1b[D\x1b[Ca\x7f\n', b'SECRET_OK')
assert b'[Oculta]' in toggled and b'abc' in toggled
terminal_case('secret', b'\x7fabd\x7fc\n', b'SECRET_OK')
terminal_case('secret-generated', b'\n', b'GENERATED_OK')
terminal_case('secret', b'', b'\r\x1b[2K', expected_code=130, interrupt=True)
cancelled_secret = terminal_case('secret', b'\x1b', b'Cancelado.', expected_code=1)
assert 'La operación falló'.encode() not in cancelled_secret
terminal_case('root-secret', b"bad'\n", b'ROOT_OK', followups=[
    ('MYSQL_ROOT_PASSWORD'.encode(), b'1\n'),
])
long_secret = 'a' * 130
terminal_case('secret-long', (long_secret + '\n').encode(), b'SECRET_OK',
              extra_env={'GDM_UI_EXPECT_SECRET': long_secret}, columns=40)
pages = terminal_case('pages', b'\n', b'PAGES_OK', followups=[
    (b'[Visible] > ', b'x\n'),
    ('¿Exponer'.encode(), b'\n'),
])
assert pages.count(b'\x1b[2J\x1b[H') == 3, 'Fields appended instead of replacing the page'
assert b'\x1b[44m' not in uncolored
terminal_case('select', b'', b'\x1b[?25h', expected_code=130, interrupt=True)
screen = terminal_case('screen', b'\x1b[F\n', b'RESULT=quit')
assert 'Todavía no hay un GLPI'.encode() in screen
assert 'Instalar GLPI'.encode() in screen and 'Restaurar un respaldo'.encode() in screen
# A cancellation inside the menu returns straight to it, without "press Enter".
cancelled = terminal_case('menu-cancel', b'\n', b'MENU_CLOSED', followups=[
    ('¿Qué quieres hacer?'.encode(), b'\x1b'),
])
assert 'La operación falló'.encode() not in cancelled
assert 'Pulsa Enter para volver'.encode() not in cancelled
returned = terminal_case('menu-back', b'\n', b'MENU_CLOSED', followups=[
    ('¿Qué quieres hacer?'.encode(), b'\x1b'),
])
assert 'Pulsa Enter para volver'.encode() not in returned
resources = terminal_case('resource-back', b'\n', b'MENU_CLOSED', followups=[
    ('¿Cómo quieres continuar'.encode(), b'\x1b[B\n'),
    ('¿Qué quieres hacer?'.encode(), b'\x1b'),
])
assert b'UNSAFE_CONTINUATION' not in resources
assert 'Pulsa Enter para volver'.encode() not in resources
assert 'instalación pequeña'.encode() not in resources
card = terminal_case('defaults-card', b'\n', b'RESULT=defaults')
assert card.count(b'GLPI_DB_HOST') == 2
assert b'\x1b[1;36m3306' in card
saved_language = terminal_case('saved-language', b'', b'Usage:', language='en',
                               extra_env={'TERM': 'dumb'})
assert b'Uso:' in saved_language
with tempfile.TemporaryDirectory() as folder:
    # The failure details stay in a protected log, not in ordinary progress output.
    failure = terminal_case('fail', b'', 'Detalles de esta etapa:'.encode(), expected_code=42,
                            extra_env={'GDM_UI_TEST_STATE': folder})
    assert b'UNSAFE_CONTINUATION' not in failure
    assert b'UNSAFE_INNER_CONTINUATION' not in failure
    assert b'private failure details' not in failure
    logs = list((Path(folder) / 'logs').glob('*.log'))
    assert len(logs) == 1 and b'private failure details' in logs[0].read_bytes()
    assert logs[0].stat().st_mode & 0o077 == 0, 'Step log permissions expose private output'
for failure_mode in ('io-fail', 'spinner-fail'):
    with tempfile.TemporaryDirectory() as folder:
        failure = terminal_case(failure_mode, b'', 'Se detectó un error Input/output'.encode(),
                                expected_code=74, extra_env={'GDM_UI_TEST_STATE': folder})
        assert b'UNSAFE_CONTINUATION' not in failure
        assert b'sleep: Input/output error' not in failure
print('PASS: arrow keys, scrolling, bilingual choices, editable fields, cancellation, failure and terminal restoration')

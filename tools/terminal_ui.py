#!/usr/bin/env python3
"""Small terminal widgets using Python's optional standard-library curses module."""
import os
import getpass
import re
import sys
import textwrap

try:
    import curses
except ImportError:
    curses = None


def translations(root, language):
    return dict(line.split('\t', 1) for line in
                (root / 'locales' / (language + '.tsv')).read_text().splitlines())


def clean(value):
    value = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', str(value))
    return ''.join(char for char in value if char.isprintable())


class Terminal:
    def __init__(self, messages, context=''):
        self.msg = messages
        self.context = context
        self.screen = None
        self.styles = {}

    def t(self, key, *values):
        value = self.msg.get(key, key)
        return value % values if values else value

    def run(self, action):
        capable = (curses is not None and sys.stdin.isatty() and sys.stdout.isatty()
                   and os.environ.get('TERM', 'dumb') != 'dumb'
                   and os.environ.get('GDM_UI') != 'plain')
        if capable:
            size = os.get_terminal_size()
            capable = size.columns >= 50 and size.lines >= 18
        if not capable:
            return action()
        os.environ.setdefault('ESCDELAY', '35')
        def start(screen):
            self.screen = screen
            screen.keypad(True)
            if hasattr(curses, 'set_escdelay'):
                curses.set_escdelay(35)
            self.cursor(False)
            if curses.has_colors() and 'NO_COLOR' not in os.environ:
                curses.start_color()
                try:
                    curses.use_default_colors()
                    background = -1
                except curses.error:
                    background = curses.COLOR_BLACK
                colors = [('title', curses.COLOR_MAGENTA, background),
                          ('accent', curses.COLOR_CYAN, background),
                          ('ok', curses.COLOR_GREEN, background),
                          ('warning', curses.COLOR_YELLOW, background),
                          ('error', curses.COLOR_RED, background),
                          ('selected', curses.COLOR_WHITE, curses.COLOR_BLUE)]
                for number, (name, foreground, back) in enumerate(colors, 1):
                    curses.init_pair(number, foreground, back)
                    self.styles[name] = curses.color_pair(number) | curses.A_BOLD
            return action()
        try:
            return curses.wrapper(start)
        except curses.error:
            # Missing terminfo or a limited curses build still permits setup.
            self.screen = None
            return action()
        finally:
            self.screen = None

    def cursor(self, visible):
        if self.screen is not None:
            try:
                curses.curs_set(int(visible))
            except curses.error:
                pass

    def put(self, y, x, text, style=''):
        height, width = self.screen.getmaxyx()
        if 0 <= y < height and 0 <= x < width - 1:
            try:
                self.screen.addnstr(y, x, clean(text), width - x - 1,
                                   self.styles.get(style, 0))
            except curses.error:
                pass

    def frame(self, title, notice='', notice_style='accent'):
        self.screen.erase()
        height, width = self.screen.getmaxyx()
        self.left = max(2, (width - 104) // 2)
        self.width = max(12, min(100, width - self.left - 2))
        self.put(0, self.left, 'GLPI Docker Manager', 'title')
        self.put(1, self.left, self.t('ui_subtitle'))
        self.put(2, self.left, self.context, 'accent')
        self.put(3, self.left, '─' * self.width, 'accent')
        self.put(4, self.left, title, 'accent')
        lines = textwrap.wrap(clean(notice), self.width)[:max(2, min(5, height - 17))]
        for row, line in enumerate(lines, 5):
            self.put(row, self.left, line, notice_style)
        return 6 + len(lines), height

    def key(self):
        key = self.screen.get_wch()
        if key == '\x03':
            raise KeyboardInterrupt
        # Some SSH clients send normal cursor keys even in application mode.
        if key == '\x1b':
            sequence = ''
            self.screen.timeout(35)
            try:
                first = self.screen.get_wch()
                if first not in ('[', 'O'):
                    curses.unget_wch(first)
                    return '\x1b'
                sequence = first
                while len(sequence) < 5:
                    part = self.screen.get_wch()
                    if isinstance(part, str):
                        sequence += part
                    else:
                        break
                    if part.isalpha() or part == '~':
                        break
            except curses.error:
                pass
            finally:
                self.screen.timeout(-1)
            key = {'[A': curses.KEY_UP, 'OA': curses.KEY_UP,
                   '[B': curses.KEY_DOWN, 'OB': curses.KEY_DOWN,
                   '[C': curses.KEY_RIGHT, 'OC': curses.KEY_RIGHT,
                   '[D': curses.KEY_LEFT, 'OD': curses.KEY_LEFT,
                   '[H': curses.KEY_HOME, 'OH': curses.KEY_HOME,
                   '[F': curses.KEY_END, 'OF': curses.KEY_END,
                   '[1~': curses.KEY_HOME, '[4~': curses.KEY_END,
                   '[3~': curses.KEY_DC,
                   '[5~': curses.KEY_PPAGE, '[6~': curses.KEY_NPAGE}.get(sequence, '\x1b')
        return key

    def menu(self, title, rows, selected=0, notice='', help_text='', search=False,
             notice_style='accent'):
        """Rows are (value, label, semantic color); return a value or None on Back."""
        selected = min(selected, len(rows) - 1)
        if self.screen is None:
            print('\n' + title, file=sys.stderr)
            if notice:
                print(notice, file=sys.stderr)
            for number, (_, label, _) in enumerate(rows, 1):
                print(f'  {number}) {label}', file=sys.stderr)
            while True:
                answer = input(self.t('setup_plain_choice'))
                if answer.lower() in ('b', 'back', 'volver'):
                    return None
                if answer == '':
                    return rows[selected][0]
                if answer.isdigit() and 1 <= int(answer) <= len(rows):
                    return rows[int(answer) - 1][0]
                matches = [row for row in rows if answer.casefold() in row[1].casefold()]
                if len(matches) == 1:
                    return matches[0][0]
                print(self.t('ui_invalid_choice'), file=sys.stderr)
        query = ''
        while True:
            filtered = [row for row in rows if query.casefold() in row[1].casefold()]
            selected = max(0, min(selected, len(filtered) - 1))
            note = self.t('setup_search', query) if search and query else notice
            top, height = self.frame(title, note, notice_style)
            visible = max(1, height - top - 5)
            offset = max(0, min(selected - visible // 2, len(filtered) - visible))
            for index in range(offset, min(offset + visible, len(filtered))):
                _, label, style = filtered[index]
                active = index == selected
                label = ('> ' if active else '  ') + label
                self.put(top + index - offset, self.left, label.ljust(self.width),
                         'selected' if active else style)
            if not filtered:
                self.put(top, self.left, self.t('setup_no_matches'), 'warning')
            self.put(height - 4, self.left, '─' * self.width, 'accent')
            for row, line in enumerate(textwrap.wrap(help_text, self.width)[:2], height - 3):
                self.put(row, self.left, line)
            self.put(height - 1, self.left,
                     f'{selected + 1}/{len(filtered)} · ' + self.t('setup_search_keys' if search else 'setup_keys'), 'accent')
            self.screen.refresh()
            key = self.key()
            if key in ('\n', '\r', curses.KEY_ENTER) and filtered:
                return filtered[selected][0]
            if key == '\x1b':
                return None
            if key in (curses.KEY_DOWN, '\t'):
                selected = (selected + 1) % max(1, len(filtered))
            elif key in (curses.KEY_UP, curses.KEY_BTAB):
                selected = (selected - 1) % max(1, len(filtered))
            elif key == curses.KEY_HOME:
                selected = 0
            elif key == curses.KEY_END:
                selected = len(filtered) - 1
            elif key == curses.KEY_NPAGE:
                selected = min(len(filtered) - 1, selected + visible)
            elif key == curses.KEY_PPAGE:
                selected = max(0, selected - visible)
            elif search and key in (curses.KEY_BACKSPACE, '\x7f', '\b'):
                query = query[:-1]
            elif search and isinstance(key, str) and key.isprintable():
                query += key
                selected = 0

    def edit(self, title, value, hint, validator, secret=False):
        visible = os.environ.get('GDM_PASSWORD_VISIBILITY') != 'hidden'
        if self.screen is None:
            print('\n' + title + '\n' + hint, file=sys.stderr)
            while True:
                text = getpass.getpass('> ') if secret and not visible else input('> ')
                if text == ':back':
                    return None
                text = text if text or secret else str(value)
                error = validator(text)
                if not error:
                    return text
                print(error, file=sys.stderr)
        text = str(value)
        position = len(text)
        error = ''
        while True:
            top, height = self.frame(title, error or hint, 'error' if error else 'accent')
            display = text if not secret or visible else '*' * len(text)
            start = max(0, position - self.width + 5)
            self.put(top, self.left, '> ' + display[start:start + self.width - 3])
            self.put(height - 2, self.left, self.t('setup_edit_keys'), 'accent')
            if secret:
                self.put(height - 3, self.left, self.t('ui_password_keys'))
            self.cursor(True)
            self.screen.move(min(top, height - 1), min(self.left + 2 + position - start,
                                                       self.screen.getmaxyx()[1] - 2))
            self.screen.refresh()
            key = self.key()
            self.cursor(False)
            if key == '\x1b':
                return None
            if key in ('\n', '\r', curses.KEY_ENTER):
                error = validator(text)
                if not error:
                    self.screen.erase()
                    self.screen.refresh()
                    return text
            elif secret and key == '\t':
                visible = not visible
            elif key in (curses.KEY_BACKSPACE, '\x7f', '\b') and position:
                text = text[:position - 1] + text[position:]
                position -= 1
            elif key == curses.KEY_DC:
                text = text[:position] + text[position + 1:]
            elif key in (curses.KEY_HOME, '\x01'):
                position = 0
            elif key in (curses.KEY_END, '\x05'):
                position = len(text)
            elif key == curses.KEY_LEFT:
                position = max(0, position - 1)
            elif key == curses.KEY_RIGHT:
                position = min(len(text), position + 1)
            elif key == '\x15':
                text = ''; position = 0
            elif isinstance(key, str) and key.isprintable():
                text = text[:position] + key + text[position:]
                position += 1

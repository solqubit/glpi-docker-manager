#!/usr/bin/env python3
"""Backup browser and explicit actions; Docker lifecycle stays in Bash."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import textwrap

from backup_ops import cached, managed
from terminal_ui import Terminal, translations


class Backups:
    def __init__(self, root, language, focus='', notice=''):
        self.root = Path(root)
        self.folder = self.root / 'backups'
        self.focus = focus
        self.notice = notice
        self.ui = Terminal(translations(Path(__file__).resolve().parents[1], language))

    def detail(self, path):
        data = cached(self.root, path)
        version = data.get('glpi_version') or re.search(r'glpi-([0-9.]+)-', path.name)[1]
        self.ui.context = f"GLPI {version} · {path.stat().st_size / 1048576:.1f} MiB · " + self.ui.t('backup_origin_' + data.get('origin', 'unknown'))
        recovery = self.root / 'recovery-backup'
        is_recovery = recovery.is_file() and recovery.read_text().strip() == str(path)
        verified = self.ui.t('backups_verified', data['verified_at']) if data.get('verified_at') else self.ui.t('backups_invalid' if data.get('error') else 'backups_unverified')
        labels = [str(path), f"GLPI {version} · MySQL {data.get('mysql_version') or '?'}",
                  self.ui.t('backups_origin', self.ui.t('backup_origin_' + data.get('origin', 'unknown'))),
                  self.ui.t('backups_date', data.get('created_at') or datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat()),
                  self.ui.t('backups_size', f'{path.stat().st_size / 1048576:.2f}'), verified]
        if is_recovery: labels.append(self.ui.t('backups_recovery_point'))
        if data.get('target'): labels.append(self.ui.t('backups_target', data['target']))
        width = min(100, os.get_terminal_size().columns - 6) if sys.stdout.isatty() else 76
        info = [('info', line, ('error' if data.get('error') else 'ok' if data.get('verified_at') else 'warning') if text == verified else '')
                for text in labels for line in textwrap.wrap(text, max(30, width - 2))]
        actions = [('verify', self.ui.t('backups_verify'), 'accent'),
                   ('restore', self.ui.t('backups_restore'), 'ok'),
                   ('export', self.ui.t('backups_export'), ''),
                   ('delete', self.ui.t('backups_delete'), 'warning'),
                   ('list', self.ui.t('backups_return'), '')]
        notice, style = self.notice or self.ui.t('backups_detail_help'), 'accent'
        while True:
            choice = self.ui.menu(self.ui.t('backups_details'), info + actions, len(info),
                                  notice=notice, notice_style=style, help_text=self.ui.t('setup_keys'))
            if choice is None or choice == 'list': return None
            if choice == 'info': continue
            result = dict(action=choice, archive=str(path))
            if choice == 'restore' and data.get('error'):
                notice, style = self.ui.t('backups_invalid'), 'error'; continue
            if choice == 'delete':
                if is_recovery and (self.root / 'operation.json').exists():
                    notice, style = self.ui.t('backups_protected'), 'error'; continue
                answer = self.ui.edit(self.ui.t('backups_delete'), '', self.ui.t('backups_delete_hint', path.name),
                                      lambda value: '' if value == 'DELETE' else self.ui.t('backups_delete_word'))
                if answer is None: continue
            if choice == 'export':
                def valid(value):
                    target = Path(value)
                    return '' if target.is_absolute() and target.parent.is_dir() and not target.exists() and not target.is_symlink() else self.ui.t('backups_bad_destination')
                target = self.ui.edit(self.ui.t('backups_export'), '', self.ui.t('backups_export_hint', path.name), valid)
                if target is None: continue
                result['destination'] = target
            return result

    def run(self):
        if self.focus:
            try:
                path = managed(self.root, self.focus)
                action = self.detail(path)
                if action: return action
            except (ValueError, OSError): pass
        while True:
            self.ui.context = str(self.folder)
            paths = []
            for path in self.folder.glob('glpi-*.tar.gz'):
                try: paths.append(managed(self.root, path))
                except (ValueError, OSError): pass
            paths.sort(key=lambda item: item.stat().st_mtime, reverse=True)
            rows = []
            for path in paths:
                data = cached(self.root, path)
                date = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
                version = re.search(r'glpi-([0-9.]+)-', path.name)[1]
                # Automatic (scheduled, rotated) and manual (kept until deleted) backups.
                # [M] manual (kept until deleted) · [P] before an update/restore
                # (3 kept) · [A] scheduled (5 kept).
                automatic = '-auto-' in path.name
                previous = '-pre-' in path.name
                origin = data.get('origin') or ('auto' if automatic else 'pre' if previous else 'unknown')
                origin = self.ui.t('backup_origin_' + ('auto' if automatic else origin))
                kind = '[A]' if automatic else '[P]' if previous else '[M]'
                rows.append((str(path), f'{kind} {date} · GLPI {version} · {path.stat().st_size / 1048576:.1f} MiB · {origin}',
                             'info' if automatic else ''))
            rows.append(('back', self.ui.t('ui_status_back'), 'accent'))
            total = sum(path.stat().st_size for path in paths) / 1048576
            title = self.ui.t('backups_overview', len(paths), f'{total:.1f}')
            automatic = sum('-auto-' in path.name for path in paths)
            previous = sum('-pre-' in path.name for path in paths)
            counts = self.ui.t('backups_counts', len(paths) - automatic - previous, previous, automatic)
            note = self.notice or counts + ' ' + self.ui.t('backups_help' if paths else 'backup_none')
            selected = self.ui.menu(title, rows, notice=note, help_text=self.ui.t('setup_keys'))
            if selected in (None, 'back'): return dict(action='back')
            return dict(action='inspect', archive=selected)


def main():
    os.umask(0o077)
    root, language, output = sys.argv[1:4]
    browser = Backups(root, language, sys.argv[4] if len(sys.argv) > 4 else '', sys.argv[5] if len(sys.argv) > 5 else '')
    action = browser.ui.run(browser.run)
    Path(output).write_text(json.dumps(action) + '\n')


if __name__ == '__main__':
    try: main()
    except (KeyboardInterrupt, EOFError): raise SystemExit(130)

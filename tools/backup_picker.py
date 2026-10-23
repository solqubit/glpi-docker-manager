#!/usr/bin/env python3
"""Select an archive before the verified fresh-volume restore procedure."""
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import sys
from terminal_ui import Terminal, translations


def main():
    os.umask(0o077)
    folder, language, output = sys.argv[1:]
    ui = Terminal(translations(Path(__file__).resolve().parents[1], language))
    archives = sorted(Path(folder).glob('glpi-*.tar.gz'), key=lambda p: p.stat().st_mtime, reverse=True)
    rows = []
    for path in archives:
        date = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
        match = re.fullmatch(r'glpi-([0-9]+\.[0-9]+\.[0-9]+)-.*-([a-f0-9]+)\.tar\.gz', path.name)
        label = f'GLPI {match[1]} · {match[2]}' if match else path.name
        automatic = '-auto-' in path.name
        if automatic:
            kind = '[A] ' + ui.t('backup_origin_auto')
        elif '-pre-' in path.name:
            kind = '[P] ' + ui.t('backup_origin_pre')
        else:
            kind = '[M] ' + ui.t('backup_origin_manual')
        rows.append((str(path), f'{date} · {label} · {path.stat().st_size / 1048576:.1f} MiB · {kind}',
                     'info' if automatic else ''))
    rows += [('other', ui.t('backup_choose_other'), 'accent'), ('back', ui.t('ui_back_menu'), '')]
    def choose():
        notice = ui.t('backup_none') + ' ' + ui.t('backup_none_other') if not archives else ui.t('backup_choose_help')
        while True:
            selected = ui.menu(ui.t('backup_pick_prompt'), rows, notice=notice,
                               help_text=ui.t('restore_effect'))
            if selected in (None, 'back'): return 10
            if selected == 'other':
                def valid(value):
                    return '' if Path(value).is_absolute() and Path(value).is_file() else ui.t('backup_path_invalid')
                selected = ui.edit(ui.t('backup_path'), '', ui.t('backup_path_hint'), valid, keys='confirm_edit_keys')
                # Esc on the path returns to the list.
                if selected is None: continue
            Path(output).write_text(selected + '\n')
            return 0
    return ui.run(choose)


if __name__ == '__main__':
    try: raise SystemExit(main())
    except (KeyboardInterrupt, EOFError): raise SystemExit(130)

# Changelog

## Unreleased

### Navigation
* Answering No, pressing Esc or cancelling inside the menu returns straight to the
  previous screen; no more "press Enter" after a cancellation (stop, transfer,
  credentials, updates, settings and every `die cancelled`).
* Results with nothing more to read (already up to date, nothing to refresh,
  language saved…) return at once and are shown on the dashboard status area.
* The dashboard keeps the cursor on the last action, hides the Caddy update when
  HTTPS is off, and prints the GLPI address on exit.
* Typed confirmations (RESTORE, DELETE, NEW-CA, MIGRATE…) ask again after a typo
  instead of cancelling silently; Esc on RESTORE/DELETE/NEW-CA returns to the
  backup list, Free disk space or the certificate screen.
* Installation: the version list can go back to the branch list, and Esc on the
  release notes, the GLPI 10 warning or "other version" no longer discards the
  form; imported certificates are checked before the form closes; resuming an
  installation from the menu does not ask twice.
* Schedule, log rotation and certificates: Back rows in every list, the cursor no
  longer lands on Enable/Disable after a change, choosing the current value
  changes nothing, actions that restart HTTPS ask first, and a new local CA
  shows its download URL and fingerprint.
* Restore: progress while the archive is checked, the backup's GLPI version and
  date before RESTORE, no "removing" step when nothing is removed, a readable
  result card, and the language chosen on a fresh server is kept.

### Texts
* One name for [P] backups ("pre-change backup"), warnings that no longer reappear
  on later pages, messages from failed steps shown on screen, and about 80 wording
  fixes across installation, updates, settings, backups and maintenance (ES/EN).

## 1.0.2

### Interface
* *Address* on an installed instance no longer uses installation wording: values
  show as *current* or *changed*, the actions are *Review changes* / *Leave without
  applying changes*, leaving without edits asks nothing, and nothing is applied
  when no value changed.
* Interrupted updates, backups or settings changes no longer offer *Continue the
  installation*; that option only appears for an interrupted installation.
* Context fixes across menus: update prompts ask which version to update to,
  MySQL/Caddy lookups and "already latest" messages name their component, manual
  and automatic backups are no longer called recovery backups, sub-screens offer
  *Back* instead of *Return to the main menu*, confirmation fields show
  *Enter confirm · Esc cancel*, restoring with no installation says so, and the
  local CA is no longer called self-signed.

### Performance
* The MySQL buffer pool follows the server's RAM: 25 % of it, between 256 MiB and
  8 GiB (whole GiB from 1 GiB), instead of MySQL's fixed 128 MiB. It is recalculated
  whenever the configuration is regenerated (install, updates, settings, restore),
  never by the daily job; *Diagnose* shows the applied and the next value.

## 1.0.1

### Security
* *Update HTTPS proxy (Caddy)* (`proxy-update`): applies the latest Caddy 2 image
  downloaded while GLPI runs; the previous configuration returns if HTTPS fails.
  Earlier, Caddy kept the image of the installation day.
* The daily maintenance checks for newer GLPI (PHP/Apache), MySQL and Caddy images
  and the dashboard lists them (`Updates: …`) until applied. Nothing is applied
  automatically, since every image change restarts services.

## 1.0.0

First complete release. GLPI's own settings (mail, plugins, automatic actions,
history retention) stay in GLPI; the manager handles the host and containers.

### Interface
* One visual language in Bash and curses screens: `[+]` success, `[*]` information,
  `[!]` warning, `[✗]` error, `[?]` question; compact banner and grouped help.
* Options show their consequence: `▶` recommended, `●` safe, `▲` risk/restart
  (yellow bar), `✖` destructive (red bar), `←` back, with a description line.
* Dashboard in two columns by category, with a status line (URL, HTTPS and
  certificate days, MySQL exposure, last backup, automatic backups, low disk,
  failed maintenance, kept replaced installation) and a description per action.
* Aligned configuration form and review, framed text fields with current/default
  values and a live URL preview; the server time zone is suggested.
* Live spinner details (image, health, web check); Ctrl+C restores the terminal.

### Operations
* Update GLPI lists patches (recommended newest), the next branch as a migration
  and a refreshed image of the same version. Plugins registered in GLPI are shown
  before a branch migration. The new image must be local before GLPI stops, and a
  failed apply stage offers the pre-update backup at once.
* Restore backs up a running installation first and removes the replaced one once
  the restored installation is verified; at most one replaced installation is kept
  when no backup was possible. Maintenance is scheduled after a restore too.
* Backups are tagged `[M]` manual, `[P]` before an update/restore (3 kept) and `[A]`
  automatic (5 kept). Create backup also offers the final backup for a server move.
* Daily maintenance (systemd timer or cron): log rotation, GLPI technical logs
  (20 MiB, 30 days), self-signed renewal 30 days before expiry, optional backups.
* Self-signed HTTPS uses a local CA (20 years) that signs 825-day server
  certificates renewed automatically; GLPI Agents and browsers trust the CA once
  (`gdm-ca.pem`, served at `http://SERVER/gdm-ca.pem`, included in backups).
* Log rotation screen: each kind of log with current and recommended values;
  GLPI logs, container logs and MySQL binary logs are adjustable.
* Information cards align labels of any length (accented text included) and can
  be split into sections; start-up notices no longer leak into later screens.
* Backup schedules: every day, every 2/3/N days, Monday to Friday, weekly or any
  weekdays (checkboxes), at a chosen hour and minute, with a preview of the next
  dates and the history covered.
* HTTPS and certificates in one screen: mode, expiry, renewal and reload.
* Free disk space: unused images, replaced installations, older `[P]` backups, old
  revisions and manager versions, with sizes.
* Uninstall, self-update (GitHub releases or `git pull` in a checkout), GLPI CLI as
  `www-data` (fixes the CSRF "action not allowed" error after login).
* Container logs limited to 3 × 10 MiB; parallel registry lookups; cached release
  list (15 min); Docker Hub rate limits reported.
* GLPI 10 (end of life) is listed last for new installations as a marked unsupported
  branch, with a warning and confirmation; it remains restorable
  and reachable with `install 10.x.y`.

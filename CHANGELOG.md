# Changelog

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
* New installations no longer offer GLPI 10 (end of life); it remains restorable
  and reachable with `install 10.x.y`.

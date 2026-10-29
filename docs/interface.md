# Terminal interface

Bash handles bootstrap and lifecycle operations. Configuration, the dashboard,
backup selection, status and logs use Python's optional standard-library `curses`
module. No pip UI framework, dialog or whiptail is required. Without curses or a
capable terminal, the same operations offer numbered choices.

## Navigation and editable configuration

* Up/Down or Tab moves between options; Enter accepts the highlighted option.
  The dashboard also supports Left/Right across two columns.
* Home/End selects first/last; PageUp/PageDown scrolls long selectors.
* Escape returns from every selector and text field, Bash and curses alike.
  Bash text prompts use their own line editor (not readline): Tab never lists
  files, Esc goes back, ←/→ Home/End Backspace/Delete and Ctrl+A/E/U edit. Typed
  confirmations (`RESTORE`, `DELETE`…) are cancelled with Esc, and "Press Enter"
  pauses also accept Esc.
* Escape returns from a field without changing it. From the form it opens a
  cancellation choice. Ctrl+C interrupts and restores terminal settings.
* Select a field to edit it, then return to the same highlighted row. Defaults,
  pending passwords, validation errors and accepted values have visible markers.
* Timezones use searchable region and city lists. Type to filter; Backspace
  removes a filter character. Escape from cities returns to regions.
* Text supports cursor movement, Home/End, Delete/Backspace and Ctrl+U. Passwords
  are visible initially; Tab toggles masking. Enter confirms and erases the input
  view. Empty passwords generate secure random values; there is no minimum length.
  Control characters are excluded; MySQL root also excludes quotes/backslashes
  because of the official image's initialization procedure.
* Review allows returning to a field, changing the GLPI version or cancelling
  before deployment. Changing versions preserves the other entered settings.

The defaults are `db:3306`, database/user `glpi`, HTTP 80, HTTPS 443 and timezone
UTC. Setup detects the primary routed IPv4 address and shows the resulting URL.
No `.env` preparation is needed. A busy port returns to the form for correction.
There is one installation flow, without a test/production classification.

The initial release installs directly under `/opt/glpi-docker-manager`, including
operational code and actual data folders. Open it afterward using
`sudo /opt/glpi-docker-manager/start.sh`. The dashboard shows the active root's
configuration and backup paths. `--state-dir` selects a different complete root,
with its certificates and data beneath that root too.

Run `sudo ./start.sh address` to edit access settings after installation. It
detects a LAN address when an older configuration contains `localhost`, and
offers restoring standard web ports. Review and apply before services restart.

## Dashboard and service views

The full administration menu fits an 80×24 terminal in two columns. Smaller
terminals scroll or use numbered choices. The header shows versions, aggregate
service state and the access URL. A stopped installation highlights Start.
Initial deployment starts and checks GLPI automatically; incomplete installation
has a separate resume/recovery screen. Start checks an already-running service
and starts/verifies stopped containers without reinitializing the database.

Status shows each service, version, health and published ports without long
digests or raw Docker columns. Logs have a scrollable view. Enter/Escape returns
from these views. GLPI Update lists later installable patches in the current
major and one entry for the next branch. Entering that branch shows its three
latest installable releases, newest first, with an option to show all available
releases. Esc/Back returns to the update choices. Branch changes still require
migration confirmation.
Restore/Manage backups include the archives created before updates, newest
first. The backup browser offers details, integrity checks, export, restore and
explicit per-file deletion. Typed `RESTORE`, `DELETE` and version-specific
migration confirmations remain explicit.

## Progress and completion

Bash screens and curses views share one visual language: a `GLPI Docker Manager`
header with version, magenta titles, a blue selection bar and these markers:

| Marker | Meaning |
| --- | --- |
| `[+]` | success or completed stage (green) |
| `[*]` | information (blue) |
| `[!]` | warning (yellow) |
| `[✗]` | error or failed stage (red) |
| `[?]` | question or selector |

Selector options show their consequence before Enter: `▶` recommended (cyan),
`●` safe (green), `▲` restarts services or carries risk such as a branch
migration or exposing MySQL (yellow, yellow selection bar), `✖` destructive
(red, red selection bar) and `←` back/cancel/no (dim). The highlighted option's
description appears under the list. "Yes" in confirmations that stop services,
migrate data or reveal secrets is drawn as a risk, and risky actions are never
preselected. Plain mode keeps the symbols and prints descriptions under options.

Start-up and `help` show a compact ASCII banner. The eight installation stages,
the three update stages (backup, rehearsal, apply) and MySQL updates are numbered
(`[2/8]`, `[1/3]`) and keep the completed list with each stage's duration. The
running stage shows a spinner, elapsed time and a short live detail, such as the
image being downloaded, the service being awaited or the web check attempt. The
detail comes only from the manager's own status messages, never from command
output. Slow lookups that are not stages (release list, image availability) show
the same inline spinner. Detailed output goes to private
`state/logs/install-*.log` files; failures name the failed stage and show the
relevant path. Ctrl+C restores the terminal and prints `[!] Exiting...`.

## Dashboard

Actions are grouped in two columns: Service, Updates, Manager (left) and Data,
Settings (right). Up/Down moves within a column, Left/Right jumps to the closest
action of the other column, Tab follows reading order, End selects Exit. The
status line shows the access URL, HTTPS mode and remaining certificate days,
whether MySQL is exposed, the age and kind of the last backup and the automatic
backup schedule; it turns yellow when a certificate expires within 30 days, no
backup exists or maintenance is not scheduled. The bottom line describes the
selected action. Forms show a framed input, the current and default values and,
for the address and ports, the resulting URL while typing. The server's own time
zone is suggested first.

## Maintenance, certificates and lifecycle

The manager only handles infrastructure; GLPI settings (mail, plugins, cron
tasks) stay in GLPI.

* **Daily maintenance** (`./start.sh maintenance`) is scheduled with a systemd
  timer, or `/etc/cron.d` when systemd is absent, right after installation. It
  rotates private logs (30 days, at most 200 stage logs, 1000 history entries),
  renews self-signed certificates 30 days before expiry and, when enabled, creates
  an automatic backup. It waits up to 15 minutes for an open interactive session.
  Output goes to `state/logs/maintenance-YYYYMMDD.log`.
* **Automatic backups** are configured from *Automatic backups and
  maintenance*: frequency (every day, every 2 or 3 days, every N days up to 30,
  Monday to Friday, one weekday, or any weekdays marked with checkboxes) and time
  (hour, with office hours marked as a risk, and minute 00/15/30/45). The screen
  previews the next three backup dates and how many days of history the kept
  backups cover. The task runs daily at that time; in "every N days" mode the
  count starts from the newest automatic backup, and *Run now* backs up
  immediately. They are named `glpi-<version>-<time>-auto-<id>.tar.gz`, shown as
  `[A]` (manual ones `[M]`), and only the 5 newest are kept. Manual backups are
  never rotated; pre-update/restore backups keep the 3 newest, as described below.
  GLPI stops while each backup is created.
* **Backup kinds** are visible in every list: `[M]` manual (never rotated),
  `[P]` taken automatically before an update or restore (the 3 newest are
  kept) and `[A]` scheduled (the 5 newest are kept).
* **Going back with Restore** never piles up installations. A running
  installation is backed up first (`[P]`, origin "Before restoring"); after the
  restored one passes every check, the replaced containers, volumes and data
  are removed. To go forward again, restore that `[P]` backup or update again.
  If the current installation cannot be backed up (stopped or broken), it is
  kept stopped as the only return point; at most one is ever kept, and the
  dashboard flags it.
* **Free disk space** lists, with sizes: unused images (the previous version
  is kept for a fast rollback; others are pulled again if a restore needs
  them), replaced installations (typed `DELETE`), older `[P]` backups (the
  newest stays), old configuration revisions and leftover rehearsals, and older
  manager versions. Only resources created by this manager are listed; the
  active installation and manual backups are never offered.
* **Updates** check that the new image is already local before GLPI is
  stopped, list the plugins registered in GLPI before a branch migration, and
  offer to restore the pre-update backup at once if the apply stage fails.
* **GLPI technical logs** (`/var/glpi/logs` in the official image, `/var/glpi/_log` in the classic layout; not the audit history, which
  lives in the database) are compressed with the date when they exceed 20 MiB
  and the compressed copies are deleted after 30 days. MySQL keeps its own
  30-day binary-log default.
* **Log rotation** (inside *Automatic backups and maintenance*) lists every kind
  of log with its current and recommended value, and changes the ones that grow:
  manager logs (7/14/**30**/90 days), GLPI technical logs (rotate over 10/**20**/50
  MB, keep 7/14/**30**/90 days), container logs (**10 MB × 3**, 20 × 3, 50 × 5,
  100 × 5 per service) and MySQL binary logs (1/3/7/**30** days). Container and
  binary-log changes render a new revision and restart the services after
  confirmation. The operation history keeps the last 1000 entries. Values are
  stored under `logs` in `maintenance.json`.
* **Container logs** are limited to 3 × 10 MiB per service by default. Older installations
  get the limit once from *Start / verify GLPI* (brief restart).
* **Certificates** shows the expiry date. Self-signed: renew now. Imported:
  replace the PEM files and reload. Let's Encrypt: Caddy renews automatically;
  the proxy can be restarted to retry. Expiring certificates are flagged on the
  dashboard and in the daily log.
* **Uninstall** (`./start.sh uninstall`, typed `UNINSTALL`) removes containers,
  labelled volumes of every installation ID under the root, data, revisions,
  logs and the scheduled maintenance. It keeps backups and certificates, or
  removes everything including the manager. Docker and its images stay.
* **Update this manager** (`./start.sh self-update`) downloads the latest GitHub
  release of `GDM_REPOSITORY` (default `solqubit/glpi-docker-manager`), checks
  it and restarts with it; GLPI and its data are not touched and the previous
  version stays in `manager-releases`. A Git checkout is updated with `git pull`.
* The daily job is not scheduled for test roots (`GDM_INTEGRATION`) or with
  `GDM_SCHEDULER=off`.

## Network lookups and caching

* The GitHub release list (several paginated requests) is cached for 15 minutes.
  `GDM_RELEASE_TTL=<seconds>` changes the period and `GDM_RELEASE_REFRESH=1`
  forces a new download. If GitHub is unreachable, the saved list is used with a
  warning.
* Image availability for several GLPI versions, and the MySQL and Caddy images,
  is checked in parallel (`GDM_RESOLVE_JOBS`, default 6).
* A Docker Hub rate limit (HTTP 429) is reported explicitly instead of making
  versions look unavailable; wait a few minutes or run `docker login`.

The success panel appears only after authenticated SQL, GLPI schema and web
access checks pass. It shows the URL, versions and initial web sign-in details.
A failure preserves the recovery journal and restores terminal settings.

## Basic and monochrome terminals

`NO_COLOR=1` removes colors while retaining keyboard navigation and a `>` marker.
`TERM=dumb`, non-terminal output, missing curses or very small screens use
numbered choices. To request this mode explicitly:

```bash
sudo env GDM_UI=plain ./start.sh --lang en
```

In plain text fields, `:back` returns without changes. Passwords can start masked
with `GDM_PASSWORD_VISIBILITY=hidden`. Use a UTF-8 terminal for translated text
and box drawing. Each interactive view restores echo, cursor and terminal modes
on exit or interruption.

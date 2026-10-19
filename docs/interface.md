# Terminal interface

Bash handles bootstrap and lifecycle operations. Configuration, the dashboard,
backup selection, status and logs use Python's optional standard-library `curses`
module. No pip UI framework, dialog or whiptail is required. Without curses or a
capable terminal, the same operations offer numbered choices.

## Navigation and editable configuration

* Up/Down or Tab moves between options; Enter accepts the highlighted option.
  The dashboard also supports Left/Right across two columns.
* Home/End selects first/last; PageUp/PageDown scrolls long selectors.
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
from these views. GLPI Update lists all later installable patches in the current
major and releases in the next major; the latter require migration confirmation.
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

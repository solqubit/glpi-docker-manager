# Validation evidence

Local verification on 2026-10-18 used Docker Desktop's Linux engine from a Windows
development host. The Ubuntu 24.04 test runner accessed the local Docker socket
and the repository at the same path seen by the daemon. This validates the Linux
manager inside that environment; the manager is not a native Windows installer.

## Automated checks

* All 24 unit/negative test groups passed, covering stable numeric versions,
  paginated official release discovery, image filtering, a future GLPI 13 fixture,
  distribution parsing, configuration validation, Compose password escaping,
  certificate checks, hostile/corrupt archives, bilingual prompts and interrupted
  database initialization.
* Bootstrap regression cases cover an unavailable service, plugin installation,
  package/service retry, systemd/OpenRC/service dispatch, early administrative
  access checks, custom/remote endpoints and opaque bearer-token punctuation.
  Service and package mutations are mocked in these regression cases.
* Dependency tests confirm that only missing packages are requested and that
  existing coreutils are not implicitly upgraded. Storage fixtures cover free
  capacity, exhausted inodes, temporary filesystems, EIO/ENOSPC/read-only errors
  and cleanup failure preserving the original exit status. Host disk failures
  are simulated; no real disk is disconnected or damaged in these tests.
* ShellCheck passed for the entrypoint, modules, templates and Bash tests.
* Real PTYs exercise Up/Down, Home/End, PageDown, long scrolling menus, English and
  Spanish choices, editable text, invalid-field retry, Escape, Ctrl+C, NO_COLOR,
  narrow terminals and TERM=dumb. They also cover short passwords, automatic
  generation, visible/masked input, toggling, editing and replacing wizard pages.
  Terminal settings/cursor are restored. A nested
  step failure stops immediately, shows its private log path and never announces
  success. Cancelling an operation returns to the menu and removes temporary secrets.
  Resource Back returns immediately, configuration cards retain their styling,
  and a simulated spinner or Docker I/O failure stops the manager with status 74.
* Editable curses forms cover searchable IANA regions/cities, retained values on
  review Back, cancellation, version Back, pending credentials, private atomic
  draft writes and the complete two-column 80×24 dashboard. Address detection
  excludes Docker bridges. Fixtures prove that intermediate patch versions remain
  selectable and missing image tags are excluded. Status parses both Compose
  JSON arrays and JSONL without exposing long digests or credentials.
* Root-layout cases check the installed entry point, independent operational code,
  repeatable code installation, local-volume device paths and rejection of
  symlinks that redirect the managed data directories.
* Capacity fixtures reproduce an 8 GiB free filesystem, shared engine/data
  budgets, cached versus missing images, and insufficient backup space before
  any service stop. Staging cleanup preserves saved data and rejects symlinks.
  Backup tests cover streaming nested checksums, redacted inventory metadata,
  verified export, overwrite refusal, corruption and pending-recovery protection.
* Distribution-detection smoke tests ran in Ubuntu 24.04, Debian 12, Fedora 44 and
  Rocky Linux 9.3 containers. RHEL, AlmaLinux and unknown distribution IDs were
  covered by fixtures. These are not real-machine Docker installation tests.

## Actual Docker lifecycle

The integration run used official GLPI 10.0.28, 11.0.11 and 12.0.0 images and
official MySQL 8.4.10 and 8.4.11 images. The engine reported Docker 29.8.2 and
Compose 5.6.0. Exact image digests are recorded in private test state.

The following completed with actual containers and database/file markers:

* Installation, authenticated SQL, GLPI requirements/schema and HTTP checks.
* Persistence after recreating the application container.
* A quiesced backup, followed by deliberately changed data, then restoration into
  fresh volumes with the original file and SQL values recovered.
* Automatic self-signed HTTPS with certificate verification.
* Publishing MySQL on `3306:3306` and removing that publication afterward.
* Independent MySQL 8.4.10-to-8.4.11 maintenance after an isolated rehearsal.
* GLPI 10-to-11 and 11-to-12 migrations, each rehearsed on an isolated restored
  database before applying the production operation path.
* GLPI 11.0.10-to-11.0.11 patch upgrade, followed by restoration of its automatic
  pre-update backup. Original application version, SQL marker and file marker
  were recovered; already-running Start remained idempotent.

The patch/restore scenario also runs with free-space reporting fixed to 8192 MiB
while using actual containers. This simulates the reported capacity without
filling or resizing disks; it does not certify an exact 8 GiB VM. The Bash/curses
backup browser was exercised through a PTY for inspection, verification, export,
cancelled deletion and confirmed single-file deletion using disposable archives.

Two separate actual terminal tests exercised the first-run Spanish installation
wizard using arrow keys, from Install through branch/version selection, typed
fields, settings review, all eight stages and the verified success panel. They used
GLPI 11, short manually entered passwords, default and customized settings,
self-signed HTTPS, service status and a repeated installation attempt that
preserved configuration bytes. Both confirmed `transfer` through the real terminal, verified its archive,
checked that GLPI/cron and the proxy remained stopped while MySQL stayed running,
and successfully resumed services through the explicit `start` command.

The updated wizard runs verified both standard host ports 80/443 and custom ports
18081/18444, a detected IPv4 address, certificate-verified HTTPS without SNI and
the correct HTTP-to-HTTPS redirect (including a custom HTTPS port). Existing
configuration and service volumes stay outside the Git checkout. Terminal views
were captured from actual PTYs and checked at 80×24 for readability.

The single-root wizard verifies that the installed manager entry point and code,
configuration, certificates and actual GLPI/MySQL volume devices are under its
selected root. The extended keyboard run also edits access settings, selects a
saved archive, types `RESTORE` and recovers a file marker into fresh data folders.

The administrative preflight was also executed as UID 65534 in an isolated
network-disabled container: help worked and an administrative command stopped
with the Spanish warning and exact sudo command before touching state or Docker.
The elevated diagnostic path passed against the actual local engine.

Test resources use unique project IDs and ownership labels. Cleanup removes only
those projects and their known test volumes. Existing unrelated services are
preserved. Evidence and backups remain under ignored, private `tests/.runtime/`;
they contain credentials and must not be published.

## Limits

Public ACME issuance/renewal requires a real domain and reachable public ports;
it was not exercised against a live certificate authority. The generated public
Caddyfile was adapted successfully by the official Caddy image with networking
disabled; its automation policy contained only the explicit Let's Encrypt issuer.
Imported-certificate
validation was tested locally, not with every provider's certificate chain.
ARM64 deployment, host package bootstrap, reboot behavior, SELinux on enforcing
hosts, external SQL writers, third-party plugins and business integrations need
validation in the target environment. Validation is run locally; no GitHub Actions
workflow is included. A rehearsal validates database/schema operations,
not every application workflow or future upstream release.

[English](README.md) | [Español](README.es.md)

# GLPI Docker Manager

An interactive, bilingual Linux CLI for installing and administering GLPI with
official Docker images. Bash orchestrates GLPI, MySQL and optional Caddy HTTPS;
you do not need to configure host PHP, Apache or MySQL.

## Quick start

```bash
git clone https://github.com/solqubit/glpi-docker-manager.git
cd glpi-docker-manager
chmod +x start.sh
sudo ./start.sh
```

Installation and administration require sudo/root. Without those privileges the
manager shows the exact command to run before making any system changes; `help`
and `version` remain available without root. The wizard explains missing dependencies, shows
the package procedure and asks before installing anything. It never removes an
existing Docker installation or conflicting packages automatically.

An installed but stopped Docker engine is started using the detected systemd,
OpenRC or service interface, then setup continues. Missing Compose/Buildx plugins
are offered from existing apt/dnf/yum repositories. Failed service/package actions
provide instructions and a retry option within the wizard.

Choose English or Spanish, a stable GLPI branch/version, host
ports, timezone, database credentials, MySQL exposure and HTTPS. Persistent data
folders live inside the installation root and are mounted through labelled Docker
volumes. Re-running the manager opens the
administration menu without overwriting credentials or data.

## Terminal interface

Use **↑ / ↓** to move between choices, **Enter** to select and **Esc** to cancel
or leave a menu. Language, GLPI branches/versions, HTTPS and Yes/No
questions are selectable. The editable configuration stays in one section: select
a field, edit it, then return to that field with the value retained. Defaults,
pending passwords and validated values have clear markers. Timezones use searchable
region/city lists; ports, domains and credentials use text editing. Review can
return to any field without restarting setup.

The first screen distinguishes a new installation from an existing or incomplete
one. Setup shows a private settings summary before confirmation, eight actual
installation stages, and a green **GLPI installed and verified** result with the
URL and initial sign-in instructions. This appears only after service, SQL,
schema and HTTP/HTTPS checks succeed. Detailed installation output stays in
private state logs instead of flooding the progress display.

Messages share one marker style: `[+]` success, `[*]` information, `[!]`
warning, `[✗]` error and `[?]` question. Long stages show a live spinner with
elapsed time and the current detail (image being downloaded, service health,
web check attempt). The GLPI release list is cached for 15 minutes and image
lookups run in parallel, so update and version screens open much faster.

Official release/security/support notices remain visible. Full release notes can
be opened from their selector. See [interface behavior](docs/interface.md) for
keyboard controls, monochrome and plain-terminal modes.

## Features

* Discover stable GLPI releases from the official paginated GitHub API. Show the
  latest three releases with official images for the server architecture, plus
  exact-version installation (`./start.sh install 11.0.11`). Future stable majors
  are discovered too; image/GLPI requirements still have to pass.
* Display full upstream release notes, security notices and a separate explicit
  confirmation for GLPI 10, which is outside ordinary upstream support.
* Pin GLPI, MySQL and Caddy to exact versions and immutable registry digests.
* Publish MySQL with exactly `3306:3306`, or leave it unpublished. Change this
  choice from the menu later. Publishing makes the database reachable on host
  interfaces; HTTPS for GLPI does not enable MySQL TLS.
* HTTP, automatically generated self-signed HTTPS, public ACME certificates with
  renewal, and imported certificates. Configure at installation or later.
* Stop/start, logs, status, safe credential display and diagnostics.
* Quiesced database/files backups with checksums, guided restore into fresh
  volumes and instructions for moving to a new server.
* Manage backup details, recorded origins, integrity verification, export,
  restoration and explicitly confirmed single-archive deletion from the menu.
  Space estimates run before stopping GLPI; update rehearsal/image space is
  checked separately, without a fixed 10 GiB free-space requirement.
* Update GLPI from one menu: choose any later installable patch in your branch,
  or the next major with a migration warning and explicit confirmation. Each
  version change first runs a database/schema rehearsal on an isolated restored copy.
* Independent MySQL patch maintenance within 8.4, with backup and rehearsal.
  `refresh-image` handles a rebuild of the same GLPI application version.
* Operation journal, advisory process lock, private configuration and atomic
  revisions. Failed migrations remain explicit recovery operations.

## Commands

```bash
./start.sh help
sudo ./start.sh status
sudo ./start.sh check-updates
sudo ./start.sh update                 # choose a later patch or the next major
sudo ./start.sh update 11.0.11         # exact forward target
sudo ./start.sh migrate 12.0.0         # explicit major migration, also in Update
sudo ./start.sh backup
sudo ./start.sh backups
sudo ./start.sh restore                # select a backup, including pre-update ones
sudo ./start.sh restore /absolute/path/to/backup.tar.gz
sudo ./start.sh transfer
sudo ./start.sh https
sudo ./start.sh address                # edit access IP, ports, timezone and HTTPS
sudo ./start.sh db-exposure
sudo ./start.sh credentials
sudo ./start.sh diagnose
sudo ./start.sh recover
```

Also available: `start`, `stop`, `logs`, `db-update`, `refresh-image`, `language`,
`version`. Data-changing commands require an interactive terminal and relevant
confirmations; there is no blanket `--yes` switch.

## State and credentials

The default state is `/opt/glpi-docker-manager`, outside Git:

```text
start.sh                          # installed manager entry point
manager -> manager-releases/<code>/
manager-releases/<code>/           # operational code, docs and locales
current -> revisions/<revision>/
revisions/<revision>/config.json   # private settings and credentials
revisions/<revision>/.env          # generated Compose secrets
revisions/<revision>/compose.json  # JSON is valid Compose/YAML
data/<installation-id>/            # actual GLPI/MySQL/plugin/proxy data
certs/                            # self-signed and imported TLS pairs
backups/                          # archives contain secrets
logs/                             # private operation logs
cache/                            # upstream release metadata
history.jsonl                     # completed operations; no passwords
operation.json                    # present only for an incomplete operation
```

Use `--state-dir /absolute/path` consistently to manage a different installation.
Each root has an independent project ID and data folders. Do not use the
same host ports for multiple installations. The state is protected with 0700
directories and 0600 secret files. Docker administrators can still inspect
container environments; treat Docker access as privileged. Docker images, engine
packages and runtime metadata remain managed by the system Docker Engine.

After setup, use `sudo /opt/glpi-docker-manager/start.sh`. The manager copies its
operational code into this root, so deleting the original downloaded checkout
does not remove the installed manager or GLPI data. Running a new checkout against
the same root refreshes that code copy. Use backup/transfer for consistent recovery;
copying a live MySQL data directory is not a consistent backup.

Setup marks the standard settings (`db:3306`, database/user `glpi`, HTTP 80,
HTTPS 443, timezone UTC) and lets you edit them before generating `.env`. The
server's routed IPv4 address is detected for network access. Enter your own
`GLPI_DB_PASSWORD` and `MYSQL_ROOT_PASSWORD` with no minimum length or complexity
rule, or leave them empty for secure random generation. Passwords are visible while
typing; Tab hides/shows them and submission erases the field. `credentials`
reveals them only after confirmation. The initial GLPI web accounts are upstream's
defaults (`glpi/glpi`, `tech/tech`, `normal/normal`, `post-only/postonly`); change
them in GLPI after installation. Editing `.env` alone does not rotate an existing
MySQL account. No web password is derived from the database passwords.

Application passwords support quotes, dollars and backslashes through safe init
and connection templates. The administrator password excludes quotes/backslashes
because the official MySQL root bootstrap embeds it in SQL/client configuration;
the wizard explains this restriction and offers secure automatic generation.

There is one installation flow, without a test/production classification. Use HTTPS and change the
default web accounts before opening a production service to users. Initial
accounts are intentionally not changed silently by the manager.

## HTTPS

See [HTTPS and exact certificate paths](docs/https.md). Public ACME mode needs a
domain pointing to this server and reachable ports 80 and 443. Caddy explicitly
uses Let's Encrypt for issuance and automatic renewal. Self-signed mode
generates and preserves the certificate/key automatically; trust the certificate
on each client. Imported certificates use exactly:

```text
/opt/glpi-docker-manager/certs/custom/fullchain.pem
/opt/glpi-docker-manager/certs/custom/privkey.pem
```

## Compatibility

See the [compatibility matrix](docs/compatibility.md). An unknown distribution is
allowed if its capabilities pass. The initial image architectures are amd64 and
arm64; every selected tag is checked against the registry. A local Docker Engine,
Compose V2 and Buildx are required to deploy, and can be installed by the wizard
on documented platforms. Bash 4.4+, curl, jq, OpenSSL, GNU utilities and Python 3
(standard library tools) are required and offered by bootstrap. The configuration,
service views and dashboard use Python's optional `curses` module, with a numbered
fallback when it is unavailable; no pip UI packages are required.

No fixed list of GLPI major branches is used. A new major such as GLPI 13 is listed
when upstream publishes a stable release and compatible image. The official GLPI
requirements command and installation/migration checks must succeed. If it needs
a database series beyond the manager's supported 8.4 maintenance path, a manager
compatibility update is required; it will not guess a cross-series upgrade.

## Backups, migrations and recovery

Read [data operations](docs/data-operations.md) before production use. Backups stop
GLPI and its bundled cron worker while MySQL is dumped and application volumes
are archived. Coordinate any external SQL writers separately. Backups include
encryption keys, plugins, uploaded files, configuration and TLS/ACME state.

Restore verifies checksums and archive safety **before** stopping existing
services, then uses new empty volumes and the recorded image versions. Old
volumes are retained for deliberate recovery. Only restore backups you trust:
checksums detect corruption, not an attacker's replacement of the entire archive.

An interrupted operation leaves a journal and may leave GLPI stopped. `recover`
validates the current installation; `restore` restores a known-good backup.
Changing a container image does not guarantee that a database migration is
reversible. Major migration rehearsals check database/schema compatibility, not
all plugin behavior or your business processes. Review integrations, inventory,
plugins and GLPI 12 knowledge-base permissions manually.

## Development

```bash
bash tests/run.sh
shellcheck -x start.sh lib/*.sh templates/*.sh tests/*.sh
GDM_INTEGRATION=1 bash tests/integration.sh
GDM_INTEGRATION=1 bash tests/update-integration.sh
GDM_INTEGRATION=1 GDM_TEST_FREE_MIB=8192 bash tests/update-integration.sh
GDM_INTEGRATION=1 python3 tests/backup-manager-smoke.py
GDM_INTEGRATION=1 python3 tests/wizard-smoke.py
GDM_INTEGRATION=1 GDM_WIZARD_DEFAULTS=1 python3 tests/wizard-smoke.py
GDM_INTEGRATION=1 GDM_WIZARD_DEFAULTS=1 GDM_WIZARD_EXTENDED=1 python3 tests/wizard-smoke.py
```

The integration test opts into uniquely labelled disposable Docker resources and
cleans up only its own projects/volumes. It exercises installation, persistence,
backup/restore, self-signed HTTPS and GLPI 11-to-12 migration. See
[contributing](CONTRIBUTING.md), [architecture](docs/architecture.md), and
[troubleshooting](docs/troubleshooting.md). Starting with
`GDM_TEST_GLPI_VERSION=10.0.28` also exercises the 10-to-11 path. Recorded local
results and testing limits are in [validation](docs/validation.md).

Validation runs locally with Docker; no GitHub Actions workflow is included.

## License

MIT for this manager. GLPI, MySQL, Caddy and their dependencies retain their own
licenses. This is an independent community project.

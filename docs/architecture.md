# Architecture and implementation plan

## Contract

One managed installation per state directory (default `/opt/glpi-docker-manager`).
`start.sh` is a dispatcher, not an installer monolith. Bash 4.4+ orchestrates Docker
Engine and the Compose plugin; curl, jq, OpenSSL and standard Linux utilities are
the runtime dependencies. Installation and administration require sudo/root before
bootstrap starts. Bootstrap is interactive and never removes competing
packages or guesses distribution repositories. An unlisted Linux distribution is
allowed when the actual runtime requirements are satisfied.

Configuration is data: versioned JSON, never sourced as executable shell code.
Each configuration revision lives in its own directory and `current` switches
atomically. Secrets and state are outside the checkout, permissions 0700/0600.
Official images are resolved by registry digest; tags and exact application/engine
versions are recorded separately. No permanent `latest` references.

The official images stay unmodified. Read-only templates create the application
SQL account with correctly escaped password data and check GLPI database access
using PHP getenv(), avoiding upstream environment interpolation into SQL/PHP.
The official root bootstrap requires a validated password alphabet. Non-secret
PHP/init bind files are world-readable *inside* the containers; their host parent
state directory remains private, and credentials/key files remain 0600.

## Modules

* `lib/core.sh`: translation, prompts, locks, error handling and journals.
* `lib/layout.sh`: installed code revisions, root entry point and bounded data paths.
* `lib/ui.sh`: keyboard selectors, editable fields, progress and result panels;
  loaded by core before bootstrap, without external UI dependencies.
* `lib/system.sh`: distribution/capability checks and assisted bootstrap.
* `lib/releases.sh`: paginated official releases, support notices, registry checks.
* `lib/config.sh`: validation, atomic revisions and generated Compose/PHP files.
* `lib/docker.sh`: service ownership, readiness and explicit database operations.
* `lib/tls.sh`: generated self-signed, ACME and imported PEM certificates.
* `lib/backup.sh`: quiesced backups, integrity, guided restore and transfer.
* `lib/operations.sh`: installation, updates, migrations and administration.
* `tools/terminal_ui.py`: optional standard-library curses widgets and plain fallback.
* `tools/setup.py`: private editable draft, field validation, timezone selection and review.
* `tools/main_menu.py`, `service_view.py`, `backup_picker.py`: dashboard and focused views.
* `locales/`: English and Spanish interface text; upstream logs stay unchanged.

## Persistence and recovery

The default root contains operational code, configuration, certificates, backups,
logs and actual application data. Labelled local-driver volumes bind to
`<root>/data/<installation-id>/<role>` for MySQL, all of `/var/glpi`, plugins and
proxy state. Explicit installation labels and device-path checks prevent adopting
foreign volumes. Docker engine images/metadata stay in engine-managed storage.
Backups stop the GLPI container (including its cron worker), dump MySQL logically
and archive every application volume. They contain configuration, image references,
TLS assets, UTC time and SHA-256 checksums. Restore always uses new empty volumes,
keeps old volumes, restores the original versions and requires an explicit choice
before replacing an active installation. Archives are inspected before extraction.

A persistent operation journal prevents an interrupted schema migration from
silently resuming normal administration. Do not equate a successful `compose up`
with a successful GLPI installation or migration. Validate MySQL authentication,
GLPI schema and HTTP/TLS. Database rollback is a restore operation, never a promise
that replacing an image reverses schema changes.

## Upgrade boundaries

The Update selector offers all later installable patches and the next stable
major. Major changes require a warning and explicit migration confirmation; the
`migrate` command remains available. Every version change uses official
requirements, a fresh backup and an isolated rehearsal. Plugins,
integrations and the GLPI 12 knowledge base changes need operator review. MySQL
maintenance stays in the recorded 8.4 series; cross-series migrations are outside
the automatic database operation. Rebuilding the same GLPI tag is separate from
changing the GLPI application version.

## Delivery stages

1. Foundation: discovery, bootstrap, version selection, installation and menu.
2. Administration: status, logs, lifecycle, exposure, credentials and HTTPS.
3. Data operations: backup, restore, transfer, upgrades and rehearsed migrations.
4. Validation: unit/negative tests, ShellCheck, isolated Docker integration,
   distribution fixtures and English/Spanish documentation. Tests run locally;
   no hosted CI workflow is included.

## Sources checked on 2026-10-18

* https://github.com/glpi-project/docker-images (paths, entrypoint, skip flags)
* https://github.com/glpi-project/glpi/releases (release bodies and warnings)
* https://www.glpi-project.org/en/glpi-12/ (migration and proxy requirements)
* https://glpi-install.readthedocs.io/en/latest/update.html
* https://docs.docker.com/engine/install/
* https://docs.rockylinux.org/gemstones/containers/docker/
* https://hub.docker.com/_/mysql (initialization-only environment variables)
* https://dev.mysql.com/doc/refman/8.4/en/upgrade-best-practices.html
* https://caddyserver.com/docs/automatic-https

## Material risks

Registry/network failures and rate limits must fail closed for image selection;
they must not invent available releases. Distribution fixtures are not equivalent
to installation tests on real machines. Existing database files can be changed by
new engine binaries. Plugins cannot be certified compatible from version strings
alone. Backups contain secrets and need private/off-server storage. Docker access
is privileged; the manager does not change group membership automatically.

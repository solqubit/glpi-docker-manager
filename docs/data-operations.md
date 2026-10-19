# Data operations

## Backup contents and consistency

`backup` stops GLPI and the bundled cron worker. If the managed proxy is running,
it is stopped too. MySQL stays running for a single-transaction logical dump with
routines, triggers, events and binary-safe values. Coordinate external database
writers separately; MySQL exposure is not an invitation to write during backups.

The archive contains:

* `config.json`: schema version, installation ID, exact versions/digests, settings
  and database credentials (sensitive).
* `metadata.json`: UTC timestamp, source architecture, GLPI version, actual
  MySQL version, manual/update/migration/transfer origin and any target version.
* `mysql.sql`: application database, excluding MySQL's own system databases.
* `glpi_data.tar.gz`: all of `/var/glpi`, including encryption keys and uploads;
  the disposable `files/_cache` directory is excluded.
* `plugins.tar.gz` and `marketplace.tar.gz`: custom plugins and legacy GLPI 10
  marketplace volume.
* `caddy_data.tar.gz` and `caddy_config.tar.gz`: persisted ACME/proxy state.
* `tls/fullchain.pem` and `tls/privkey.pem` when using a local/imported pair.
* `checksums.sha256`: coverage of every payload file.

Backups are private, unencrypted archives. Store off-server copies using an
encrypted transport and encrypted storage under your control. Never upload them
to public issues. The validator rejects traversal, unexpected members, duplicate
entries, special files and links. An installation containing plugin/file symlinks
is rejected during backup verification; replace those with regular files before
relying on this backup format. Failed backups are not advertised as successful.
Private staging and extracted working directories allocated by the current
operation are cleaned on exit, including failures when storage is still usable.
Saved archives are retained. I/O failures defer cleanup instead of obscuring the
original error.

Before stopping GLPI, backup creation measures application volumes and database
table/index usage. SQL serialization is budgeted conservatively at three times
table size; staging and the final archive each receive that uncompressed budget,
plus 512 MiB of filesystem headroom. The terminal shows estimated data, required
workspace and available space. Insufficient capacity stops before services are
interrupted. The final compressed size depends on the data.

## Manage backups

Choose **Manage backups** in the main menu or run `sudo ./start.sh backups` in an
interactive terminal. The browser lists archives with dates, GLPI versions, sizes
and recorded origins. Select one for its exact path, MySQL version, integrity
result and recovery-point label. Existing archives without origin metadata show
Not recorded rather than an inferred origin.

* **Verify** streams archive members, nested snapshots and SHA-256 checksums
  without creating another extracted disk copy. It does not restore GLPI.
* **Export** verifies and copies to a new absolute destination file, checks
  capacity and compares hashes. Existing files are never overwritten.
* **Restore** opens the same verified fresh-volume restoration procedure and
  requires typing `RESTORE`.
* **Delete** requires typing `DELETE` for the selected archive. Other archives
  and application data stay in place. A recovery archive referenced by an
  incomplete operation cannot be deleted.

Manual backup success is labelled separately from an automatic pre-update
backup. If rehearsal fails after backup creation, the saved archive stays
available and the live installation has not entered its migration phase yet.
Rehearsal capacity includes expanded application files, SQL import/index rebuild
allowance and database baseline files; image space is added only for missing
images.

## Guided restore and moving servers

1. Run `transfer` on the source and confirm the planned interruption. It makes
   the final consistent backup and leaves source GLPI/cron stopped. Ordinary
   `backup` resumes GLPI; `transfer` deliberately freezes it at the snapshot.
2. Copy the archive privately to the destination using your preferred SSH/SFTP
   tool. Install this repository there and run `./start.sh`.
3. Select `restore` and supply the absolute archive path. The manager checks
   archive structure/checksums and configuration **before** stopping any service.
4. Type `RESTORE` after reading the effects. A running installation is backed up
   first (`[P]`, "Before restoring"). A new installation ID and empty volumes are
   used; the backup's original GLPI/MySQL images are pulled by digest when missing.
5. The logical dump is imported into the fresh database; file/keys/plugin volumes
   are restored. Schema, authenticated SQL and HTTP/HTTPS must pass.
6. Only then is the replaced installation removed (its data is in the `[P]`
   backup). When it could not be backed up it is kept stopped as the single return
   point, replacing any older kept one; **Free disk space** removes it later.
   Daily maintenance is scheduled for the restored installation.
7. Check hostname, DNS, certificate trust, mail, inventory, cron and integrations.
   Keep the old server until the destination is verified, then switch traffic.
   Keep source GLPI stopped while the destination is active. To cancel, use
   `start` on the source. Coordinate external MySQL writers separately.

The source backup's architecture is recorded. Target image availability and actual
Docker startup still determine whether a different architecture is usable. Do not
assume third-party plugin binaries are portable. Exact images can disappear from
a registry; retain private image exports separately for long-term recovery.

If replacing an active installation, old containers are stopped and old volumes
are retained. There is no merge of writes made after the backup. Old volumes can
contain sensitive data and consume disk; their retirement is a deliberate manual
administration task, outside routine updates/restores.

## Application updates and major migrations

`update` lists every later installable stable version in the current major,
followed by the next major with a migration warning. You can choose intermediate
patches one at a time or select a later patch directly. If no forward target has
an image for the host architecture, it reports no updates. New majors cannot be
skipped; `migrate [version]` remains an explicit CLI entry point for the next major.
`refresh-image` compares the same version's current registry digest with the
recorded digest. All require a fresh backup and run the target's
requirements/migration/schema commands on an isolated restored copy first.

The rehearsal has a distinct project and volumes, no published application or
database ports, an internal Docker network, and no cron worker. The database is
restored from SQL, then the official target GLPI image runs its CLI migration.
GLPI 10 marketplace files are copied into the newer persistent marketplace path.
Only the rehearsal's labelled volumes/networks and detached data folder are
removed afterward. Current installation data and retained restore points are
kept separately under their installation IDs.

A database rehearsal is not a complete functional staging test. The operator must
review plugin support, integrations, inventory authentication, knowledge-base
permissions and reverse-proxy changes, then type a version-specific confirmation
before a major production migration. Production GLPI and cron are stopped while
the target CLI migrates the database. MySQL does not change in this operation.

For GLPI 12, review https://www.glpi-project.org/en/glpi-12/ . Future stable majors
can be discovered, but require passing target-image checks and operator review of
their actual requirements. The manager cannot certify compatibility of a release
that upstream has not published yet.

## MySQL patches

`db-update` selects a later exact patch within 8.4, backs up, rehearses with the
target engine and current GLPI, then asks for `UPDATE-MYSQL` before applying it.
Cross-series upgrades (for example 8.4 to 9.x) are not automated. No background
updater changes database images. Do not manually start an arbitrary newer MySQL
image on the production volume as a compatibility test.

## Failure recovery

`operation.json` records an incomplete operation. Mutating commands are blocked
until recovery; status, logs, diagnose, backups, restore and recover remain usable.
An incomplete initial installation can be resumed with `install`, using the
original credentials. `previous-revision` and `recovery-backup` point to relevant
recovery evidence for application updates.

Pre-update archives are immediately listed under **Restore a backup** and
**Manage backups**. Select the dated file, choose Restore, review its effect and
type `RESTORE`.
The file path is also displayed before rehearsal and after a successful update.
`sudo ./start.sh restore` opens the same picker; `backups` lists archive names for
CLI use. Restore recovers the recorded GLPI/MySQL versions and the data as of the
backup into fresh volumes; later writes are not merged. Changing only the image
tag is not a rollback after a schema migration.

`recover` requires `RESUME`, starts the **current** configuration and checks actual
readiness/schema before closing the journal. It does not reverse a migration.
For a failed schema migration, restore the known-good backup to fresh volumes.
Do not import it into a partially migrated database. Never delete production
volumes as part of troubleshooting an update.

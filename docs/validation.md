# Validation evidence for 1.0.0

Validated on **2026-10-19 (America/Guayaquil)** from a Windows development host
using Docker Desktop's Linux engine. These results apply to the 1.0.0 working
tree with the fixes described below; no commit or release was created by this
validation run.

## Environment

* Test image built from `tests/Dockerfile`, Ubuntu 24.04.5 LTS, x86_64, UID 0.
* Bash 5.2.21, Python 3.12.3, ShellCheck 0.9.0, OpenSSL 3.0.13.
* Docker Engine 29.8.2; the test image's Compose client is 2.40.3.
* Unit tests mount the checkout read-only, copy it into `/tmp/w`, and remove
  `tests/.runtime` from that copy. No Docker socket is mounted for this suite.
  Existing private test data is hidden by an empty read-only tmpfs mount to
  avoid copying gigabytes of old data only to discard it.

## Reproducing the clean unit run

From the repository root in a shell supporting the following syntax:

```bash
docker build -t gdm-tests -f tests/Dockerfile tests
docker run --rm -v "$PWD:/workspace:ro" \
  --tmpfs /workspace/tests/.runtime:ro gdm-tests bash -c \
  'cp -r /workspace /tmp/w && rm -rf /tmp/w/tests/.runtime && cd /tmp/w && shellcheck -x start.sh lib/*.sh templates/*.sh tests/*.sh && bash tests/run.sh && python3 -m compileall -q tools tests'
```

Final results:

```text
ShellCheck: exit 0, no diagnostics
tests/run.sh: 26 tests passed
Python compilation: exit 0
```

The 26 groups cover numeric release selection and future-branch fixtures;
permissive OS detection; mocked dependency/Docker bootstrap; capacity and I/O
failure handling; network address detection; the single-root layout;
configuration and Compose credential escaping; database exposure; local-CA and
server-certificate generation, hostname checks, renewal and CA replacement;
archive/checksum/link/traversal rejection; backup export and deletion protection;
maintenance retention, schedules and log settings; English/Spanish key and
format parity; real PTY keyboard interaction and curses setup/dashboard/backup
views; interrupted installation; and unprivileged help/version.

New regressions additionally check that daily schedules with an empty weekday
field retain custom log settings, that navigation keys do not accept a pause,
and that text editing, Tab handling, Escape cancellation and typed confirmations
restore terminal settings without accepting unintended input.

## Failures found and corrections

* `lib/maintenance.sh`: tab-separated parsing collapsed an empty weekday field
  into the following log-settings field. Daily schedules silently reverted
  custom log limits to defaults. A non-whitespace separator preserves the empty
  field; `tests/maintenance-cases.sh` covers the failing round trip.
* `lib/ui.sh`: the pause accepted the Escape prefix of an arrow key. It now
  consumes complete navigation sequences and accepts a lone Escape or Enter.
  The PTY regression first reproduced the premature return, then passed.
* `lib/ui.sh`: ShellCheck SC2015 rejected an `A && B || C` color-selection
  expression. An explicit `if/else` makes its behavior unambiguous.
* `lib/operations.sh`: ShellCheck SC2016 flagged intentional variables inside
  the container's shell command. A narrowly scoped annotation documents why
  expansion must remain inside the container, keeping database credentials out
  of host command arguments.
* `tests/integration.sh`: the new CA-download probe used the Docker Desktop bridge
  hostname as its HTTP Host, which did not match Caddy's configured site. The
  probe now uses `--connect-to` to retain the configured hostname. Teardown in
  both integration scripts attempts all owned resources even if an individual
  removal fails, so subsequent runs can release their fixed test ports.

No test was removed and no certificate, credential or archive validation was
weakened. The CA integration checks were extended to include a CA download,
leaf renewal and recovery of the backed-up CA after deliberate replacement.

## Actual Docker lifecycle

Integration tests run as root in separate disposable Compose projects, with the
checkout mounted at the same absolute path used by the Docker daemon. They use
the Docker socket, official images pinned by digest, and private state beneath
`tests/.runtime`. Scheduling is disabled with `GDM_INTEGRATION=1` and
`GDM_SCHEDULER=off`; unrelated running containers are preserved.

`GDM_INTEGRATION=1 bash tests/update-integration.sh` completed successfully using
GLPI 11.0.10 and 11.0.11 with MySQL 8.4.11. It verified installation, a quiesced
pre-update backup, an isolated restored rehearsal, application of the selected
patch, backup integrity/origin, and restoration of the original GLPI version,
SQL marker and file marker. Start/verify also succeeded after restoration.

`GDM_INTEGRATION=1 bash tests/integration.sh` also completed successfully. It
verified GLPI 11.0.11 installation, authenticated SQL/schema/HTTP, public CA
download, trusted HTTPS, leaf renewal without changing the CA, container
recreation, a quiesced backup, MySQL exposure on/off, and restoration into fresh
volumes. Before restoring, the test deliberately replaced the live CA; the
archive recovered the original CA and key and could sign another valid server
certificate. SQL/file markers survived. The 11-to-12.0.0 migration then passed
both its isolated rehearsal and the actual apply/readiness path.

MySQL stayed on 8.4.11; no newer patch was available for the optional independent
database-update branch. The resolved Caddy image was 2.11.7. Exact image
references remain in private test configurations; credentials and backups are
not published.

Local evidence files (ignored by Git):

* `tests/.runtime/validation-100-unit.log`
* `tests/.runtime/validation-100-integration.log`
* `tests/.runtime/validation-100-update.log`

## Limits

Public Let's Encrypt issuance/renewal, Windows/macOS trust-store deployment,
ARM64 hardware, real-machine package bootstrap, systemd/cron execution across
reboots and SELinux enforcement remain outside this evidence. The VM follow-up
below adds real systemd execution, manager self-update and uninstallation; no
production host was used. A successful database rehearsal does
not certify every plugin, application workflow or future upstream version.
The clean unit suite uses fixtures for external failures and host mutations;
these results do not represent a native Windows installation of the manager.

## Disposable Ubuntu VM follow-up

On **2026-10-19**, the user supplied a disposable VM after the initial access
check. These results supersede the earlier pending checklist. The VM ran Ubuntu
24.04.5 LTS, kernel 6.8.0-147-generic, systemd as PID 1, Docker Engine 29.9.1,
2 vCPUs, 1959 MiB RAM, 2047 MiB swap and a 17282 MiB root filesystem. SSH used
the `ubuntu` account and sudo; manager operations ran as root. The state root
was `/opt/glpi-docker-manager`, with real host scheduling enabled. No production
server or unrelated Docker Desktop workload was used for lifecycle operations.

The existing GLPI 11.0.11 installation used self-signed HTTPS on the VM IP.
First, the Git self-updater advanced the user's checkout from `da6ea13` to
`b4402c9`; then testing used that code plus the dashboard correction below.
A manual backup and the CA hash were saved before removing the initial
installation. A fresh wizard installation of 11.0.9 used the detected VM IP,
ports 80/443, self-signed HTTPS and generated database passwords. It passed
SQL/schema/web checks and retained the original CA. MySQL was 8.4.11 and Caddy
2.11.7. SQL and file markers were added for subsequent recovery checks.

Menus were driven through real PTYs in supported plain/numbered mode, including
confirmations. This is functional UI evidence, not a visual review of ANSI colors.

| Requested check | Status | Actual result |
| --- | --- | --- |
| 1. Scheduled maintenance | OK, with timing-method limitation below | The real systemd timer fired unattended at 08:36 UTC, returned `Result=success` / `ExecMainStatus=0`, wrote `maintenance-20261019.log`, created a new `-auto-` archive and recorded status `ok`. Daily retention kept five automatic archives without changing the manual archive's SHA-256. Every-two-days skipped recent data and backed up after aged mtimes. Monday-to-Friday was due on actual Monday and not due with a Sunday date fixture. The dashboard showed the latest automatic backup. Changing time through the menu changed `OnCalendar` to `23:45:00`. |
| 2. Log rotation | OK | The menu applied container logs `20m` / `3` and MySQL `--binlog-expire-logs-seconds=259200`, recreated services and passed readiness checks. Actual container inspection confirmed the logging configuration. Unattended maintenance compressed a 21 MiB `/var/glpi/logs/gdm-vm-validation.log` written as `www-data`, with a dated gzip file, and emptied the original. Decompression returned exactly 22020096 bytes. |
| 3. Free disk space | OK | Real upgrades 11.0.9 → 11.0.10 → 11.0.11 passed backup, rehearsal and apply. Cleanup offered 11.0.9 and protected active 11.0.11 and previous 11.0.10. Its menu removed the old image, unused revisions and older `[P]` archives; the manual archive and readiness checks remained intact. After the stopped restores, cleanup protected active 11.0.10 and kept 11.0.9 and removed unused 11.0.11. |
| 4. Running and stopped restores | OK | A running restore created a new `[P]` archive with origin `restore`, recovered 11.0.10 and baseline SQL/file markers, and removed the replaced containers, labelled volumes and data directory. Two successive stopped restores recovered 11.0.9 and 11.0.10; each left exactly one previous installation and two data directories total. The dashboard displayed `1 replaced installation kept` after both. |
| 5. Failed update and rollback | OK | A temporary launcher outside the repository returned 42 from `oneoff_action update` only in the live migration phase. Rehearsal succeeded first. The actual failure displayed the recovery offer; choosing Restore and typing `RESTORE` recovered 11.0.10, baseline SQL/files, healthy services and a closed journal. One failed/replaced installation was kept, as documented. The temporary fault entry point was removed. |
| 6. Manager self-update | Git OK; published-release path unavailable | The actual self-updater pulled as checkout owner `ubuntu`, restarted into the dashboard, changed the installed manager link from `manager-releases/bb4ca96c86841a67` to `manager-releases/9485e2dd80c1d6a9`, and preserved file/FETCH_HEAD ownership. Installed code matched the updated checkout. GitHub returned an empty releases list and HTTP 404 for `v1.0.0`; the installed release updater consequently showed its unavailable-release warning. No release was created. |
| 7. Keep-data uninstall and CA recovery | OK | The final keep-backups/certificates uninstall left no `gdm_` containers or volumes, data directory or timer files/listed timers. Docker remained usable and backups plus the CA certificate/key remained. Restoring the initial manual archive recovered healthy GLPI 11.0.11 with the same CA SHA-256, no kept installations and no operation journal. |

### Scheduling and fixture details

The schedule menu offers minutes 00/15/30/45, not an arbitrary minute. Daily
backups and a normal time were first selected through that menu. To test an
unattended run three minutes ahead, the harness used the real
`maintenance_write` / `scheduler_install` functions with an exact minute; it
did not change the VM clock or replace systemd. The later 23:45 change used the
menu and was checked through `systemctl show`.

Retention fixtures were copies of a valid archive with automatic-backup names
and aged filesystem mtimes. Native maintenance then created real new automatic
archives and pruned to five. The two-day and weekday settings/due rules were
exercised through native maintenance functions; only the Sunday weekday reading
was substituted. Unused configuration revisions were created by `config_stage`
without activating them, then offered and removed by the actual cleanup menu.

Early harness retries corrected missing `ARCH` initialization, the tar member
name `./metadata.json`, and the log path used to verify an injected failure in
plain mode. These were harness errors, not product fixes. The incomplete backup
from the first harness error was recovered using the real `recover` command,
with SQL/schema/web verification and journal closure, before retrying retention.

### Product failure and regression

`tools/main_menu.py` classified the newest backup as either automatic or manual,
so a genuine `-pre-` archive appeared as **Manual** in the VM dashboard. It now
recognizes the pre-update/restore category using the existing
`backup_origin_pre` translation. No locale keys or security checks changed.

`tests/test_setup.py` checks manual, automatic and pre-update/restore dashboard
labels in both English and Spanish. The new test failed on the old code, then
passed after the correction. The same fix was applied to the VM checkout and
verified through the real dashboard, which displayed **Before an update or
restore** for its latest `[P]` archive.

### Final unit/static run for this follow-up

The clean image was rebuilt from `tests/Dockerfile`. After the dashboard fix,
the read-only checkout/copy command documented above was repeated without a
Docker socket:

```text
docker build -t gdm-tests -f tests/Dockerfile tests: exit 0
ShellCheck: exit 0, no diagnostics
tests/run.sh: 26 tests passed
```

English/Spanish key/format parity passed. The local summary is retained in the
ignored `tests/.runtime/validation-100-vm-unit.log`. Private VM harness scripts,
PTY logs, the copied scheduled-result JSON, CA hashes and recovery checkpoints
are under `/root/gdm-vm-validation`; original installation logs were inspected
before uninstallation removed them. No passwords or archives are published.
No commit or push was performed.

The VM was left running the recovered initial GLPI 11.0.11 installation at
`https://192.168.0.33`, using the original CA and the locally corrected manager.
The temporary fault entry point is absent. The development host's unrelated
Docker services were preserved. This completes the requested VM checks except
the unavailable published-release path and the explicit method limitations above.

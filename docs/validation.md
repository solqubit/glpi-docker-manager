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
reboots, SELinux enforcement, manager self-update and host uninstallation were
not exercised against production hosts. A successful database rehearsal does
not certify every plugin, application workflow or future upstream version.
The clean unit suite uses fixtures for external failures and host mutations;
these results do not represent a native Windows installation of the manager.

# Troubleshooting

Run `sudo ./start.sh diagnose` for distribution/architecture, Docker/Compose,
available disk, non-secret settings and service/certificate status. `logs` shows
the latest 150 lines. Raw upstream logs may contain application data: sanitize them
before sharing. The manager's own diagnostics do not dump environments/passwords.

## Docker exists but is inaccessible

Run installation/administration with `sudo ./start.sh`; an early warning prints
the exact resume command when root privileges are missing. Once elevated, the
manager starts an unavailable default engine through systemd, OpenRC or service
and continues. Failed service actions show status/log commands and allow a retry
without leaving the wizard. The script intentionally does not reinstall Docker or grant
permanent Docker group membership. In Docker Desktop development environments,
enable the desired Linux/WSL integration yourself or run the isolated test runner.
Remote contexts are rejected because host bind paths would refer to another host.
For custom/rootless endpoints, use the specific service instructions shown by the
wizard; it does not start an unrelated rootful engine. Missing plugins are treated
separately from engine availability and offered from configured apt/dnf/yum repositories.

## Missing tools or unsupported automatic bootstrap

The wizard offers runtime dependencies through a detected package manager. If
Docker installation is not documented for the detected distribution, prepare
Docker Engine/Buildx/Compose manually and run again. The distribution ID itself
does not prevent using a functioning runtime. Do not replace repositories with a
different distribution codename simply to get past bootstrap.

## Version/image discovery fails

Check access to GitHub, Docker Hub and the Docker registry. GitHub unauthenticated
requests have rate limits; optionally export a GitHub read token as `GITHUB_TOKEN`
without writing it into this repository. No cached list is silently treated as
current after a network failure. Only stable, non-draft releases and images that
advertise the host Linux architecture are offered.

## GLPI is not ready

Inspect `logs` and `operation.json`. MySQL startup may take several minutes.
Readiness requires authenticated SQL, container health, GLPI schema consistency
and an HTTP/TLS probe. Resume an incomplete first installation using `install`;
it preserves the original settings and credentials. After a failed update, use
the recovery guidance rather than trying arbitrary image tags.

## Host Input/output errors during image downloads

If ordinary host tools such as `ls`, `df`, `sudo`, `sleep` or `rm` also fail with
`Input/output error`, investigate system/storage availability before retrying.
The manager cannot determine from that message alone whether the cause is a
disconnected virtual disk, a full backend, filesystem damage or a host outage.
On Vates/XCP-ng, inspect the VM's VDI attachment, its SR and host/storage alerts
from Xen Orchestra. Multiple affected guests point to a shared host/storage
incident. Reattaching a disk may not recover a guest that already encountered
filesystem errors. Use a verified snapshot/rescue procedure when necessary.

When tools work, collect `df -h`, `df -i`, `docker info --format
'{{.DockerRootDir}}'` and kernel logs. Docker 29's containerd image store can also
use `/var/lib/containerd`, separate from DockerRootDir. Capacity inside the guest
does not establish free capacity on a thin-provisioned SR.

Recognized I/O, read-only and no-space errors in a step log stop the interactive
manager with status 74. Spinner failures are logged privately and do not loop.
Cleanup errors preserve the original failure status and report that private
temporary files may remain. Recovery messages are best effort if the OS can no
longer execute programs or read the log. No automatic disk repair, remount,
hypervisor disk operation or Docker prune is performed.

## HTTPS fails

If the configured URL contains `localhost` or unwanted nonstandard ports,
update the manager code and run `sudo ./start.sh address`. Set the VM's actual LAN
IPv4 address, select standard ports 80/443 if available, review and apply. This
preserves database volumes and credentials. Self-signed certificates are
regenerated when the configured address changes. The proxy supports IP clients
without SNI and redirects HTTP to the configured HTTPS port. A protocol error is
different from a certificate trust warning.

Check `status` for actual published ports. Test from the VM and another machine
on the same LAN; if local access succeeds but remote access fails, inspect VM
network mode, routing and host/network firewall rules for those ports. The
manager does not silently change firewall policies. With default ports use
`http://SERVER_IP` or `https://SERVER_IP`; custom ports need `:PORT` in the URL.

For ACME, check public A/AAAA records, inbound 80/443, outbound HTTPS and Caddy
logs. A running container alone does not mean a certificate was issued. For
self-signed certificates, import the public certificate into clients' trust
stores. For custom pairs, verify the exact paths in [HTTPS](https.md), matching
key, SAN hostname and chain. The probe rejects expired/untrusted certificates.

## Password changed in .env but login fails

MySQL initialization variables create accounts only on an empty data directory.
Editing `.env` cannot rotate a populated database's passwords. Restore the matching
configuration and use a deliberate coordinated SQL/configuration rotation procedure.
The GLPI web accounts have separate credentials managed inside GLPI.

## Backup fails validation

Do not restore that backup. Check available disk, dump output, permissions and
unsupported symlinks. A valid backup includes keys and files, not just SQL.
Keep backups and private intermediate work under protected storage. Checksums do
not establish who created an archive: restore only trusted backups.

## Database published but remote connection fails

The binary option publishes `3306:3306`. Check cloud security groups, routing and
Docker's actual publishing rules. Host UFW/firewalld policies do not necessarily
filter Docker-published ports in the way ordinary host services are filtered.
See https://docs.docker.com/engine/network/packet-filtering-firewalls/ .

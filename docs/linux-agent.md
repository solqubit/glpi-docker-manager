# Automatic Linux agent installation

The agent is installed **on the computer to inventory**, not in the GLPI server
container. The GLPI server publishes public bootstrap resources; clients download
the official upstream agent directly from GitHub. No new installation-wizard
question is added. Publication is enabled by default and can be disabled under
**Settings → Linux agent · Automatic installation**.

## Existing installations

Update this manager's code as usual, then open `sudo ./start.sh`. On the first
normal administration session, an existing running installation without these
resources gets a new configuration revision. Services restart briefly and access
is verified; failure restores the previous revision. This transition is done once.
An explicitly disabled installer is never enabled again automatically. A stopped
installation is left stopped; resources are applied when you choose Start.

## Install on another computer

1. On the GLPI server, open **Linux agent · Automatic installation → Show the
   installation command**, or run:

   ```bash
   sudo /opt/glpi-docker-manager/start.sh agent-command
   ```

2. Copy the **entire generated `sudo bash -c ...` line** through a trusted server
   session. On the Linux computer to inventory, paste and run that line. Root
   users without sudo can omit its initial `sudo`. The client needs Bash,
   coreutils (`sha256sum`, `mktemp`) and either curl or wget to bootstrap. Missing
   curl, OpenSSL, CA bundles and libcrypt dependencies are subsequently installed
   using apt, dnf, yum or zypper when needed; the OS is not broadly upgraded.

3. The installer verifies the server, downloads the pinned official GLPI Agent
   **1.21 x86_64 AppImage**, checks its published SHA-256, extracts it, configures
   the agent, sends the first inventory in the foreground and enables its systemd
   service for later inventories. Extraction followed by `AppRun` requires no
   FUSE installation or `/dev/fuse`. Existing agent identity under
   `/var/lib/glpi-agent` is preserved when this command is repeated.

4. In GLPI, inventory must be enabled under **Administration → Inventory**.
   Verify the imported computer there. Server import rules can reject or ignore
   a submission even if the agent reports no transport error. This installer
   configures unauthenticated native inventory; deployments requiring inventory
   OAuth or Basic authentication need their authentication configured separately.
   A transport error fails installation verification and prints the log location.
   The persistent service is still enabled for retries; an agent service that
   was running before a failed reconfiguration is started again.

Supported clients: **Linux x86_64 with glibc**, with a running systemd for the
persistent service. Debian/Ubuntu and RHEL-family clients are the primary targets.
ARM and Alpine/musl are not supported by this AppImage. The installer refuses a
native/package-managed agent rather than silently replacing its package files.
Uninstall it through its original method first, or keep using that method.

## HTTP and HTTPS

| GLPI mode | Client configuration |
| --- | --- |
| HTTP | Uses the configured HTTP hostname/IP and port. No CA is installed. Inventory traffic is unencrypted. |
| Public HTTPS / Let's Encrypt | Uses HTTPS and the agent's normal public certificate trust. No leaf fingerprint is pinned. |
| Local CA | Downloads the public CA, verifies its embedded SHA-256 and uses `ca-cert-file`. |
| Imported private CA | Before publishing/refreshing, place its PEM CA bundle at `/opt/glpi-docker-manager/certs/custom/agent-ca.pem`. It must verify the server certificate. Only that public bundle is distributed. |

If an imported certificate is publicly trusted, no `agent-ca.pem` is needed.
The manager does not guess a private CA from an SSL error. No `--insecure`,
`no-ssl-check` or HTTPS-to-HTTP fallback is used.

Bootstrap resources are served on the configured **HTTP port**, including with
HTTPS enabled, to avoid needing the local CA before it can be downloaded. Their
authenticity comes from the expected installer hash copied from the trusted
manager session. The verified script embeds the expected CA and agent hashes.
An unverified `curl http://SERVER/agent/install.sh | sudo bash` is **not** an
equivalent command and should not be used.

The URLs are port-aware:

* `http://SERVER[:PORT]/agent/install.sh`: generated installer.
* `http://SERVER[:PORT]/agent/bootstrap.json`: public metadata (no credentials).
* `http://SERVER[:PORT]/agent/ca.pem`: public CA, only when a private/local CA is used.
* `http://SERVER[:PORT]/gdm-ca.pem`: existing local CA download for other clients.

HTTPS also serves `/agent/` resources. Other HTTP routes continue to redirect to
HTTPS. With HTTP-only GLPI, only the public `agent/` directory is mounted under
the Apache public directory. Configuration, `.env`, private keys and backups are
never exposed by these routes.

## Files and service on the client

* `/opt/glpi-agent/appimage-1.21/`: extracted official application.
* `/usr/local/bin/glpi-agent`: official executable wrapper.
* `/etc/glpi-agent/conf.d/99-gdm.cfg`: manager-owned server/TLS settings.
* `/etc/glpi-agent/certs/gdm-ca.pem`: public CA, when required.
* `/var/lib/glpi-agent/`: persistent identity and agent state.
* `/var/log/glpi-agent/gdm-bootstrap.log`: first inventory output.
* `/etc/systemd/system/glpi-agent.service`: automatic background inventories.

```bash
sudo systemctl status glpi-agent
sudo journalctl -u glpi-agent --no-pager -n 50
sudo tail -n 50 /var/log/glpi-agent/gdm-bootstrap.log
```

## Refresh or disable

Use the administration menu to refresh resources after changing an imported CA,
or to disable publication. CLI equivalents (confirmation required):

```bash
sudo /opt/glpi-docker-manager/start.sh agent-setup publish
sudo /opt/glpi-docker-manager/start.sh agent-setup disable
```

Disabling publication removes the routes/mount at the next verified revision.
Already installed agents keep working. Regenerate and redistribute the command
after changing the address, ports, CA, language or installer. A changed address
also needs the agent configuration updated; rerunning the new command does so
without resetting identity. Ordinary leaf-certificate renewal under the same CA
does not require reinstalling the agent.

For an intentional one-shot/container installation, generate a command with
`sudo ./start.sh agent-command --once`. It installs and sends one inventory but
does not create or enable a service. This is not the default for regular machines.

## Validation

`tests/agent-cases.sh` runs with the main unit suite. Optional real containers:

```bash
docker build -t gdm-tests -f tests/Dockerfile tests
GDM_AGENT_INTEGRATION=1 python3 tests/agent-integration.py
```

The integration creates uniquely named disposable GLPI/MySQL/Caddy and Linux
client containers, verifies actual imported inventories and tampering rejection,
then removes only its containers, anonymous volumes, network and image tags.
It leaves evidence in ignored `tests/.runtime/`. It does not need privileged
clients, FUSE, a host Docker socket inside the clients or a production server.

Upstream references: [AppImage installation](https://glpi-agent.readthedocs.io/en/1.21/installation/linux-appimage.html)
and [release/checksums](https://github.com/glpi-project/glpi-agent/releases/tag/1.21).

# HTTPS

Run `sudo ./start.sh https` at any time. Modes are `off`, `self-signed`, `acme`
and `custom`. A configuration revision is validated before applying; a failed
readiness check reactivates the preceding configuration. HTTPS changes can briefly
restart services. GLPI is not directly published while the managed proxy is used.

## Self-signed HTTPS with a local certificate authority

The manager creates a **local CA valid for 20 years** and a server certificate
signed by it (3072-bit RSA, DNS or IPv4 SAN for the configured address, valid
825 days so Apple platforms accept it):

* `/opt/glpi-docker-manager/certs/self-signed/ca/gdm-ca.pem`: the CA certificate,
  the **only file to distribute** (also served at `http://SERVER/gdm-ca.pem`).
* `/opt/glpi-docker-manager/certs/self-signed/ca/gdm-ca.key`: CA private key,
  0600, never distributed; included in backups so a restore keeps the same CA.
* `/opt/glpi-docker-manager/certs/self-signed/fullchain.pem` and `privkey.pem`:
  the server certificate (leaf + CA) and its key.

Clients trust the CA once. The server certificate is renewed automatically 30
days before it expires, when the address changes or on request, always signed by
the same CA, so **GLPI Agents and browsers never need to be touched again**.
*HTTPS and certificates* shows the download URL, path, expiry and SHA-256
fingerprint of the CA. *Create a NEW local CA* (typed `NEW-CA`) exists only for a
lost or compromised CA key; every client must then import the new file.

### GLPI Agent

Copy `gdm-ca.pem` to each computer, for example `C:\CA-GLPI\gdm-ca.pem`, before or
after installing the agent (it is read on every connection, not at install time).
In the installer's *Remote Targets SSL Options*: *CA Certificate File* = that
path; leave *CA Certificates Directory* and *Fingerprint* empty and do not
disable the SSL check. Unattended Windows example:

```powershell
New-Item -ItemType Directory -Force C:\CA-GLPI | Out-Null
Invoke-WebRequest http://192.168.0.33/gdm-ca.pem -OutFile C:\CA-GLPI\gdm-ca.pem
msiexec /i GLPI-Agent-x64.msi /quiet SERVER="https://192.168.0.33/" CA_CERT_FILE="C:\CA-GLPI\gdm-ca.pem"
```

On Linux use `ca-cert-file = /etc/glpi-agent/gdm-ca.pem`. Do not pin the server
fingerprint: it changes with every renewal. Browsers: import `gdm-ca.pem` as a
trusted root authority (by GPO in a domain).

Moving to another server by restoring a backup keeps the CA; with the same
address nothing changes on clients, with another address only the agents' server
URL changes. A DNS name instead of an IP avoids even that. Earlier revisions retain
their original pair. Custom certificates are validated and never automatically
replaced.

HTTP 80 and HTTPS 443 are the default host ports, so the URL needs no port suffix.
Other ports remain configurable. HTTP redirects explicitly to the configured
HTTPS port. The proxy sets a default TLS server name for IP clients without SNI;
the certificate SAN still must match the configured address. Use `address` to
replace an older `localhost` configuration with the server's LAN IP.

## Public HTTPS with Let's Encrypt

Use a public DNS name, for example `glpi.example.org`, pointing to the server.
Host TCP 80 and 443 must be reachable; Caddy needs outbound HTTPS. Incorrect AAAA
records can prevent validation even if A is correct. The basic automatic mode
uses these standard host ports. Wildcard/DNS-provider automation is not included.

Caddy explicitly uses the Let's Encrypt ACME directory to obtain and renew
certificates automatically. The wizard identifies this option by name and
explains domain/DNS and port requirements. Its `/data` and
`/config` are persisted and backed up. The manager verifies HTTPS, not merely that
the proxy container started. Never use a production ACME CA for repeated automated tests.

## Imported certificates: exact paths

Create the private directory:

```bash
sudo install -d -m 0700 /opt/glpi-docker-manager/certs/custom
sudo install -m 0600 /your/provider/fullchain.pem /opt/glpi-docker-manager/certs/custom/fullchain.pem
sudo install -m 0600 /your/provider/privkey.pem /opt/glpi-docker-manager/certs/custom/privkey.pem
sudo ./start.sh https
```

Select `custom` and enter the domain covered by the certificate.
`fullchain.pem` must contain the leaf/domain certificate first, followed by its
intermediate CA certificates, in PEM format. `privkey.pem` must be the matching
unencrypted PEM private key. A `.pfx` file cannot be converted by renaming it.

For a PKCS12/PFX input, perform conversion in a private directory:

```bash
umask 077
openssl pkcs12 -in provider.pfx -clcerts -nokeys -out leaf.pem
openssl pkcs12 -in provider.pfx -cacerts -nokeys -out intermediates.pem
cat leaf.pem intermediates.pem > fullchain.pem
openssl pkcs12 -in provider.pfx -nocerts -nodes -out privkey.pem
```

OpenSSL asks for the input password interactively. Install the files into the
exact paths above. The manager checks validity (at least another day), hostname/IP
and public/private key matching before application. Public trust/complete chain
is also checked by the final HTTPS probe. For a private CA, configure that CA in
the server/client trust stores. Imported certificates are renewed by their owner;
replace the files and run `https` again. Backups include the active revision's pair.

The managed proxy forwards original host/protocol/client IP; GLPI 12 trusts only
the proxy resolved on its dedicated per-project network. HTTPS cookies are
enabled for HTTPS modes. IPv6 literal service names are not supported initially.

# Security policy

Do not publish credentials, database dumps, backup archives or private keys in
issues. For a suspected vulnerability, use this repository's GitHub private
vulnerability reporting if enabled, or contact the maintainer privately before
publishing details. Do not open a public issue containing exploit secrets.

Only use current manager releases and supported GLPI/MySQL versions for production.
The manager can offer old GLPI versions for compatibility, with warnings; that
does not restore upstream security support. Initial GLPI web passwords are the
official defaults and must be changed by the administrator.

Docker access is privileged. State and backups contain secrets. SHA-256 checksums
detect corruption but do not authenticate a maliciously replaced backup.

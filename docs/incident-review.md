# Host I/O incident review

An Ubuntu VM reported errors during step 2 of installation, followed by host
`sleep`, `rm`, `df`, `sudo`, `tail` and `ls` failing with `Input/output error`.
The initial trace pointed to the MySQL image pull. No GLPI/MySQL application
containers had been started by the installation pipeline at that point.

The user later observed a detached virtual disk, then reported simultaneous disk
errors across their VMs and a suspected power interruption. This is consistent
with a shared host/storage incident. It does not establish the exact initiating
event; hypervisor/storage/kernel logs were not available for this review.

The installation path was audited for host writes, package operations, image
pulls, mounts, permissions and cleanup. It contains no Vates/Xen Orchestra API
calls, guest disk detach operations, formatting or partitioning. Image pulls
write through the existing Docker engine; configuration mounts are read-only
and container data uses separately labelled volumes.

Two independent installer weaknesses were found and corrected: requesting a
whole dependency package list could update already-installed packages such as
coreutils, and the resource check inspected the manager state filesystem without
checking Docker/containerd capacity. Packages are now limited to absent tools,
APT requests exclude removal/upgrading of already installed named packages, and
image pulls check accessible engine filesystems and free inodes. These findings
are not proof of the incident's cause.

Regression tests cover these changes and simulated I/O failures. Local Docker
verification cannot reproduce or certify recovery of the user's Vates SR/VDIs.
See [troubleshooting](troubleshooting.md) for evidence collection and recovery.

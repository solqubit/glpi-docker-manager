# Compatibility

Installation/administration must run as root or through sudo; help/version do not
need elevation. Compatibility is capability-based. An unlisted distribution is not rejected just
because of its ID. Runtime needs Linux, Bash 4.4+, a local functioning Docker
Engine with Compose V2 and Buildx, curl, jq, OpenSSL, tar/gzip, coreutils, util-linux,
iproute2 and Python 3. The wizard offers missing dependencies through apt, dnf/yum,
zypper, pacman or apk. A documented Docker installation plan is separately required
to automatically add Docker repositories.

| Distribution | Docker bootstrap | Validation status |
|---|---|---|
| Ubuntu | Official apt repository, detected codename | Detection fixtures; Ubuntu 24.04 container smoke test/integration runner |
| Debian | Official apt repository, detected codename | Detection fixtures; Debian 12 container smoke test |
| Fedora | Official Fedora Docker repository | Detection fixtures; Fedora 44 container smoke test |
| RHEL | Official RHEL Docker repository | Detection fixtures |
| Rocky Linux | RHEL repository per Rocky documentation | Detection fixtures; Rocky 9.3 container smoke test; host installation not certified |
| CentOS | Official CentOS Docker repository | Capability checks; host installation not certified |
| AlmaLinux | Reuse functioning Docker; manual Docker preparation | Detection fixtures; repository mapping not guessed |
| Other Linux | Reuse functioning Docker; manual Docker preparation | Allowed when capabilities pass |

Distribution versions must still be supported by their Docker repository. Apt
bootstrap checks the exact codename's Release metadata before adding the source.
The script never uses `--allowerasing`, removes Podman or changes Docker group
membership. An installed but stopped Docker daemon is started through systemd,
OpenRC or service and checked again. Failures provide instructions and an in-place
retry. Existing-engine Compose/Buildx plugins can be installed from configured
apt/dnf/yum repositories; other package managers get manual plugin instructions
and retry. Custom/rootless sockets are never replaced with a different engine.

Image platform selection supports amd64 and arm64. All chosen image manifests
must contain the server's Linux architecture. An image's existence does not prove
that every plugin supports the architecture. ARM64 integration and real-system
Docker bootstrap are not implied by unit tests.

Default persistence uses labelled local-driver volumes bound to directories under
`/opt/glpi-docker-manager/data/<id>/`, without world-writable permissions.
Read-only configuration bind mounts request private SELinux relabelling.
SELinux should stay enabled; never solve a permissions problem with chmod 777.
Remote Docker contexts are not supported because bind paths belong to this host.

Minimum enforced bootstrap resources: 1 GiB RAM and 2 GiB available disk, with a
confirmation below 4 GiB / 10 GiB. Actual production requirements depend on data,
plugins, users and backup space. Backups require additional staging space.

Before image pulls, the manager also checks the engine's DockerRootDir and
`/var/lib/containerd` when those paths are accessible locally. There is no fixed
10 GiB free-space gate. Cached pinned images need no download allocation; missing
images are budgeted at four times their compressed layer sizes (2 GiB per image
if layer sizes cannot be read). Backup staging and restored working copies use
separate data-size estimates. Requirements sharing a filesystem are added
together, with 512 MiB of headroom per filesystem and a 10,000-inode minimum on
filesystems reporting inode counts. Estimates are conservative, not exact sizes.
RAM-backed/read-only image filesystems are rejected. Engine storage outside the
current filesystem namespace requires a separate check on the engine host.
Guest disk figures cannot verify a hypervisor's underlying storage capacity.

Sources:

* https://docs.docker.com/engine/install/
* https://docs.docker.com/engine/install/ubuntu/
* https://docs.docker.com/engine/install/debian/
* https://docs.docker.com/engine/install/fedora/
* https://docs.docker.com/engine/install/rhel/
* https://docs.rockylinux.org/gemstones/containers/docker/

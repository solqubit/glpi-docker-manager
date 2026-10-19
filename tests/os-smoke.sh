#!/usr/bin/env bash
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
# shellcheck source=lib/core.sh
source "$GDM_ROOT/lib/core.sh"
# shellcheck source=lib/system.sh
source "$GDM_ROOT/lib/system.sh"
os_detect /etc/os-release
[[ $OS_ID != unknown && $ARCH != unsupported && -n $PKG ]]
printf '%s %s %s %s\n' "$OS_ID" "$OS_VERSION" "$ARCH" "$PKG"
docker_install_plan || true

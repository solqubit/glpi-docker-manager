#!/usr/bin/env bash
# Package manager calls are recorded, never executed.
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$GDM_ROOT/lib/core.sh"
source "$GDM_ROOT/lib/system.sh"
tr_load
work=$(mktemp -d)
trap 'builtin command rm -rf -- "$work"' EXIT
missing_tool=jq
command() {
    if [[ $1 == -v ]]; then [[ $2 != "$missing_tool" ]]
    else builtin command "$@"; fi
}
confirm() { return 0; }
admin_command_retry() { printf '%s\n' "$*" >> "$work/calls"; }
PKG=apt-get
bootstrap_dependencies
grep -qx 'apt-get install -y --no-remove --no-upgrade jq' "$work/calls"
if grep -q coreutils "$work/calls"; then exit 1; fi
missing_tool=none
builtin command rm -- "$work/calls"
bootstrap_dependencies
[[ ! -e $work/calls ]]
PKG=dnf; missing_tool=ss
bootstrap_dependencies
grep -qx 'dnf install -y iproute' "$work/calls"
PKG=pacman; missing_tool=python3
bootstrap_dependencies
grep -qx 'pacman -S --needed python' "$work/calls"

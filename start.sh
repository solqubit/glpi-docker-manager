#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf '%s\n' 'Bash 4.4 or newer is required / Se requiere Bash 4.4 o posterior.' >&2
    exit 1
fi
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export GDM_ROOT
for module in core system releases config docker tls backup maintenance operations; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
main "$@"

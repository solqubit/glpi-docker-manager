#!/usr/bin/env bash
# Read-only fixtures stop deliberately at the first service-changing command.
# shellcheck disable=SC2317
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
GDM_STATE_DIR=${1:?}; export GDM_ROOT GDM_STATE_DIR
for module in core system config docker tls backup; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
# shellcheck source=tests/helpers.sh
source "$GDM_ROOT/tests/helpers.sh"
tr_load; init_state
test_config "$STATE/config.json"
# CONFIG is consumed by cfg() in the sourced lifecycle modules.
# shellcheck disable=SC2034
CONFIG="$STATE/config.json"
assert_running() { :; }
dc() {
    if [[ $1 == exec ]]; then printf '52428800\n'
    elif [[ $1 == stop ]]; then printf '%s\n' "$*" > "$STATE/stopped"; return 77
    else return 1; fi
}
docker() {
    if [[ $1 == info ]]; then printf '%s\n' "$STATE"
    elif [[ $1 == run ]]; then
        # One helper measures every volume: report each /data/<role> argument.
        for arg; do [[ $arg != /data/* ]] || printf '1048576\t%s\n' "$arg"; done
    else return 1; fi
}
df() {
    case $1 in
        -PTm) printf 'Filesystem Type Size Used Available Use%% Mounted\nfixture ext4 17000 8000 %s 51%% /\n' "${GDM_TEST_FREE_MIB:?}";;
        -Pm) printf 'Filesystem Size Used Available Use%% Mounted\nfixture 17000 8000 %s 51%% /\n' "$GDM_TEST_FREE_MIB";;
        -Pi) printf 'Filesystem Inodes IUsed IFree IUse%% Mounted\nfixture 100000 10000 90000 10%% /\n';;
        *) return 1;;
    esac
}
backup_create

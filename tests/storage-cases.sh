#!/usr/bin/env bash
# Filesystem failures are fixtures; no disks, mounts or daemon settings change.
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$GDM_ROOT/lib/core.sh"
source "$GDM_ROOT/lib/system.sh"
tr_load
work=$(mktemp -d)
trap 'command rm -rf -- "$work"' EXIT
storage_root="$work/engine data"
mkdir -p "$storage_root"
docker() { printf '%s\n' "$storage_root"; }
free_mb=12000; free_inodes=50000; filesystem=ext4
df() {
    if [[ $1 == -Pi ]]; then printf 'Filesystem Inodes IUsed IFree IUse%% Mounted\nfixture 100000 50000 %s 50%% /\n' "$free_inodes"
    else printf 'Filesystem Type 1M-blocks Used Available Use%% Mounted\nfixture %s 20000 8000 %s 40%% /\n' "$filesystem" "$free_mb"; fi
}
storage_preflight 10240 > "$work/output" 2>&1
# The reported 8 GiB case succeeds when only a small working copy is needed.
STATE="$work/application"; mkdir -p "$STATE"
free_mb=8192
storage_preflight 0 1024 > "$work/output" 2>&1
grep -q '1536 MiB' "$work/output"
storage_preflight 2048 1024 > "$work/output" 2>&1
grep -q '3584 MiB' "$work/output"
free_mb=3000
if (storage_preflight 2048 1024) > "$work/output" 2>&1; then exit 1; fi
grep -q '3584 MiB, but 3000 MiB' "$work/output"
free_mb=100
if (storage_preflight 10240) > "$work/output" 2>&1; then exit 1; fi
grep -q 'Insufficient free space' "$work/output"
free_mb=12000; free_inodes=0
if (storage_preflight 10240) > "$work/output" 2>&1; then exit 1; fi
grep -q 'free inodes' "$work/output"
free_inodes=50000; filesystem=tmpfs
if (storage_preflight 10240) > "$work/output" 2>&1; then exit 1; fi
grep -q 'temporary/read-only' "$work/output"
# Cached images need no download allocation; missing images use layer sizes.
ARCH=amd64
docker() {
    case "$1 $2" in
        'image inspect') [[ $3 == cached ]];;
        'buildx imagetools')
            [[ $4 != missing ]] || return 1
            printf '{"layers":[{"size":10485760}]}\n';;
        *) return 1;;
    esac
}
[[ $(image_storage_budget cached) == 0 ]]
[[ $(image_storage_budget layers) == 40 ]]
[[ $(image_storage_budget missing 2>/dev/null) == 2048 ]]
for failure in 'Input/output error' 'Read-only file system' 'No space left on device'; do
    printf '%s\n' "$failure" > "$work/step.log"
    storage_failure_report "$work/step.log" > "$work/output" 2>&1
    grep -q 'host/hypervisor' "$work/output"
done
printf 'network timeout\n' > "$work/step.log"
if storage_failure_report "$work/step.log"; then exit 1; fi
STATE=$work
mkdir -p "$STATE/backups/.restore-0123456789abcdef" "$STATE/backups/saved" "$STATE/outside"
ln -s "$STATE/outside" "$STATE/backups/.restore-fedcba9876543210"
CLEANUP_DIRECTORIES=("$STATE/backups/.restore-0123456789abcdef" "$STATE/backups/saved" "$STATE/backups/.restore-fedcba9876543210")
(trap cleanup EXIT; exit 0) > "$work/output" 2>&1
[[ ! -e $STATE/backups/.restore-0123456789abcdef && -d $STATE/backups/saved && -d $STATE/outside ]]
CLEANUP_DIRECTORIES=()
touch "$work/private-temporary"
CLEANUP_PATHS=("$work/private-temporary")
rm() { return 9; }
set +e
(trap cleanup EXIT; exit 42) > "$work/output" 2>&1
cleanup_status=$?
set -e
[[ $cleanup_status == 42 && -f $work/private-temporary ]]
grep -q 'private temporary files' "$work/output"

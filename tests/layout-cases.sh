#!/usr/bin/env bash
# Docker fixture callbacks are redefined between independent cases.
# shellcheck disable=SC2317
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
GDM_STATE_DIR="${GDM_STATE_DIR:?}/layout"
export GDM_ROOT GDM_STATE_DIR
for module in core config docker operations; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
# shellcheck source=tests/helpers.sh
source "$GDM_ROOT/tests/helpers.sh"
tr_load
init_state
layout_install_code
[[ -L $STATE/manager && -x $STATE/start.sh && -f $STATE/manager/lib/layout.sh ]]
[[ ! -e $STATE/manager/.git && ! -e $STATE/manager/tests && ! -e $STATE/manager/.env ]]
[[ $(bash "$STATE/start.sh" version) == "$(cat "$GDM_ROOT/VERSION")" ]]
first_code=$(readlink "$STATE/manager")
layout_install_code
[[ $(readlink "$STATE/manager") == "$first_code" ]]
if (GDM_ROOT=$STATE; layout_install_code) >/dev/null 2>&1; then exit 1; fi
(
    GDM_ROOT=$(readlink -f "$STATE/manager")
    layout_install_code
    [[ -x $STATE/start.sh ]]
)
test_config "$STATE/input.json"
jq '.storage="directory"' "$STATE/input.json" > "$STATE/directory.json"
CONFIG="$STATE/directory.json"
config_validate "$CONFIG"
docker() {
    [[ $1 == volume && $2 == create ]] || return 1
    printf '%s\n' "$*" >> "$STATE/volume-calls"
}
volumes_ensure
for role in glpi_data db_data plugins marketplace caddy_data caddy_config; do
    directory="$STATE/data/0123456789abcdef/$role"
    [[ -d $directory ]]
    grep -Fq -- "--opt device=$directory" "$STATE/volume-calls"
done
mv -- "$STATE/data" "$STATE/owned-data"
ln -s /tmp "$STATE/data"
if (volumes_ensure) >/dev/null 2>&1; then exit 1; fi
rm -- "$STATE/data"
mv -- "$STATE/owned-data" "$STATE/data"
# Rehearsal cleanup removes only its own detached data ID, never adjacent data.
parent=$STATE
STATE="$parent/rehearsals/abcdef0123456789"
mkdir -p "$STATE/data/0123456789abcdef" "$STATE/data/protected"
printf retained > "$STATE/data/protected/marker"
dc() { :; }
docker() {
    if [[ $1 == volume && $2 == inspect ]]; then printf '0123456789abcdef\n'; fi
}
rehearsal_cleanup
[[ ! -e $STATE/data/0123456789abcdef && -f $STATE/data/protected/marker ]]
STATE=$parent

#!/usr/bin/env bash
# Executed as an external process so the caller cannot disable Bash errexit.
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
GDM_STATE_DIR=${GDM_FAULT_DIR:?}
export GDM_ROOT GDM_STATE_DIR
for module in core system releases config docker tls backup operations; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
# shellcheck source=tests/helpers.sh
source "$GDM_ROOT/tests/helpers.sh"
tr_load
init_state
test_config "$STATE/input.json"
config_render "$STATE/input.json" "$STATE/revisions/fault"
config_activate "$STATE/revisions/fault"
volumes_ensure() { :; }
storage_preflight() { :; }
pull_images() { :; }
initialize_plugin_volume() { :; }
dc() { printf '%s\n' "$*" >> "$STATE/calls"; }
wait_healthy() { :; }
install_database() { return 42; }
verify_services() { printf 'UNSAFE_CONTINUATION\n' >> "$STATE/calls"; }
journal_begin install
installation_finish

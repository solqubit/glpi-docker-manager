#!/usr/bin/env bash
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
GDM_STATE_DIR=$(mktemp -d); export GDM_STATE_DIR
for module in core system config tls; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
# shellcheck source=tests/helpers.sh
source "$GDM_ROOT/tests/helpers.sh"
trap 'rm -rf -- "$GDM_STATE_DIR"' EXIT
tr_load
mkdir -p "$STATE/revisions"
test_config "$STATE/input.json"
for mode in off self-signed custom acme; do
    dir="$STATE/revisions/$mode"
    host=localhost; [[ $mode != acme ]] || host=glpi.example.com
    jq --arg mode "$mode" --arg host "$host" '.agent_enabled=true | .tls=$mode | .hostname=$host |
        if .tls=="acme" then .http_port=80 | .https_port=443 else . end' "$STATE/input.json" > "$STATE/agent.json"
    if [[ $mode == custom ]]; then
        mkdir -p "$CERT_ROOT/custom"
        cp "$CERT_ROOT/self-signed/fullchain.pem" "$CERT_ROOT/self-signed/privkey.pem" "$CERT_ROOT/custom/"
        cp "$CERT_ROOT/self-signed/ca/gdm-ca.pem" "$CERT_ROOT/custom/agent-ca.pem"
    fi
    config_render "$STATE/agent.json" "$dir"
    tls_prepare "$STATE/agent.json" "$dir"
    agent_prepare "$STATE/agent.json" "$dir"
    bash -n "$dir/public/agent/install.sh"
    shellcheck "$dir/public/agent/install.sh"
    [[ $(stat -c %a "$dir/public/agent/install.sh") == 644 ]]
    if grep -rE 'test_password|root_password|BEGIN .*PRIVATE KEY' "$dir/public"; then exit 1; fi
    if [[ $mode == off ]]; then
        jq -e '.services.glpi.volumes | any(type=="object" and .target=="/var/www/glpi/public/agent" and .read_only)' "$dir/compose.json" >/dev/null
        jq -e '.server=="http://localhost:18080/front/inventory.php" and .ca_sha256==""' "$dir/public/agent/bootstrap.json" >/dev/null
    else
        grep -q 'handle /agent/\*' "$dir/Caddyfile"
        jq -e '.services.proxy.volumes | any(type=="object" and .target=="/etc/gdm/public" and .read_only)' "$dir/compose.json" >/dev/null
    fi
    if [[ $mode == self-signed || $mode == custom ]]; then
        cmp "$dir/public/agent/ca.pem" "$CERT_ROOT/self-signed/ca/gdm-ca.pem"
        jq -e '.ca_sha256|test("^[a-f0-9]{64}$")' "$dir/public/agent/bootstrap.json" >/dev/null
    else [[ ! -e $dir/public/agent/ca.pem ]]; fi
    ln -sfn "revisions/$mode" "$STATE/current"
    CONFIG="$STATE/current/config.json"; export CONFIG; cfg_cache
    agent_command '' > "$STATE/command.sh"
    bash -n "$STATE/command.sh"
    expected=$(sha256sum < "$dir/public/agent/install.sh"); expected=${expected%% *}
    grep -q "$expected" "$STATE/command.sh"
    # No running systemd: fail before changing the client, unless --once is explicit.
    if bash "$dir/public/agent/install.sh" > "$STATE/client.log" 2>&1; then exit 1; fi
    grep -q 'running systemd' "$STATE/client.log"
done
# Imported public certificates must not cause a leaf certificate to be trusted
# as a CA. A separate private CA is optional, and an invalid one is rejected.
rm "$CERT_ROOT/custom/agent-ca.pem"
jq '.agent_enabled=true | .tls="custom"' "$STATE/input.json" > "$STATE/custom-public.json"
config_render "$STATE/custom-public.json" "$STATE/revisions/public-custom"
tls_prepare "$STATE/custom-public.json" "$STATE/revisions/public-custom"
agent_prepare "$STATE/custom-public.json" "$STATE/revisions/public-custom"
[[ ! -e $STATE/revisions/public-custom/public/agent/ca.pem ]]
printf invalid > "$CERT_ROOT/custom/agent-ca.pem"
if (agent_prepare "$STATE/custom-public.json" "$STATE/revisions/public-custom") >/dev/null 2>&1; then exit 1; fi
config_render "$STATE/input.json" "$STATE/revisions/disabled"
agent_prepare "$STATE/input.json" "$STATE/revisions/disabled"
[[ ! -e $STATE/revisions/disabled/public/agent/install.sh ]]
if jq -e '.services.glpi.volumes | any(type=="object" and .target=="/var/www/glpi/public/agent")' "$STATE/revisions/disabled/compose.json" >/dev/null; then exit 1; fi
# Missing flag means enabled for new configurations and older installations.
jq 'del(.agent_enabled) | .status="ready"' "$STATE/input.json" > "$STATE/old.json"
config_render "$STATE/old.json" "$STATE/revisions/old"
agent_prepare "$STATE/old.json" "$STATE/revisions/old"
[[ -f $STATE/revisions/old/public/agent/install.sh ]]
# Simulate the one-time transition from the former Compose layout. Do not start
# a deliberately stopped installation, repeat the transition or undo opt-out.
rm -rf -- "$STATE/revisions/old/public"
ln -sfn revisions/old "$STATE/current"
CONFIG="$STATE/current/config.json"; cfg_cache
running=''
dc() { [[ $1 == ps ]] && printf '%s' "$running"; }
ui_run() { shift 2; "$@"; }
apply_settings() {
    [[ ${2:-} == true ]]
    printf 'apply\n' >> "$STATE/applied"
    cp "$1" "$STATE/current/config.json"
    cfg_cache
    agent_prepare "$CONFIG" "$STATE/current"
}
agent_upgrade_existing
[[ ! -e $STATE/applied ]]
running=glpi-test-container
agent_upgrade_existing
[[ $(wc -l < "$STATE/applied") == 1 ]]
agent_upgrade_existing
[[ $(wc -l < "$STATE/applied") == 1 ]]
rm -rf -- "$STATE/current/public"
agent_upgrade_existing
[[ $(wc -l < "$STATE/applied") == 1 ]]
jq '.agent_enabled=false' "$CONFIG" > "$STATE/off.json"
cp "$STATE/off.json" "$CONFIG"; cfg_cache
agent_upgrade_existing
[[ $(wc -l < "$STATE/applied") == 1 ]]
printf '%s\n' 'PASS: agent publication, ports, public/private/local CA, pinned commands, permissions, opt-out and no credential leakage'

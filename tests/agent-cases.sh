#!/usr/bin/env bash
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
GDM_STATE_DIR=$(mktemp -d); export GDM_STATE_DIR
for module in core system config tls operations; do
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
    [[ -f $dir/public/agent/install-$expected.sh ]]
    agent_information > "$STATE/info.stdout" 2> "$STATE/info.log"
    grep -Fq "$(t agent_info_target "$(installation_url)/front/inventory.php")" "$STATE/info.log"
    grep -Fq '/etc/glpi-agent/conf.d/99-gdm.cfg' "$STATE/info.log"
    if grep -qE 'test_password|root_password|privkey|gdm-ca.key' "$STATE/info.log"; then exit 1; fi
    if [[ $mode == self-signed || $mode == custom ]]; then
        grep -Fq '/etc/glpi-agent/certs/gdm-ca.pem' "$STATE/info.log"
    else
        if grep -Fq '/etc/glpi-agent/certs/gdm-ca.pem' "$STATE/info.log"; then exit 1; fi
    fi
    if [[ -n ${previous_installer:-} ]]; then
        cmp "$previous_installer" "$dir/public/agent/${previous_installer##*/}"
    fi
    previous_installer="$dir/public/agent/install-$expected.sh"
    # No running systemd: fail before changing the client, unless --once is explicit.
    if bash "$dir/public/agent/install.sh" > "$STATE/client.log" 2>&1; then exit 1; fi
    grep -q 'running systemd' "$STATE/client.log"
done
# The private information screen returns to the same administration submenu.
if (
    # Called indirectly by the sourced agent_setup implementation.
    # shellcheck disable=SC2317
    choose() {
        if [[ ! -e $STATE/info-visited ]]; then
            printf visited > "$STATE/info-visited"
            printf -v "$1" '%s' info
        else
            [[ $3 == info ]] || exit 23
            printf -v "$1" '%s' back
        fi
    }
    # shellcheck disable=SC2317
    ui_pause() { [[ $1 == agent_info_back ]] || exit 24; }
    agent_setup ''
) > "$STATE/info-menu.log" 2>&1; then exit 1
else [[ $? == 10 ]]; fi
# Corrupted history is not carried into a new revision or trusted implicitly.
printf altered >> "$previous_installer"
mkdir "$STATE/resource-history"
agent_resources_carry "$STATE/resource-history"
[[ ! -e $STATE/resource-history/${previous_installer##*/} ]]
# Execute the exact copyable block using local download fixtures. The generated
# command must work with either tool and reject altered bytes before execution.
cat > "$STATE/current/public/agent/install.sh" <<'CLIENT'
#!/usr/bin/env bash
printf '%s\n' "${1:-service}" > "$GDM_BOOTSTRAP_MARKER"
CLIENT
mkdir -p "$STATE/bootstrap-tmp"
bootstrap_case() {
    local tool=$1 tamper=${2:-false} argument=${3:-} bin="$STATE/bin-$1" command
    mkdir -p "$bin"
    for command in bash mktemp rm sha256sum; do ln -sf "$(command -v "$command")" "$bin/$command"; done
    printf '#!/bin/bash\nexec "$@"\n' > "$bin/sudo"
    chmod 755 "$bin/sudo"
    if [[ $tool != missing ]]; then
        cat > "$bin/$tool" <<'DOWNLOAD'
#!/bin/bash
set -eu
while (( $# )); do
    case $1 in -O|-o) destination=$2; shift 2;; *) shift;; esac
done
/bin/cp -- "$GDM_BOOTSTRAP_PAYLOAD" "$destination"
[[ $GDM_BOOTSTRAP_TAMPER != true ]] || printf '\n# altered in transit\n' >> "$destination"
DOWNLOAD
        chmod 755 "$bin/$tool"
    fi
    agent_command "$argument" > "$STATE/readable-command.sh"
    [[ $(head -n 1 "$STATE/readable-command.sh") == "sudo bash <<'GDM_AGENT'" ]]
    [[ $(tail -n 1 "$STATE/readable-command.sh") == GDM_AGENT ]]
    if grep -q $'\033' "$STATE/readable-command.sh"; then exit 1; fi
    bash -n "$STATE/readable-command.sh"
    shellcheck -s bash "$STATE/readable-command.sh"
    rm -f -- "$STATE/client-marker"
    if PATH="$bin" TMPDIR="$STATE/bootstrap-tmp" GDM_BOOTSTRAP_MARKER="$STATE/client-marker" \
        GDM_BOOTSTRAP_PAYLOAD="$STATE/current/public/agent/install.sh" GDM_BOOTSTRAP_TAMPER="$tamper" \
        bash "$STATE/readable-command.sh" > "$STATE/bootstrap.log" 2>&1; then
        [[ $tamper == false && $tool != missing ]]
        [[ $(< "$STATE/client-marker") == "${argument:-service}" ]]
    else
        [[ $tamper == true || $tool == missing ]]
        [[ ! -e $STATE/client-marker ]]
    fi
    [[ -z $(find "$STATE/bootstrap-tmp" -mindepth 1 -print -quit) ]]
}
bootstrap_case wget
bootstrap_case curl false --once
bootstrap_case wget true
bootstrap_case missing
# An older copied block still resolves to its original verified bytes after the
# canonical installer changes (for example after a manager update).
old_digest=$(sha256sum < "$STATE/current/public/agent/install.sh"); old_digest=${old_digest%% *}
printf '# updated installer\n' >> "$STATE/current/public/agent/install.sh"
agent_snapshot "$STATE/current/public/agent" "$STATE/current/public/agent/install.sh" install
old_bytes=$(sha256sum < "$STATE/current/public/agent/install-$old_digest.sh"); old_bytes=${old_bytes%% *}
[[ $old_bytes == "$old_digest" ]]
# The card has one success marker; the executable output stays plain text.
agent_show_command > "$STATE/displayed-command.sh" 2> "$STATE/command-card.log"
grep -Fq "[+] $(t agent_ready)" "$STATE/command-card.log"
if grep -Fq '[*] [+]' "$STATE/command-card.log"; then exit 1; fi
bash -n "$STATE/displayed-command.sh"
# Imported public certificates must not cause a leaf certificate to be trusted
# as a CA. A separate private CA is optional, and an invalid one is rejected.
rm "$CERT_ROOT/custom/agent-ca.pem"
jq '.agent_enabled=true | .tls="custom"' "$STATE/input.json" > "$STATE/custom-public.json"
config_render "$STATE/custom-public.json" "$STATE/revisions/public-custom"
tls_prepare "$STATE/custom-public.json" "$STATE/revisions/public-custom"
agent_prepare "$STATE/custom-public.json" "$STATE/revisions/public-custom"
[[ ! -e $STATE/revisions/public-custom/public/agent/ca.pem ]]
ln -sfn revisions/public-custom "$STATE/current"
CONFIG="$STATE/current/config.json"; cfg_cache
agent_information > "$STATE/public-info.stdout" 2> "$STATE/public-info.log"
expected_info=$(t agent_info_custom_public)
grep -Fq "${expected_info:0:35}" "$STATE/public-info.log"
if grep -Fq '/etc/glpi-agent/certs/gdm-ca.pem' "$STATE/public-info.log"; then exit 1; fi
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

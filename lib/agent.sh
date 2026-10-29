#!/usr/bin/env bash
# Public bootstrap resources contain only addresses, public certificates and
# pinned upstream downloads. They never include the installation configuration.
agent_enabled() { jq -e '.agent_enabled != false' "$1" >/dev/null; }

agent_prepare() {
    local file=$1 revision=$2 mode host port base server ca='' ca_hash='' name value
    agent_enabled "$file" || return 0
    mode=$(jq -r .tls "$file"); host=$(jq -r .hostname "$file")
    port=$(jq -r .http_port "$file")
    base="http://$host"; [[ $port == 80 ]] || base+=":$port"
    server="$base"
    if [[ $mode != off ]]; then
        port=$(jq -r .https_port "$file")
        server="https://$host"; [[ $port == 443 ]] || server+=":$port"
    fi
    mkdir -p "$revision/public/agent"
    if [[ $mode == self-signed ]]; then
        ca="$revision/tls/gdm-ca.pem"
    elif [[ $mode == custom && -f $(jq -r .cert_dir "$file")/custom/agent-ca.pem ]]; then
        ca="$(jq -r .cert_dir "$file")/custom/agent-ca.pem"
        openssl x509 -in "$ca" -noout -checkend 86400 >/dev/null || die agent_ca_invalid
        openssl verify -CAfile "$ca" -untrusted "$revision/tls/fullchain.pem" \
            "$revision/tls/fullchain.pem" >/dev/null || die agent_ca_invalid
    fi
    if [[ -n $ca ]]; then
        cp -- "$ca" "$revision/public/agent/ca.pem"
        ca_hash=$(sha256sum < "$ca"); ca_hash=${ca_hash%% *}
    fi
    # Fixed, reviewed upstream release. Its checksum is published in the official
    # glpi-agent-1.21.sha256 asset; a future agent update changes both together.
    local version=1.21 digest=285eccea560c0e9f253be0feb19786903110d5189d28285d4f1cc2097bb1bd33
    local asset="https://github.com/glpi-project/glpi-agent/releases/download/$version/glpi-agent-$version-x86_64.AppImage"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'readonly GDM_AGENT_SERVER=%q\n' "$server/front/inventory.php"
        printf 'readonly GDM_AGENT_CA_URL=%q\n' "$base/agent/ca.pem"
        printf 'readonly GDM_AGENT_CA_SHA256=%q\n' "$ca_hash"
        printf 'readonly GDM_AGENT_VERSION=%q\n' "$version"
        printf 'readonly GDM_AGENT_ASSET=%q\n' "$asset"
        printf 'readonly GDM_AGENT_SHA256=%q\n' "$digest"
        printf 'declare -A AGENT_MESSAGES=()\n'
        while IFS=$'\t' read -r name value; do
            [[ $name == agent_client_* ]] || continue
            printf 'AGENT_MESSAGES[%q]=%q\n' "${name#agent_client_}" "$value"
        done < "$GDM_ROOT/locales/$(jq -r .language "$file").tsv"
        cat "$GDM_ROOT/templates/agent-install.sh"
    } > "$revision/public/agent/install.sh"
    jq -n --arg server "$server/front/inventory.php" --arg tls "$mode" --arg version "$version" \
        --arg ca "$ca_hash" --arg asset "$asset" --arg sha256 "$digest" \
        '{format:1,server:$server,tls:$tls,agent_version:$version,architecture:"x86_64",ca_sha256:$ca,
          asset:$asset,asset_sha256:$sha256}' > "$revision/public/agent/bootstrap.json"
    chmod 755 "$revision/public" "$revision/public/agent"
    chmod 644 "$revision/public/agent/"*
}

agent_command() {
    local installer="$STATE/current/public/agent/install.sh" url hash body
    [[ -z ${1:-} || $1 == --once ]] || die invalid agent-command
    if ! agent_enabled "$CONFIG" || [[ ! -f $installer ]]; then die agent_not_published; fi
    url=$(tls_ca_url "$(cfg hostname)" "$(cfg http_port)"); url=${url%/gdm-ca.pem}/agent/install.sh
    hash=$(sha256sum < "$installer"); hash=${hash%% *}
    # Run in a root-owned temporary directory. The expected hash comes from the
    # trusted manager session, never from the unauthenticated HTTP response.
    # shellcheck disable=SC2016
    printf -v body 'set -eu; umask 077; d=$(mktemp -d); trap '\''rm -rf -- "$d"'\'' EXIT; if command -v curl >/dev/null; then curl --proto "=http" -fsS --connect-timeout 10 --max-time 120 %q -o "$d/install.sh"; elif command -v wget >/dev/null; then wget -q --timeout=120 -O "$d/install.sh" %q; else echo "Install curl or wget first" >&2; exit 1; fi; printf "%%s  %%s\\n" %q "$d/install.sh" | sha256sum -c -; bash "$d/install.sh"' "$url" "$url" "$hash"
    [[ ${1:-} != --once ]] || body+=' --once'
    printf 'sudo bash -c %q\n' "$body"
}

agent_setup() {
    local action=${1:-} file publication
    local -a details=("$(t agent_intro)")
    if agent_enabled "$CONFIG"; then publication=$(t agent_state_on); else publication=$(t agent_state_off); fi
    details+=("$publication")
    [[ $(cfg tls) != custom ]] || details+=("$(t agent_custom_ca "$CERT_ROOT/custom/agent-ca.pem")")
    ui_panel "$(t agent_title)" "${details[@]}"
    if [[ -z $action ]]; then
        if agent_enabled "$CONFIG"; then
            choose action agent_title show show "$(ui_opt primary "$(t agent_show)")" \
                publish "$(t agent_publish)" disable "$(ui_opt warn "$(t agent_disable)")" \
                back "$(ui_opt back "$(t ui_back_menu)")" || exit 10
        else
            choose action agent_title publish publish "$(ui_opt primary "$(t agent_publish)")" \
                back "$(ui_opt back "$(t ui_back_menu)")" || exit 10
        fi
    fi
    case $action in publish|disable|show) ;; back) exit 10;; *) die invalid agent-setup;; esac
    if [[ $action == show ]]; then agent_show_command; return; fi
    confirm agent_publish_confirm || exit 10
    file=$(mktemp "$STATE/.agent.XXXXXX"); CLEANUP_PATHS+=("$file")
    jq --argjson enabled "$([[ $action != disable ]] && printf true || printf false)" \
        '.agent_enabled=$enabled' "$CONFIG" > "$file"
    ui_run 0 settings_step_apply apply_settings "$file" true
    [[ $action != disable ]] || { menu_done agent_disabled; return; }
    agent_show_command
}
agent_show_command() {
    ui_panel "$(t agent_ready)" "$(t agent_copy)" "$(t agent_trust_note)"
    # Do not wrap a shell command into a card: copying the complete line matters.
    printf '\n'; agent_command ''; printf '\n'
}

# Upgrade old installed Compose files once, without changing deliberately stopped
# installations. A failed application restores the previous revision as usual.
agent_upgrade_needed() {
    agent_enabled "$CONFIG" && [[ ! -f $STATE/current/public/agent/install.sh ]]
}
agent_upgrade_apply() {
    local file
    file=$(mktemp "$STATE/.agent-upgrade.XXXXXX"); CLEANUP_PATHS+=("$file")
    jq '.agent_enabled=true' "$CONFIG" > "$file"
    apply_settings "$file" true
}
agent_upgrade_existing() {
    [[ -L $STATE/current && ! -e $STATE/operation.json ]] || return 0
    config_load
    [[ $(cfg status) == ready ]] || return 0
    # The recorded flag is the one-time transition marker. Later repairs or
    # installer refreshes remain explicit administration actions.
    jq -e 'has("agent_enabled") | not' "$CONFIG" >/dev/null || return 0
    agent_upgrade_needed || return 0
    [[ -n $(dc ps --status running --quiet glpi) ]] || return 0
    ui_run 0 agent_upgrade_step agent_upgrade_apply
}

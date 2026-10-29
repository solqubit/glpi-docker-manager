#!/usr/bin/env bash
# Included after a generated, shell-quoted header by agent_prepare.
set -Eeuo pipefail
umask 077
# Formats come only from trusted repository translations in the generated header.
# shellcheck disable=SC2154,SC2059
agent_message() { local key=$1; shift; printf "${AGENT_MESSAGES[$key]}\n" "$@"; }
agent_error() { agent_message "$@" >&2; exit 1; }
[[ $EUID == 0 ]] || agent_error root
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || agent_error architecture
once=false
case ${1:-} in --once) once=true;; '') ;; *) agent_error usage;; esac
if [[ $once == false ]]; then
    if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then agent_error systemd; fi
fi
work=$(mktemp -d)
service_was_running=false
service_stopped=false
agent_cleanup() {
    local result=$?
    trap - EXIT
    set +e
    rm -rf -- "$work"
    if [[ $service_stopped == true && $service_was_running == true ]]; then systemctl start glpi-agent; fi
    exit "$result"
}
trap agent_cleanup EXIT
trap 'agent_message failed >&2' ERR

agent_packages() {
    (( $# )) || return 0
    agent_message dependencies "$*"
    if command -v apt-get >/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    elif command -v dnf >/dev/null; then dnf install -y "$@"
    elif command -v yum >/dev/null; then yum install -y "$@"
    elif command -v zypper >/dev/null; then zypper --non-interactive install "$@"
    else agent_error packages "$*"; fi
}
missing=()
command -v curl >/dev/null || missing+=(curl)
command -v openssl >/dev/null || missing+=(openssl)
[[ -f /etc/ssl/certs/ca-certificates.crt || -f /etc/pki/tls/certs/ca-bundle.crt ]] || missing+=(ca-certificates)
agent_packages "${missing[@]}"
agent_fetch() {
    # No insecure TLS, HTTPS downgrade or cross-protocol redirects. HTTP is
    # allowed only for the CA, whose expected SHA-256 is embedded in this script.
    curl --proto '=http,https' --proto-redir '=https' --fail --silent --show-error \
        --location --retry 2 --connect-timeout 10 --max-time 600 "$1" -o "$2"
}
agent_checksum() { printf '%s  %s\n' "$1" "$2" | sha256sum -c - >/dev/null; }
ca_args=()
if [[ -n $GDM_AGENT_CA_SHA256 ]]; then
    agent_message certificate
    agent_fetch "$GDM_AGENT_CA_URL" "$work/ca.pem"
    agent_checksum "$GDM_AGENT_CA_SHA256" "$work/ca.pem" || agent_error checksum
    openssl x509 -in "$work/ca.pem" -noout -checkend 86400 >/dev/null || agent_error certificate_invalid
    ca_args=(--cacert "$work/ca.pem")
fi
# Detect wrong addresses, hostname/CA mismatches and unreachable servers before
# modifying an existing agent. The inventory endpoint need not accept HTTP GET.
agent_message checking "$GDM_AGENT_SERVER"
curl --proto '=http,https' --proto-redir '=https' --silent --show-error --location \
    --connect-timeout 10 --max-time 45 "${ca_args[@]}" "${GDM_AGENT_SERVER%/front/inventory.php}/" \
    -o /dev/null --fail || agent_error unreachable

agent_message downloading "$GDM_AGENT_VERSION"
agent_fetch "$GDM_AGENT_ASSET" "$work/agent.AppImage"
agent_checksum "$GDM_AGENT_SHA256" "$work/agent.AppImage" || agent_error checksum
chmod 700 "$work/agent.AppImage"
# Extracting an AppImage uses neither /dev/fuse nor libfuse. Keep the extracted
# application at a permanent path: the official installed wrappers refer to it.
target="/opt/glpi-agent/appimage-$GDM_AGENT_VERSION"
(cd "$work" && ./agent.AppImage --appimage-extract >/dev/null)
if ! "$work/squashfs-root/AppRun" --version > "$work/version.log" 2>&1; then
    if grep -q 'libcrypt.so.1' "$work/version.log"; then
        if command -v apt-get >/dev/null; then agent_packages libcrypt1
        else agent_packages libxcrypt-compat; fi
    else cat "$work/version.log" >&2; agent_error runtime; fi
fi
"$work/squashfs-root/AppRun" --version
# Never silently replace a native/package-managed installation with an AppImage.
if command -v glpi-agent >/dev/null && [[ ! -f /var/lib/glpi-agent/.APPIMAGE ]]; then
    agent_error existing
fi
agent_message installing
if [[ -d $target ]]; then
    [[ -f $target/.gdm-sha256 && $(< "$target/.gdm-sha256") == "$GDM_AGENT_SHA256" ]] || agent_error existing
else
    mkdir -p /opt/glpi-agent
    mv -- "$work/squashfs-root" "$target"
    printf '%s\n' "$GDM_AGENT_SHA256" > "$target/.gdm-sha256"
fi
if [[ $once == false ]] && systemctl is-active --quiet glpi-agent; then
    service_was_running=true; service_stopped=true
    systemctl stop glpi-agent
fi
mkdir -p /etc/glpi-agent/conf.d /etc/glpi-agent/certs /var/log/glpi-agent
config="$work/99-gdm.cfg"
{
    printf '# Managed by GLPI Docker Manager. Agent identity is preserved.\n'
    printf 'server = %s\nno-ssl-check = 0\nssl-fingerprint =\nca-cert-dir =\n' "$GDM_AGENT_SERVER"
    if [[ -n $GDM_AGENT_CA_SHA256 ]]; then
        install -m 644 "$work/ca.pem" /etc/glpi-agent/certs/gdm-ca.pem
        printf 'ca-cert-file = /etc/glpi-agent/certs/gdm-ca.pem\n'
    else printf 'ca-cert-file =\n'; fi
} > "$config"
# The official installer preserves VARDIR and copies this one stable config
# filename instead of generating a new numbered file on every invocation.
"$target/AppRun" --install --no-service --config="$config" --server="$GDM_AGENT_SERVER"
install -m 600 "$config" /etc/glpi-agent/conf.d/99-gdm.cfg

agent_message inventory
log=/var/log/glpi-agent/gdm-bootstrap.log
# Run once in the foreground so failures are visible before announcing success.
inventory_ok=true
if ! /usr/local/bin/glpi-agent --force --tasks=inventory --logger=stderr --debug > "$log" 2>&1; then inventory_ok=false; fi
if grep -Eqi '\[error\]|\[fault\]|certificate verify failed|failed to send|communication error' "$log"; then
    inventory_ok=false
fi
if [[ $once == false ]]; then
    cat > /etc/systemd/system/glpi-agent.service <<'UNIT'
[Unit]
Description=GLPI Agent
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/glpi-agent --daemon --no-fork --logger=stderr
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 /etc/systemd/system/glpi-agent.service
    systemctl daemon-reload
    systemctl enable --now glpi-agent
    systemctl is-active --quiet glpi-agent
    service_stopped=false
fi
if [[ $inventory_ok == false ]]; then cat "$log" >&2; agent_error inventory_failed "$log"; fi
agent_message 'done' "$GDM_AGENT_SERVER" "$log"
agent_message import_note

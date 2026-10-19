#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
GDM_STATE_DIR=$(mktemp -d)
GDM_CERT_DIR="$GDM_STATE_DIR/certs"
export GDM_STATE_DIR GDM_CERT_DIR
for module in core system releases config docker tls backup maintenance operations; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
# shellcheck source=tests/helpers.sh
source "$GDM_ROOT/tests/helpers.sh"
tr_load
trap 'rm -rf -- "$GDM_STATE_DIR"' EXIT
passed=0
ok() { ((passed+=1)); printf 'ok %s - %s\n' "$passed" "$1"; }
expect_fail() { if ("$@") >/dev/null 2>&1; then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi; }

while IFS= read -r file; do bash -n "$file"; done < <(find "$GDM_ROOT" -name '*.sh' -not -path '*/.runtime/*')
ok 'Bash syntax'
valid_version 11.0.11
expect_fail valid_version latest
expect_fail valid_version 12.0.0-rc1
version_gt 11.0.11 11.0.9
expect_fail version_gt 11.0.7 11.0.7
expect_fail version_gt 11.0.7 12.0.0
ok 'Numeric semantic version comparisons and stable-only selection'
bash "$GDM_ROOT/tests/release-cases.sh"
ok 'Paginated release discovery filters drafts/RCs, skips missing images and discovers canonical CLI commands'
bash "$GDM_ROOT/tests/maintenance-cases.sh"
ok 'Backup rotation, restore cleanup, free-space selection and flexible backup schedules (days, weekdays, time)'

for distro in ubuntu debian fedora rocky almalinux rhel custom-linux; do
    printf 'ID=%s\nVERSION_ID="99"\nPRETTY_NAME="Test %s"\n' "$distro" "$distro" > "$STATE/os-release"
    os_detect "$STATE/os-release"
    [[ $OS_ID == "$distro" && $OS_VERSION == 99 && $OS_NAME == "Test $distro" ]]
done
# shellcheck disable=SC2016
printf 'ID="$(touch /tmp/gdm-os-injection)"\n' > "$STATE/os-release"
os_detect "$STATE/os-release"
[[ ! -f /tmp/gdm-os-injection ]]
ok 'Distribution detection is permissive and never executes os-release data'
bash "$GDM_ROOT/tests/bootstrap-cases.sh"
ok 'Administrative access is checked first; Docker service/plugin recovery continues and supports retry without switching engines'
bash "$GDM_ROOT/tests/dependency-cases.sh"
ok 'Only missing dependency packages are requested; existing coreutils are not implicitly upgraded'
bash "$GDM_ROOT/tests/storage-cases.sh"
ok 'Docker filesystem capacity, inodes, temporary storage, I/O diagnosis and cleanup failures are handled'
bash "$GDM_ROOT/tests/network-cases.sh"
ok 'Network address detection prefers the routed interface and excludes Docker bridges'
bash "$GDM_ROOT/tests/layout-cases.sh"
ok 'One application root contains operational code and data, preserves ownership and rejects redirected data paths'
bash "$GDM_ROOT/tests/http-cases.sh"
ok 'Opaque GitHub bearer tokens accept JWT punctuation, reject header injection and never enter curl arguments or third-party requests'

init_state
test_config "$STATE/input.json"
config_validate "$STATE/input.json"
jq 'del(.mode)' "$STATE/input.json" > "$STATE/standard.json"
config_validate "$STATE/standard.json"
for expression in '.http_port=0' '.http_port=65536' '.http_port=1.5' '.glpi_version="latest"' '.major=12' '.db_name="glpi; DROP DATABASE x"' '.hostname="site;id"' '.timezone="../../etc/passwd"' '.expose_db="yes"' '.mysql_image="attacker/mysql:8.4.11"' '.db_password=""' '.root_password=""' '.db_password="control\ncharacter"'; do
    jq "$expression" "$STATE/input.json" > "$STATE/bad.json"
    expect_fail config_validate "$STATE/bad.json"
done
ok 'Invalid ports, versions, image origins, identifiers, timezone and passwords rejected'
jq '.db_password="x" | .root_password="1"' "$STATE/input.json" > "$STATE/short.json"
config_validate "$STATE/short.json"
jq '.major=13 | .glpi_version="13.0.0" | .glpi_image=(.glpi_image|sub("11.0.11";"13.0.0"))' "$STATE/input.json" > "$STATE/future.json"
config_validate "$STATE/future.json"
ok 'Future stable majors such as GLPI 13 are not rejected by a hard-coded branch list'

mkdir -p "$STATE/revisions/unit"
config_render "$STATE/input.json" "$STATE/revisions/unit"
grep -q '^GLPI_DB_HOST="db"$' "$STATE/revisions/unit/.env"
grep -q '^GLPI_DB_PORT="3306"$' "$STATE/revisions/unit/.env"
grep -q '^GLPI_DB_NAME=' "$STATE/revisions/unit/.env"
grep -q '^GLPI_DB_USER=' "$STATE/revisions/unit/.env"
jq -e '.services.db.ports==null and .services.glpi.environment.GLPI_SKIP_AUTOUPDATE=="true" and .services.glpi.environment.GLPI_SKIP_AUTOINSTALL=="true" and .services.glpi.environment.MYSQL_ROOT_PASSWORD==null and .services.glpi.volumes[0]=="glpi_data:/var/glpi"' "$STATE/revisions/unit/compose.json" >/dev/null
jq -e '.services.db.command==["--binlog-expire-logs-seconds=2592000"] and .services.glpi.logging.options["max-size"]=="10m" and .services.db.logging.options["max-file"]=="3"' "$STATE/revisions/unit/compose.json" >/dev/null
jq '.expose_db=true | .major=10 | .glpi_version="10.0.28" | .glpi_image=(.glpi_image|sub("11.0.11";"10.0.28"))' "$STATE/input.json" > "$STATE/legacy.json"
config_render "$STATE/legacy.json" "$STATE/revisions/legacy"
jq -e '.services.db.ports==["3306:3306"] and (.services.glpi.volumes|index("marketplace:/var/www/glpi/marketplace"))!=null' "$STATE/revisions/legacy/compose.json" >/dev/null
ok 'Database exposure is binary, legacy marketplace persists, automatic schema updates disabled'

if docker compose version >/dev/null 2>&1; then
    while IFS= read -r password_case; do
        jq --argjson password "$password_case" '.db_password=$password' "$STATE/input.json" > "$STATE/edge.json"
        config_render "$STATE/edge.json" "$STATE/revisions/edge"
        docker compose --env-file "$STATE/revisions/edge/.env" -f "$STATE/revisions/edge/compose.json" config --format json > "$STATE/edge-parsed.json"
        jq -e --slurpfile config "$STATE/edge.json" '(.services.glpi.environment.GLPI_DB_PASSWORD|gsub("\\$\\$";"$"))==$config[0].db_password' "$STATE/edge-parsed.json" >/dev/null
    done < <(jq -c '.[]' "$GDM_ROOT/tests/fixtures/passwords.json")
    jq --arg password 'quoted $ # '\'' slash\ end' '.db_password=$password' "$STATE/input.json" > "$STATE/quoted.json"
    config_render "$STATE/quoted.json" "$STATE/revisions/quoted"
    docker compose --env-file "$STATE/revisions/quoted/.env" -f "$STATE/revisions/quoted/compose.json" config --format json > "$STATE/parsed.json"
    # Compose escapes dollars in its canonical serialized output for re-import.
    jq -e --slurpfile config "$STATE/quoted.json" '(.services.glpi.environment.GLPI_DB_PASSWORD|gsub("\\$\\$";"$"))==$config[0].db_password' "$STATE/parsed.json" >/dev/null || {
        jq -c --slurpfile config "$STATE/quoted.json" '{test_actual:.services.glpi.environment.GLPI_DB_PASSWORD,test_expected:$config[0].db_password}' "$STATE/parsed.json"
        exit 1
    }
    ok 'Compose preserves special characters in passwords without exposing root credentials to GLPI'
fi

jq '.tls="self-signed"' "$STATE/input.json" > "$STATE/tls.json"
config_render "$STATE/tls.json" "$STATE/revisions/tls"
tls_prepare "$STATE/tls.json" "$STATE/revisions/tls"
tls_validate_pair "$STATE/revisions/tls/tls" localhost
expect_fail tls_validate_pair "$STATE/revisions/tls/tls" wrong.example.org
before=$(sha256sum "$CERT_ROOT/self-signed/privkey.pem")
tls_prepare "$STATE/tls.json" "$STATE/revisions/tls"
[[ $(sha256sum "$CERT_ROOT/self-signed/privkey.pem") == "$before" ]]
ok 'Self-signed generation, hostname verification and key preservation'
jq '.hostname="192.0.2.30"' "$STATE/tls.json" > "$STATE/ip-tls.json"
config_render "$STATE/ip-tls.json" "$STATE/revisions/ip-tls"
tls_prepare "$STATE/ip-tls.json" "$STATE/revisions/ip-tls"
tls_validate_pair "$STATE/revisions/ip-tls/tls" 192.0.2.30
tls_validate_pair "$STATE/revisions/tls/tls" localhost
grep -q 'default_sni 192.0.2.30' "$STATE/revisions/ip-tls/Caddyfile"
grep -q 'https://192.0.2.30:18443{uri}' "$STATE/revisions/ip-tls/Caddyfile"
ok 'Self-signed address changes regenerate IP SAN certificates while preserving prior revision keys and custom-port redirects'

python3 "$GDM_ROOT/tests/test_archive.py"
ok 'Backup checksums, traversal, links, duplicate members and tampering'
python3 "$GDM_ROOT/tests/test_backups.py"
ok 'Backup inventory, streaming checks, export, deletion protection and available space before service interruption'

python3 - "$GDM_ROOT" <<'PY'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
def locale(lang):
    result = {}
    for line in (root / 'locales' / (lang + '.tsv')).read_text().splitlines():
        key, value = line.split('\t', 1)
        assert key not in result, key
        result[key] = value
    return result
en, es = locale('en'), locale('es')
assert en.keys() == es.keys()
for key in en:
    assert re.findall(r'%[sd]', en[key]) == re.findall(r'%[sd]', es[key]), key
assert '10.0.28' in en['glpi10_warning'] and '10.0.28' in es['glpi10_warning']
PY
ok 'English/Spanish key and format parity, including GLPI 10 support warning'
python3 "$GDM_ROOT/tests/test_prompts.py"
ok 'Real terminal prompts accept English/Spanish confirmation and assign caller variables safely'
python3 "$GDM_ROOT/tests/test_ui.py"
ok 'Real keyboard navigation, editable text, scrolling, cancellation and terminal restoration'
python3 "$GDM_ROOT/tests/test_setup.py"
python3 "$GDM_ROOT/tests/test_setup_terminal.py"
ok 'Editable configuration, searchable time zones, Back, validation, secret privacy and the complete dashboard'

if GDM_FAULT_DIR="$STATE/fault" bash "$GDM_ROOT/tests/fault-driver.sh"; then
    printf '%s\n' 'Failure injection unexpectedly succeeded' >&2; exit 1
fi
[[ -f $STATE/fault/operation.json ]]
[[ $(jq -r .status "$STATE/fault/current/config.json") == configured ]]
if grep -q UNSAFE_CONTINUATION "$STATE/fault/calls"; then exit 1; fi
ok 'Failed database initialization stops immediately, preserves journal and never reports readiness'

GDM_LANG=es bash "$GDM_ROOT/start.sh" help | grep -q 'Uso:'
bash "$GDM_ROOT/start.sh" help | grep -q 'cleanup'
[[ $(bash "$GDM_ROOT/start.sh" version) == "$(cat "$GDM_ROOT/VERSION")" ]]
ok 'Help and version work without Docker or elevated permissions'
printf '%s tests passed\n' "$passed"

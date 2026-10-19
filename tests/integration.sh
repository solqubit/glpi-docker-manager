#!/usr/bin/env bash
# Container commands must preserve variables for the container's own shell.
# shellcheck disable=SC2016
# Explicit opt-in. This creates and removes ONLY uniquely labelled test resources.
set -Eeuo pipefail
umask 077
[[ ${GDM_INTEGRATION:-0} == 1 ]] || { printf '%s\n' 'Set GDM_INTEGRATION=1 to authorize isolated Docker integration tests.' >&2; exit 2; }
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
GDM_STATE_DIR="$GDM_ROOT/tests/.runtime/integration-$(openssl rand -hex 8)"
GDM_CERT_DIR="$GDM_STATE_DIR/certs"
export GDM_STATE_DIR GDM_CERT_DIR
for module in core system releases config docker tls backup operations; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
# shellcheck source=tests/helpers.sh
source "$GDM_ROOT/tests/helpers.sh"
tr_load
ARCH=amd64
[[ $(docker info --format '{{.Architecture}}') != aarch64 ]] || ARCH=arm64
export ARCH
init_state
declare -a TEST_PROJECTS=()
test_cleanup() {
    local id role
    if [[ -r ${CONFIG:-/nonexistent} ]]; then TEST_PROJECTS+=("$(cfg id)"); fi
    for id in "${TEST_PROJECTS[@]}"; do
        docker ps -aq --filter "label=com.docker.compose.project=gdm_$id" | xargs -r docker rm -f >/dev/null
        docker network ls -q --filter "label=com.docker.compose.project=gdm_$id" | xargs -r docker network rm >/dev/null
        for role in glpi_data db_data plugins marketplace caddy_data caddy_config; do
            docker volume rm "gdm_${id}_$role" >/dev/null 2>&1 || true
        done
    done
}
trap test_cleanup EXIT
confirm() { return 0; }
typed_confirm() { return 0; }
id=$(openssl rand -hex 8); TEST_PROJECTS+=("$id")
test_config "$STATE/input.json" "$id"
glpi_version=${GDM_TEST_GLPI_VERSION:-11.0.11}
mysql_version=${GDM_TEST_MYSQL_VERSION:-$(official_tag_latest mysql 8.4)}
caddy_version=$(official_tag_latest caddy 2)
glpi_image=$(image_resolve glpi/glpi "$glpi_version")
mysql_image=$(image_resolve mysql "$mysql_version")
caddy_image=$(image_resolve caddy "$caddy_version")
jq --arg gv "$glpi_version" --arg gi "$glpi_image" --arg mv "$mysql_version" --arg mi "$mysql_image" --arg ci "$caddy_image" \
    --slurpfile passwords "$GDM_ROOT/tests/fixtures/passwords.json" \
    '.storage="directory" | .glpi_version=$gv | .major=($gv|split(".")[0]|tonumber) | .glpi_image=$gi | .mysql_version=$mv | .mysql_image=$mi | .caddy_image=$ci | .db_password=$passwords[0][7] | .root_password=$passwords[0][1]' \
    "$STATE/input.json" > "$STATE/real.json"
config_stage "$STATE/real.json"
config_activate "$REVISION"
journal_begin install
installation_finish
[[ $(docker volume inspect -f '{{index .Options "device"}}' "$(volume_name db_data)") == "$STATE/data/$(cfg id)/db_data" ]]
printf '%s\n' 'PASS: official image installation, authenticated database, GLPI schema and HTTP'

# Prove persistence across a container recreation, and recovery of actual user data.
dc exec -T glpi sh -c 'printf persistent-data > /var/glpi/files/gdm-integration-marker'
dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" exec mysql -u"$GDM_DB_USER" "$MYSQL_DATABASE"' <<'SQL'
INSERT INTO glpi_configs (context,name,value) VALUES ('gdm_integration','marker','before-backup');
SQL
dc up -d --force-recreate glpi
wait_healthy glpi
[[ $(dc exec -T glpi cat /var/glpi/files/gdm-integration-marker) == persistent-data ]]
backup_create
backup=$LAST_BACKUP
backup_extract "$backup"
dc exec -T glpi sh -c 'printf changed-after-backup > /var/glpi/files/gdm-integration-marker'
dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" exec mysql -u"$GDM_DB_USER" "$MYSQL_DATABASE"' <<'SQL'
UPDATE glpi_configs SET value='changed-after-backup' WHERE context='gdm_integration' AND name='marker';
SQL
printf '%s\n' 'PASS: recreation persistence and verified quiesced backup'

jq '.tls="self-signed"' "$CONFIG" > "$STATE/https.json"
apply_settings "$STATE/https.json"
verify_services
printf '%s\n' 'PASS: automatic self-signed HTTPS and trusted TLS probe'

if [[ ${GDM_TEST_EXPOSURE:-1} == 1 ]]; then
    jq '.expose_db=true' "$CONFIG" > "$STATE/expose.json"
    apply_settings "$STATE/expose.json"
    dc port db 3306 | grep -q ':3306'
    jq '.expose_db=false' "$CONFIG" > "$STATE/close.json"
    apply_settings "$STATE/close.json"
    docker inspect --format '{{json .NetworkSettings.Ports}}' "$(dc ps --quiet db)" |
        jq -e '.["3306/tcp"]==null' >/dev/null
    printf '%s\n' 'PASS: MySQL exposure on and off after installation'
fi

# Restore uses a new installation id and retains the previous test volumes.
restore_backup "$backup"
TEST_PROJECTS+=("$(cfg id)")
[[ $(dc exec -T glpi cat /var/glpi/files/gdm-integration-marker) == persistent-data ]]
actual=$(dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" exec mysql -u"$GDM_DB_USER" "$MYSQL_DATABASE" -Ns' <<'SQL'
SELECT value FROM glpi_configs WHERE context='gdm_integration' AND name='marker';
SQL
)
[[ $actual == before-backup ]]
printf '%s\n' 'PASS: guided restore into fresh volumes'

if version_gt "$(official_tag_latest mysql 8.4)" "$(cfg mysql_version)"; then
    update_database
    printf '%s\n' 'PASS: rehearsed independent MySQL patch update'
fi

if [[ ${GDM_TEST_MIGRATION:-1} == 1 && $(cfg major) == 10 ]]; then
    update_glpi migrate 11.0.11
    [[ $(cfg major) == 11 ]]
    printf '%s\n' 'PASS: GLPI 10 to 11 migration with legacy marketplace handling'
fi

if [[ ${GDM_TEST_MIGRATION:-1} == 1 && $(cfg major) == 11 ]]; then
    update_glpi migrate 12.0.0
    [[ $(cfg major) == 12 ]]
    [[ $(dc exec -T glpi cat /var/glpi/files/gdm-integration-marker) == persistent-data ]]
    printf '%s\n' 'PASS: isolated rehearsal and GLPI 11 to 12 production-path migration'
fi
printf 'Integration tests passed. Evidence retained privately at %s\n' "$STATE"

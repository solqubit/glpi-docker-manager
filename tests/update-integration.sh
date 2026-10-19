#!/usr/bin/env bash
# Opt-in real patch upgrade followed by restoration of its automatic backup.
# shellcheck disable=SC2016
set -Eeuo pipefail
umask 077
[[ ${GDM_INTEGRATION:-0} == 1 ]] || { printf 'Set GDM_INTEGRATION=1 for isolated Docker tests.\n' >&2; exit 2; }
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
GDM_STATE_DIR="$GDM_ROOT/tests/.runtime/update-$(openssl rand -hex 8)"
GDM_CERT_DIR="$GDM_STATE_DIR/certs"
export GDM_ROOT GDM_STATE_DIR GDM_CERT_DIR
for module in core system releases config docker tls backup maintenance operations; do
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
if [[ -n ${GDM_TEST_FREE_MIB:-} ]]; then
    # Report a controlled free-space value without filling or resizing any disk.
    df() {
        case $1 in
            -PTm) command df "$@" | awk -v free="$GDM_TEST_FREE_MIB" 'NR==2 {$5=free} {print}';;
            -Pm) command df "$@" | awk -v free="$GDM_TEST_FREE_MIB" 'NR==2 {$4=free} {print}';;
            *) command df "$@";;
        esac
    }
fi
declare -a TEST_PROJECTS=()
test_cleanup() {
    local id role
    [[ ! -r ${CONFIG:-/nonexistent} ]] || TEST_PROJECTS+=("$(cfg id)")
    for id in "${TEST_PROJECTS[@]}"; do
        # An individual cleanup failure must not leave later owned resources behind.
        docker ps -aq --filter "label=com.docker.compose.project=gdm_$id" | xargs -r docker rm -f >/dev/null || true
        docker network ls -q --filter "label=com.docker.compose.project=gdm_$id" | xargs -r docker network rm >/dev/null || true
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
glpi_image=$(image_resolve glpi/glpi 11.0.10)
mysql_version=$(official_tag_latest mysql 8.4)
mysql_image=$(image_resolve mysql "$mysql_version")
caddy_image=$(image_resolve caddy "$(official_tag_latest caddy 2)")
jq --arg gi "$glpi_image" --arg mv "$mysql_version" --arg mi "$mysql_image" --arg ci "$caddy_image" \
   '.storage="directory" | .glpi_version="11.0.10" | .glpi_image=$gi | .mysql_version=$mv | .mysql_image=$mi |
    .caddy_image=$ci | .http_port=18082 | .https_port=18445' "$STATE/input.json" > "$STATE/real.json"
config_stage "$STATE/real.json"
config_activate "$REVISION"
journal_begin install
installation_finish
dc exec -T glpi sh -c 'printf before-upgrade > /var/glpi/files/gdm-update-marker'
dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" exec mysql -u"$GDM_DB_USER" "$MYSQL_DATABASE"' <<'SQL'
INSERT INTO glpi_configs (context,name,value) VALUES ('gdm_update','marker','before-upgrade');
SQL
update_glpi update 11.0.11
[[ $(cfg glpi_version) == 11.0.11 ]]
backup=$(cat "$STATE/recovery-backup")
[[ -f $backup && $backup == "$STATE/backups/glpi-11.0.10-"* ]]
python3 "$GDM_ROOT/tools/backup_ops.py" check "$STATE" "$backup"
[[ $(jq -r .origin "$STATE/backups/.index/$(basename -- "$backup").json") == update ]]
[[ $(dc exec -T glpi cat /var/glpi/files/gdm-update-marker) == before-upgrade ]]
printf 'PASS: selected GLPI 11.0.10 to 11.0.11 upgrade, isolated rehearsal and automatic recovery backup\n'
dc exec -T glpi sh -c 'printf after-upgrade > /var/glpi/files/gdm-update-marker'
dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" exec mysql -u"$GDM_DB_USER" "$MYSQL_DATABASE"' <<'SQL'
UPDATE glpi_configs SET value='after-upgrade' WHERE context='gdm_update' AND name='marker';
SQL
restore_backup "$backup"
TEST_PROJECTS+=("$(cfg id)")
[[ $(cfg glpi_version) == 11.0.10 ]]
[[ $(dc exec -T glpi cat /var/glpi/files/gdm-update-marker) == before-upgrade ]]
actual=$(dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" exec mysql -u"$GDM_DB_USER" "$MYSQL_DATABASE" -Ns' <<'SQL'
SELECT value FROM glpi_configs WHERE context='gdm_update' AND name='marker';
SQL
)
[[ $actual == before-upgrade ]]
service_start
printf 'PASS: restore of the pre-update version, original SQL and file data, and idempotent Start\n'
printf 'Private patch/restore evidence: %s\n' "$STATE"

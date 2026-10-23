#!/usr/bin/env bash
# Retention and cleanup rules: backup rotation by kind, the restore policy for
# replaced installations and what Free disk space offers. Docker is stubbed.
# Stubs are called indirectly and CLEAN_*/RESTORE_* are read by sourced code.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
GDM_STATE_DIR="${GDM_STATE_DIR:?}/maintenance-cases"
export GDM_ROOT GDM_STATE_DIR
for module in core config backup maintenance; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
tr_load
mkdir -p "$STATE/backups" "$STATE/revisions"

# Human-readable sizes.
[[ $(human_size 0) == '0 KB' ]]
[[ $(human_size 1048576) == '1 MB' ]]
[[ $(human_size 1610612736) == '1.5 GB' ]]

# Rotation keeps the newest N of one kind; manual backups never match.
make_backup() {
    local file="$STATE/backups/glpi-11.0.11-2026101${1}T000000-$2.tar.gz"
    : > "$file"
    touch -d "2026-10-1$1" "$file"
}
for day in 1 2 3 4 5 6 7; do
    make_backup "$day" "auto-a0000$day"; make_backup "$day" "pre-b0000$day"; make_backup "$day" "c0000$day"
done
backup_prune auto 5
backup_prune pre 3
[[ $(find "$STATE/backups" -name '*-auto-*' | wc -l) == 5 ]]
[[ $(find "$STATE/backups" -name '*-pre-*' | wc -l) == 3 ]]
[[ $(find "$STATE/backups" -name 'glpi-*' ! -name '*-auto-*' ! -name '*-pre-*' | wc -l) == 7 ]]
[[ -f $STATE/backups/glpi-11.0.11-20261017T000000-pre-b00007.tar.gz ]]
[[ ! -f $STATE/backups/glpi-11.0.11-20261014T000000-pre-b00004.tar.gz ]]

# Restore policy: with a pre-restore backup only the replaced installation is
# removed; without one it is kept and any older kept installation is removed.
declare -a removed=() fake_previous=()
installation_remove() { removed+=("$1"); }
previous_installations() { printf '%s\n' "${fake_previous[@]}"; }
cfg() { [[ $1 != id ]] || printf 'cccccccccccccccc\n'; }
RESTORE_PREVIOUS_ID=aaaaaaaaaaaaaaaa
fake_previous=(aaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbb)
removed=() RESTORE_KEPT=''
restore_cleanup "$STATE/backups/pre.tar.gz"
[[ ${removed[*]} == aaaaaaaaaaaaaaaa && -z $RESTORE_KEPT ]]
removed=() RESTORE_KEPT=''
restore_cleanup ''
[[ ${removed[*]} == bbbbbbbbbbbbbbbb && $RESTORE_KEPT == aaaaaaaaaaaaaaaa ]]

# Free disk space keeps the active revision, the one before the last update
# and the 3 newest revisions; only images no longer needed are offered.
previous_installations() { :; }
docker() { if [[ $1 == image && $2 == inspect ]]; then printf '1048576\n'; else return 1; fi; }
digest=$(printf 'a%.0s' {1..64})
revision() {
    mkdir -p "$STATE/revisions/$1"
    jq -n --arg glpi "glpi/glpi:$2@sha256:$digest" --arg mysql "mysql:8.4.11@sha256:$digest" \
        --arg caddy "caddy:2.10.2@sha256:$digest" \
        '{id:"cccccccccccccccc",glpi_image:$glpi,mysql_image:$mysql,caddy_image:$caddy}' > "$STATE/revisions/$1/config.json"
}
revision 20261001T000000-0000000a 11.0.8
revision 20261002T000000-0000000b 11.0.9
revision 20261003T000000-0000000c 11.0.10
revision 20261004T000000-0000000d 11.0.10
revision 20261005T000000-0000000e 11.0.11
ln -sfn revisions/20261005T000000-0000000e "$STATE/current"
printf '%s\n' "$STATE/revisions/20261003T000000-0000000c" > "$STATE/previous-revision"
declare -a CLEAN_IMAGES=() CLEAN_PREVIOUS=() CLEAN_BACKUPS=() CLEAN_REVISIONS=() CLEAN_RELEASES=()
CLEAN_IMAGES_BYTES=0
cleanup_scan 2>/dev/null
[[ ${#CLEAN_IMAGES[@]} == 2 && $CLEAN_IMAGES_BYTES == 2097152 ]]
[[ " ${CLEAN_IMAGES[*]} " == *"glpi/glpi:11.0.8@"* && " ${CLEAN_IMAGES[*]} " == *"glpi/glpi:11.0.9@"* ]]
[[ ${#CLEAN_REVISIONS[@]} == 2 && ${#CLEAN_BACKUPS[@]} == 2 && ${#CLEAN_RELEASES[@]} == 0 ]]
# Schedule: format 2 round trip, frequency texts, due rules and preview.
LANGUAGE=en; tr_load
rm -f -- "$STATE/maintenance.json"
maintenance_settings
[[ $MAINT_BACKUPS == false && $MAINT_HOUR == 3 && $MAINT_MINUTE == 0 && $MAINT_MODE == days && $MAINT_EVERY == 1 ]]
MAINT_BACKUPS=true MAINT_HOUR=2 MAINT_MINUTE=30 MAINT_MODE=weekdays MAINT_WEEKDAYS='5 1 3'
maintenance_write
maintenance_settings
[[ $MAINT_BACKUPS == true && $MAINT_HOUR == 2 && $MAINT_MINUTE == 30 && $MAINT_MODE == weekdays && $MAINT_WEEKDAYS == '1 3 5' ]]
[[ $(maintenance_time_text) == 02:30 && $(maintenance_frequency_text) == 'Mon, Wed, Fri' ]]
MAINT_WEEKDAYS='1 2 3 4 5'; [[ $(maintenance_frequency_text) == 'Monday to Friday' ]]
MAINT_WEEKDAYS=7; [[ $(maintenance_frequency_text) == 'every Sunday' && $(maintenance_coverage_days) == 35 ]]
MAINT_WEEKDAYS=$(date +%u); backup_due
MAINT_WEEKDAYS=$(( $(date +%u) % 7 + 1 )); if backup_due; then exit 1; fi
[[ $(maintenance_next_runs 3 | wc -l) == 3 ]]
MAINT_MODE=days MAINT_EVERY=2
rm -f -- "$STATE"/backups/*-auto-*
backup_due
recent="$STATE/backups/glpi-11.0.11-20261020T000000-auto-d00001.tar.gz"
: > "$recent"
if backup_due; then exit 1; fi
touch -d '3 days ago' "$recent"
backup_due
[[ $(maintenance_frequency_text) == 'every 2 days' && $(maintenance_coverage_days) == 10 ]]
[[ $(maintenance_next_runs 3 | wc -l) == 3 ]]
# Log rotation: recommended defaults, only offered values, round trip.
log_settings_read ''
[[ $LOG_MANAGER_DAYS == 30 && $LOG_GLPI_MB == 20 && $LOG_GLPI_DAYS == 30 && $LOG_CONTAINER_MB == 10 && $LOG_CONTAINER_FILES == 3 && $LOG_BINLOG_DAYS == 30 ]]
log_settings_read 'glpi_mb=50 binlog_days=3 container_mb=999 manager_days=x'
[[ $LOG_GLPI_MB == 50 && $LOG_BINLOG_DAYS == 3 && $LOG_CONTAINER_MB == 10 && $LOG_MANAGER_DAYS == 30 ]]
maintenance_write
maintenance_settings
[[ $LOG_GLPI_MB == 50 && $LOG_BINLOG_DAYS == 3 && $MAINT_MODE == days && $MAINT_EVERY == 2 ]]
[[ $(jq -r '.logs.binlog_days' "$STATE/maintenance.json") == 3 ]]
# Daily schedules have no weekdays; that empty field must not swallow log settings.
MAINT_WEEKDAYS=''
maintenance_write
maintenance_settings
[[ -z $MAINT_WEEKDAYS && $LOG_GLPI_MB == 50 && $LOG_BINLOG_DAYS == 3 ]]
(
    MAINT_MODE=days MAINT_EVERY=2 MAINT_WEEKDAYS=''
    frequency_calls=0
    choose() {
        local output=$1 prompt=$2 answer
        frequency_calls=$((frequency_calls+1))
        [[ ${!#} == "$(ui_opt back "$(t ui_back_previous)")" ]] || exit 1
        case $frequency_calls:$prompt in
            1:maint_freq_prompt) answer=pick;;
            2:weekdays_prompt) answer=back;;
            3:maint_freq_prompt) answer=back;;
            *) printf 'Unexpected frequency screen: %s\n' "$prompt" >&2; exit 1;;
        esac
        printf -v "$output" '%s' "$answer"
    }
    if frequency_menu; then exit 1; fi
    [[ $frequency_calls == 3 && $MAINT_MODE == days && $MAINT_EVERY == 2 && -z $MAINT_WEEKDAYS ]]
)
(
    # Cancelling RESTORE returns to the file list without reopening its details.
    calls="$STATE/restore-cancel-calls"
    python3() {
        [[ $1 == "$GDM_ROOT/tools/backup_manager.py" ]] || return 1
        printf 'call\n' >> "$calls"
        if [[ $(wc -l < "$calls") == 1 ]]; then
            printf '{"action":"restore","archive":"%s/backups/cancel.tar.gz"}\n' "$STATE" > "$4"
        else
            [[ -z ${5:-} ]] || exit 1
            printf '{"action":"back"}\n' > "$4"
        fi
    }
    restore_backup() { RESTORE_CANCELLED=true; }
    ui_pause() { exit 1; }
    backup_manage
    [[ $(wc -l < "$calls") == 2 ]]
    rm -- "$calls"
    restore_backup() { RESTORE_CANCELLED=false; }
    ui_pause() { printf 'read\n' > "$STATE/restore-result-read"; }
    backup_manage
    [[ $(wc -l < "$calls") == 2 && -f $STATE/restore-result-read ]]
)
printf 'PASS: backup rotation by kind, restore cleanup policy, free-space selection, backup schedules, nested Back navigation and log rotation settings\n'

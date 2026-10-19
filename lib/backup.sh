#!/usr/bin/env bash
# Container-only expansion and shared state returned to operations.sh are intentional.
# shellcheck disable=SC2016,SC2034
SNAPSHOT_ROLES=(glpi_data plugins marketplace caddy_data caddy_config)
LAST_BACKUP=
RESUME_GLPI_ON_EXIT=false
snapshot_save() {
    local role=$1 destination=$2
    docker run --rm --network none --label org.glpidm.helper=true --user 0 \
        --mount "type=volume,src=$(volume_name "$role"),dst=/data,readonly" \
        --entrypoint tar "$(cfg glpi_image)" -C /data --exclude='./files/_cache' -czf - . > "$destination"
}
snapshot_restore() {
    local role=$1 source=$2
    docker run --rm -i --network none --label org.glpidm.helper=true --user 0 \
        --mount "type=volume,src=$(volume_name "$role"),dst=/data" \
        --entrypoint tar "$(cfg glpi_image)" -C /data -xzf - < "$source"
}
backup_create() {
    assert_running
    local resume=${1:-true} origin=${2:-manual} target=${3:-} work archive role size free volume_size was_proxy=false required database_size
    local usage measured=0
    local -a mounts=() paths=()
    case $origin in manual|update|migrate|db-update|refresh-image|transfer) ;; *) die invalid backup_origin;; esac
    ui_status "$(t status_measure)"
    # Use uncompressed volume usage plus database size as a conservative budget.
    database_size=$(dc exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -Nse "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables"')
    [[ $database_size =~ ^[0-9]+$ ]] || die backup_space
    # SQL text/hex literals can exceed physical table data. Staging and final
    # archive are budgeted without assuming a particular compression ratio.
    size=$((database_size*3))
    # One read-only helper measures every volume instead of one container each.
    for role in "${SNAPSHOT_ROLES[@]}"; do
        mounts+=(--mount "type=volume,src=$(volume_name "$role"),dst=/data/$role,readonly")
        paths+=("/data/$role")
    done
    usage=$(docker run --rm --network none --user 0 "${mounts[@]}" --entrypoint du "$(cfg glpi_image)" -sb "${paths[@]}")
    while read -r volume_size _; do
        [[ $volume_size =~ ^[0-9]+$ ]] || die backup_space
        size=$((size+volume_size)); measured=$((measured+1))
    done <<< "$usage"
    (( measured == ${#SNAPSHOT_ROLES[@]} )) || die backup_space
    required=$(((size*2+1048575)/1048576))
    free=$(df -Pm "$STATE" | awk 'NR==2 {print $4}')
    ui_progress_note backup_estimate "$(((size+1048575)/1048576))" "$((required+512))" "$free"
    storage_preflight 0 "$required"
    work=$(mktemp -d "$STATE/backups/.work-XXXXXX"); CLEANUP_DIRECTORIES+=("$work")
    archive="$STATE/backups/glpi-$(cfg glpi_version)-$(date -u +%Y%m%dT%H%M%S)-$(openssl rand -hex 3).tar.gz"
    CLEANUP_PATHS+=("$archive.partial")
    say backup_started
    if [[ $(cfg tls) != off && -n $(dc ps --status running --quiet proxy) ]]; then was_proxy=true; dc stop proxy; fi
    dc stop glpi
    RESUME_GLPI_ON_EXIT=true
    cp -- "$CONFIG" "$work/config.json"
    ui_status "$(t status_dump)"
    dc exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --routines --events --triggers --hex-blob --no-tablespaces --set-gtid-purged=OFF "$MYSQL_DATABASE"' > "$work/mysql.sql"
    for role in "${SNAPSHOT_ROLES[@]}"; do ui_status "$(t status_snapshot "$role")"; snapshot_save "$role" "$work/$role.tar.gz"; done
    if [[ -f $STATE/current/tls/fullchain.pem ]]; then
        mkdir "$work/tls"; cp -- "$STATE/current/tls/"*.pem "$work/tls/"
    fi
    jq -n --arg now "$(date -u +%FT%TZ)" --arg glpi "$(cfg glpi_version)" \
        --arg mysql "$(dc exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -Nse "SELECT VERSION()"')" \
        --arg arch "$ARCH" --arg origin "$origin" --arg target "$target" \
        '{format:1,created_at:$now,glpi_version:$glpi,mysql_server_version:$mysql,architecture:$arch,origin:$origin,target_version:$target}' > "$work/metadata.json"
    (cd "$work" && for name in config.json metadata.json mysql.sql ./*.tar.gz tls/*.pem; do
        [[ -f $name ]] || continue
        name=${name#./}
        sha256sum -- "$name"
    done > checksums.sha256)
    ui_status "$(t status_archive)"
    python3 "$GDM_ROOT/tools/archive.py" verify "$work" || die backup_invalid
    tar -C "$work" -czf "$archive.partial" .
    mv -- "$archive.partial" "$archive"
    chmod 600 "$archive"
    python3 "$GDM_ROOT/tools/backup_ops.py" check "$STATE" "$archive"
    RESUME_GLPI_ON_EXIT=false
    if [[ $resume == true ]]; then
        dc start glpi
        [[ $was_proxy != true ]] || dc start proxy
        wait_healthy glpi
    fi
    LAST_BACKUP=$archive
    say backup_ready "$archive"
    # Exact directory from mktemp under our private backup directory.
    if [[ $work == "$STATE/backups/.work-"* && ! -L $work ]]; then rm -rf -- "$work"; fi
}
backup_extract() {
    local archive=$1
    [[ $archive == /* && -f $archive ]] || die backup_invalid
    EXTRACTED="$STATE/backups/.restore-$(openssl rand -hex 8)"
    CLEANUP_DIRECTORIES+=("$EXTRACTED")
    python3 "$GDM_ROOT/tools/archive.py" extract "$archive" "$EXTRACTED" || die backup_invalid
    config_validate "$EXTRACTED/config.json"
}
restore_into_current() {
    local folder=$1 role data_need
    data_need=$(python3 "$GDM_ROOT/tools/archive.py" footprint "$folder")
    pull_images "$data_need"
    volumes_ensure
    for role in "${SNAPSHOT_ROLES[@]}"; do ui_status "$(t status_restore_volume "$role")"; snapshot_restore "$role" "$folder/$role.tar.gz"; done
    dc up -d db
    wait_healthy db
    ui_status "$(t status_import)"
    dc exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$MYSQL_DATABASE"' < "$folder/mysql.sql"
}
restore_backup() {
    local archive=${1:-} selection picker_result
    if [[ -z $archive ]]; then
        selection=$(mktemp "$STATE/.backup-choice.XXXXXX"); CLEANUP_PATHS+=("$selection")
        if python3 "$GDM_ROOT/tools/backup_picker.py" "$STATE/backups" "$LANGUAGE" "$selection"; then picker_result=0; else picker_result=$?; fi
        [[ $picker_result == 0 ]] || exit "$picker_result"
        IFS= read -r archive < "$selection"
    fi
    backup_extract "$archive"
    ui_panel "$(t backup_selected)" "$archive" "$(t restore_effect)"
    typed_confirm RESTORE
    ui_run 0 backup_step_restore restore_selected_backup "$archive"
    ui_panel "✓ $(t restore_done)" "$(t ready "$(installation_url)")" "$archive"
}
restore_selected_backup() {
    local tmp old_revision='' had_install=false archive=${1:-}
    if [[ -L $STATE/current ]]; then
        config_load; old_revision=$(readlink -f "$STATE/current"); had_install=true
    fi
    # Existing journals are evidence, not discarded when recovery uses a restore.
    if [[ -f $STATE/operation.json ]]; then
        cp -- "$STATE/operation.json" "$STATE/recovery-$(date -u +%Y%m%dT%H%M%S).json"
        rm -- "$STATE/operation.json"
    fi
    journal_begin restore
    [[ -z $archive ]] || printf '%s\n' "$archive" > "$STATE/recovery-backup"
    tmp=$(mktemp "$STATE/.restore-config.XXXXXX"); CLEANUP_PATHS+=("$tmp")
    local new_id
    new_id=$(openssl rand -hex 8)
    jq --arg id "$new_id" --arg cert_dir "$CERT_ROOT" '.id=$id | .project=("gdm_"+$id) | .cert_dir=$cert_dir | .storage="directory" | .status="configured"' "$EXTRACTED/config.json" > "$tmp"
    if [[ -d $EXTRACTED/tls ]]; then
        local cert_mode
        cert_mode=$(jq -r .tls "$tmp")
        mkdir -p "$CERT_ROOT/$cert_mode"
        cp -- "$EXTRACTED/tls/"*.pem "$CERT_ROOT/$cert_mode/"
        chmod 600 "$CERT_ROOT/$cert_mode/"*.pem
    fi
    config_stage "$tmp"
    [[ $had_install != true ]] || dc stop
    config_activate "$REVISION"
    journal_phase restoring
    restore_into_current "$EXTRACTED"
    data_ownership_repair
    dc up -d
    verify_services
    config_set_status ready
    journal_done
    [[ -z $old_revision ]] || printf '%s\n' "$old_revision" > "$STATE/previous-revision"
}
backup_list() {
    say backup_list
    find "$STATE/backups" -maxdepth 1 -type f -name 'glpi-*.tar.gz' -printf '%f\n' | LC_ALL=C sort
}
backup_manage() {
    local request action archive destination focus='' notice=''
    request=$(mktemp "$STATE/.backup-action.XXXXXX"); CLEANUP_PATHS+=("$request")
    while :; do
        if python3 "$GDM_ROOT/tools/backup_manager.py" "$STATE" "$LANGUAGE" "$request" "$focus" "$notice"; then :
        else return 0; fi
        action=$(jq -er .action "$request")
        [[ $action != back ]] || return 0
        archive=$(jq -er .archive "$request"); focus=$archive; notice=''
        case $action in
            inspect) ui_run 0 backups_step_inspect python3 "$GDM_ROOT/tools/backup_ops.py" inspect "$STATE" "$archive";;
            verify)
                ui_run 0 backups_step_verify python3 "$GDM_ROOT/tools/backup_ops.py" verify "$STATE" "$archive"
                notice=$(t backups_check_done);;
            restore) restore_backup "$archive"; notice=$(t restore_done);;
            delete)
                ui_run 0 backups_step_delete python3 "$GDM_ROOT/tools/backup_ops.py" delete "$STATE" "$archive"
                focus=''; notice=$(t backups_deleted);;
            export)
                destination=$(jq -er .destination "$request")
                ui_run 0 backups_step_export python3 "$GDM_ROOT/tools/backup_ops.py" export "$STATE" "$archive" "$destination"
                notice=$(t backups_exported "$destination");;
            *) die invalid backup_action;;
        esac
    done
}

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
    local usage measured=0 tag
    local -a mounts=() paths=()
    case $origin in manual|auto|update|migrate|db-update|refresh-image|transfer|restore) ;; *) die invalid backup_origin;; esac
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
    # Rotation works on names: "-auto-" scheduled (5 kept), "-pre-" taken before
    # an update/restore (3 kept). Manual and transfer backups are never rotated.
    case $origin in auto) tag=auto-;; update|migrate|db-update|refresh-image|restore) tag=pre-;; *) tag='';; esac
    archive="$STATE/backups/glpi-$(cfg glpi_version)-$(date -u +%Y%m%dT%H%M%S)-$tag$(openssl rand -hex 3).tar.gz"
    CLEANUP_PATHS+=("$archive.partial")
    ui_progress_note backup_started
    if [[ $(cfg tls) != off && -n $(dc ps --status running --quiet proxy) ]]; then was_proxy=true; dc stop proxy; fi
    dc stop glpi
    RESUME_GLPI_ON_EXIT=true
    cp -- "$CONFIG" "$work/config.json"
    ui_status "$(t status_dump)"
    dc exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --routines --events --triggers --hex-blob --no-tablespaces --set-gtid-purged=OFF "$MYSQL_DATABASE"' > "$work/mysql.sql"
    for role in "${SNAPSHOT_ROLES[@]}"; do ui_status "$(t status_snapshot "$role")"; snapshot_save "$role" "$work/$role.tar.gz"; done
    if [[ -f $STATE/current/tls/fullchain.pem ]]; then
        mkdir "$work/tls"; cp -- "$STATE/current/tls/"*.pem "$work/tls/"
        # The local CA key travels with the backup: a restored server keeps the
        # same CA, so GLPI Agents and browsers keep trusting it.
        if [[ $(cfg tls) == self-signed && -f $(cfg cert_dir)/self-signed/ca/gdm-ca.key ]]; then
            cp -- "$(cfg cert_dir)/self-signed/ca/gdm-ca.key" "$work/tls/gdm-ca.key"
        fi
    fi
    jq -n --arg now "$(date -u +%FT%TZ)" --arg glpi "$(cfg glpi_version)" \
        --arg mysql "$(dc exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -Nse "SELECT VERSION()"')" \
        --arg arch "$ARCH" --arg origin "$origin" --arg target "$target" \
        '{format:1,created_at:$now,glpi_version:$glpi,mysql_server_version:$mysql,architecture:$arch,origin:$origin,target_version:$target}' > "$work/metadata.json"
    (cd "$work" && for name in config.json metadata.json mysql.sql ./*.tar.gz tls/*.pem tls/*.key; do
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
    [[ $tag != pre- ]] || backup_prune pre "$PRE_BACKUP_KEEP"
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
# Going back to a backup never leaves a growing pile of installations:
#  1/3 the current installation is backed up first (origin "restore"), when it runs;
#  2/3 the backup is restored into new volumes and verified;
#  3/3 the replaced installation is removed when step 1 saved it. If it could not
#      be backed up (broken/stopped), it is kept as the only return point and any
#      older kept installation is removed.
restore_backup() {
    local archive=${1:-} selection picker_result pre_backup='' note
    RESTORE_PREVIOUS_ID='' RESTORE_KEPT=''
    if [[ -z $archive ]]; then
        selection=$(mktemp "$STATE/.backup-choice.XXXXXX"); CLEANUP_PATHS+=("$selection")
        if python3 "$GDM_ROOT/tools/backup_picker.py" "$STATE/backups" "$LANGUAGE" "$selection"; then picker_result=0; else picker_result=$?; fi
        [[ $picker_result == 0 ]] || exit "$picker_result"
        IFS= read -r archive < "$selection"
    fi
    # Extracting and checking a large archive takes a while: show it.
    ui_task restore_checking backup_extract "$archive"
    local replaced='' id
    if restore_can_backup; then note=$(t restore_plan_safe)
    elif [[ ! -L $STATE/current ]]; then note=$(t restore_plan_fresh)
    else
        note=$(t restore_plan_keep)
        # Only when there is a current installation to keep in its place.
        if [[ -L $STATE/current ]]; then
            while IFS= read -r id; do replaced+="${replaced:+, }GLPI $(installation_version "$id")"; done < <(previous_installations)
            [[ -z $replaced ]] || note+=" $(t restore_replaces_kept "$replaced")"
        fi
    fi
    local contents installed=''
    contents="GLPI $(jq -r '.glpi_version // "?"' "$EXTRACTED/metadata.json" 2>/dev/null) · $(jq -r '.created_at // "?"' "$EXTRACTED/metadata.json" 2>/dev/null)"
    [[ ! -L $STATE/current ]] || installed="$(t restore_installed)"$'\t'"GLPI $(cfg glpi_version)"
    ui_panel "$(t backup_selected)" \
        "$(t restore_file)"$'\t'"${archive##*/}" "$(t restore_folder)"$'\t'"${archive%/*}" \
        "$(t restore_contents)"$'\t'"$contents" ${installed:+"$installed"} \
        "§$(t restore_section_plan)" "$(t restore_effect)" "$note"
    # From the backup list, Esc returns to it instead of leaving.
    if ! typed_confirm RESTORE soft; then
        [[ ${RESTORE_FROM_LIST:-false} == true ]] || die cancelled
        RESTORE_CANCELLED=true; return 0
    fi
    local first=1/2 second=2/2 fresh=false
    [[ -L $STATE/current ]] || fresh=true
    if restore_can_backup; then
        RESTORE_PREVIOUS_ID=$(cfg id)
        ui_run 1/3 restore_step_backup backup_create true restore
        pre_backup=$LAST_BACKUP first=2/3 second=3/3
    fi
    if [[ $fresh == true ]]; then ui_run 0 backup_step_restore restore_selected_backup "$archive"
    else
        ui_run "$first" backup_step_restore restore_selected_backup "$archive"
        # Only announce a removal when one happens; otherwise it is kept.
        if [[ -n $pre_backup ]]; then ui_run "$second" restore_step_cleanup restore_cleanup "$pre_backup"
        else ui_run "$second" restore_step_keep restore_cleanup ''; fi
    fi
    maintenance_ensure
    if [[ -n $pre_backup ]]; then note=$(t restore_removed_previous "$pre_backup")
    elif [[ -n $RESTORE_KEPT ]]; then note=$(t restore_kept_previous)
    else note=''; fi
    [[ $fresh != true ]] || note+="${note:+ }$(t restore_new_server)"
    ui_panel "✓ $(t restore_done_title)" "$(t ready "$(installation_url)")" "$(t restore_done)" "$archive" ${note:+"$note"}
}
# The running installation can be backed up before it is replaced.
restore_can_backup() {
    [[ -L $STATE/current && ! -f $STATE/operation.json ]] || return 1
    ( config_load ) >/dev/null 2>&1 || return 1
    config_load
    [[ $(cfg status) == ready && -n $(dc ps --status running --quiet glpi) && -n $(dc ps --status running --quiet db) ]]
}
restore_selected_backup() {
    local tmp old_revision='' had_install=false archive=${1:-}
    if [[ -L $STATE/current ]]; then
        config_load; old_revision=$(readlink -f "$STATE/current"); had_install=true
        [[ -n $RESTORE_PREVIOUS_ID ]] || RESTORE_PREVIOUS_ID=$(cfg id)
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
    jq --arg id "$new_id" --arg cert_dir "$CERT_ROOT" --arg language "$LANGUAGE" --argjson fresh "$([[ $had_install == true ]] && echo false || echo true)" \
        '.id=$id | .project=("gdm_"+$id) | .cert_dir=$cert_dir | .storage="directory" | .status="configured" |
         if $fresh then .language=$language else . end' "$EXTRACTED/config.json" > "$tmp"
    if [[ -d $EXTRACTED/tls ]]; then
        local cert_mode name
        cert_mode=$(jq -r .tls "$tmp")
        mkdir -p "$CERT_ROOT/$cert_mode"
        for name in fullchain.pem privkey.pem; do
            [[ ! -f $EXTRACTED/tls/$name ]] || cp -- "$EXTRACTED/tls/$name" "$CERT_ROOT/$cert_mode/"
        done
        chmod 600 "$CERT_ROOT/$cert_mode/"*.pem
        # Same local CA as the source server: GLPI Agents need no change.
        if [[ $cert_mode == self-signed && -f $EXTRACTED/tls/gdm-ca.pem && -f $EXTRACTED/tls/gdm-ca.key ]]; then
            mkdir -p "$CERT_ROOT/self-signed/ca"; chmod 700 "$CERT_ROOT/self-signed/ca"
            cp -- "$EXTRACTED/tls/gdm-ca.pem" "$EXTRACTED/tls/gdm-ca.key" "$CERT_ROOT/self-signed/ca/"
            chmod 600 "$CERT_ROOT/self-signed/ca/gdm-ca.key"; chmod 644 "$CERT_ROOT/self-signed/ca/gdm-ca.pem"
        fi
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
# Runs only after the restored installation passed every check.
restore_cleanup() {
    local pre_backup=${1:-} current id
    current=$(cfg id)
    if [[ -n $pre_backup && -n $RESTORE_PREVIOUS_ID ]]; then
        # Its data is in the new [P] backup; an older kept installation stays.
        installation_remove "$RESTORE_PREVIOUS_ID"
        rm -f -- "$STATE/previous-revision"
        return 0
    fi
    RESTORE_KEPT=$RESTORE_PREVIOUS_ID
    [[ -n $RESTORE_KEPT ]] || return 0
    # It becomes the only return point; the panel announced the replacement.
    while IFS= read -r id; do
        [[ $id == "$current" || $id == "$RESTORE_KEPT" ]] || installation_remove "$id"
    done < <(previous_installations)
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
        else local rc=$?; (( rc != 130 )) || exit 130; return 0; fi
        action=$(jq -er .action "$request")
        [[ $action != back ]] || return 0
        archive=$(jq -er .archive "$request"); focus=$archive; notice=''
        case $action in
            inspect) ui_run 0 backups_step_inspect python3 "$GDM_ROOT/tools/backup_ops.py" inspect "$STATE" "$archive";;
            verify)
                ui_run 0 backups_step_verify python3 "$GDM_ROOT/tools/backup_ops.py" verify "$STATE" "$archive"
                notice=$(t backups_check_done);;
            restore)
                RESTORE_FROM_LIST=true RESTORE_CANCELLED=false
                restore_backup "$archive"
                if [[ $RESTORE_CANCELLED == true ]]; then focus=''; continue; fi
                ui_pause
                focus=''
                notice=$(t restore_done_title);;
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

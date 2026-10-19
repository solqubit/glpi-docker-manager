#!/usr/bin/env bash
# Rehearsals intentionally change STATE only inside their subshell.
# shellcheck disable=SC2030,SC2031,SC2034
installation_url() {
    local port scheme suffix
    if [[ $(cfg tls) == off ]]; then scheme=http; port=$(cfg http_port); else scheme=https; port=$(cfg https_port); fi
    suffix=":$port"
    [[ $scheme != http || $port != 80 ]] || suffix=''
    [[ $scheme != https || $port != 443 ]] || suffix=''
    printf '%s://%s%s\n' "$scheme" "$(cfg hostname)" "$suffix"
}
installation_ports_check() {
    local port
    port=$(cfg http_port); port_free "$port" || die port_busy "$port"
    if [[ $(cfg tls) != off ]]; then port=$(cfg https_port); port_free "$port" || die port_busy "$port"; fi
    [[ $(cfg expose_db) != true ]] || port_free 3306 || die port_busy 3306
}
installation_finish() {
    storage_preflight 0 1024
    ui_run 1/8 ui_step_volumes volumes_ensure
    ui_run 2/8 ui_step_images pull_images 1024
    ui_run 3/8 ui_step_plugins initialize_plugin_volume
    ui_run 4/8 ui_step_database start_database
    ui_run 5/8 ui_step_install install_database
    ui_run 6/8 ui_step_requirements oneoff_action requirements
    ui_run 7/8 ui_step_services dc up -d
    ui_run 8/8 ui_step_verify verify_services
    config_set_status ready
    journal_done
    maintenance_ensure
    [[ $(cfg expose_db) != true ]] || say firewall_docker 3306
    # Self-signed HTTPS: what to give GLPI Agents (CA file, URL, fingerprint).
    local -a ca_rows=()
    [[ $(cfg tls) != self-signed ]] || ca_rows_build
    ui_panel "$(t ui_install_success)" "$(t ready "$(installation_url)")" \
        "GLPI $(cfg glpi_version) · MySQL $(cfg mysql_version)" \
        "$(t ui_initial_account)" "$(t ui_next_steps)" "$(t layout_entrypoint "$STATE/start.sh")" "${ca_rows[@]}"
}
start_database() { dc up -d db; wait_healthy db; }
service_snapshot() {
    SERVICE_DATA=$(mktemp "$STATE/.services.XXXXXX")
    CLEANUP_PATHS+=("$SERVICE_DATA")
    dc ps --all --format json > "$SERVICE_DATA"
}
service_status() {
    service_snapshot
    python3 "$GDM_ROOT/tools/service_view.py" "$CONFIG" "$SERVICE_DATA" "$LANGUAGE" status "${GDM_IN_MENU:-false}"
}
service_logs() {
    local log_file
    log_file=$(mktemp "$STATE/.service-logs.XXXXXX"); CLEANUP_PATHS+=("$log_file")
    dc logs --no-color --tail 150 > "$log_file" 2>&1
    python3 "$GDM_ROOT/tools/service_view.py" "$CONFIG" "$log_file" "$LANGUAGE" logs "${GDM_IN_MENU:-false}"
}
service_start_action() { data_ownership_repair; dc up -d; verify_services; }
service_check_action() { data_ownership_repair; verify_services; }
service_refresh_action() { data_ownership_repair; tls_reapply; }
recover_services() { dc up -d; verify_services; config_set_status ready; journal_done; }
service_start() {
    [[ $(cfg status) == ready && ! -f $STATE/operation.json ]] || die ui_pending_body
    service_snapshot
    local current
    current=$(python3 "$GDM_ROOT/tools/service_view.py" "$CONFIG" "$SERVICE_DATA" "$LANGUAGE" state false)
    if ! jq -e '.services.glpi.logging' "$STATE/current/compose.json" >/dev/null 2>&1; then
        # Revisions from older versions lack container log limits: re-render once.
        say compose_refresh
        ui_run 0 ui_service_starting service_refresh_action
    elif [[ $current == running ]]; then ui_run 0 ui_service_checking service_check_action
    else ui_run 0 ui_service_starting service_start_action; fi
    ui_panel "$(t ui_service_ready)" "$(t ready "$(installation_url)")" "$(t ui_next_steps)"
}
select_major() {
    # MINIMUM excludes branches at or below it: 10 for new installations (GLPI 10
    # is end of life; it stays restorable and reachable with "install 10.x.y").
    local major_output=$1 major_default=$2 major_minimum=${3:-10} major_mode=${5:-install} major_value major_first=true
    local -a major_options=()
    while IFS= read -r major_value; do
        (( major_value > major_minimum )) || continue
        if [[ $major_mode == migrate ]]; then
            major_options+=("$major_value" "$(ui_opt warn "GLPI $major_value" "$(t opt_update_major "$major_minimum" "$major_value")")")
        elif [[ $major_first == true ]]; then
            major_options+=("$major_value" "$(ui_opt primary "GLPI $major_value · $(t opt_recommended)" "$(t opt_major_latest)")")
        else
            major_options+=("$major_value" "$(ui_opt '' "GLPI $major_value" "$(t opt_major_older)")")
        fi
        major_first=false
    done < <(jq -r '[.[].version|split(".")[0]|tonumber]|unique|sort|reverse|.[]|select(.>=10)' "$STATE/cache/releases.json")
    (( ${#major_options[@]} > 0 )) || die image_missing "$major_default"
    [[ ${4:-false} != true ]] || major_options+=(back "$(ui_opt back "$(t setup_return_edit)")")
    if ! choose "$major_output" major_prompt "$major_default" "${major_options[@]}"; then
        if [[ ${4:-false} == true ]]; then printf -v "$major_output" '%s' back; else die cancelled; fi
    fi
}
installation_summary() {
    local summary_file=$1 summary_tls summary_access
    summary_tls=$(jq -r .tls "$summary_file")
    summary_access=$(jq -r .expose_db "$summary_file")
    [[ $summary_access == true ]] && summary_access=$(t ui_db_public) || summary_access=$(t ui_db_private)
    ui_panel "$(t ui_summary)" \
        "GLPI $(jq -r .glpi_version "$summary_file") · MySQL $(jq -r .mysql_version "$summary_file")" \
        "$(t ui_host): $(jq -r .hostname "$summary_file")" \
        "HTTP: $(jq -r .http_port "$summary_file") · HTTPS: $(jq -r .https_port "$summary_file")" \
        "HTTPS: $(t "ui_tls_$summary_tls")" \
        "MySQL: $summary_access" \
        "$(t ui_database): $(jq -r .db_name "$summary_file") / $(jq -r .db_user "$summary_file")" \
        "$(t ui_secrets_hidden)"
}
install_wizard() {
    local requested=${1:-} major id file clean_file editor_result detected_host
    local mysql_version mysql_image caddy_version caddy_image
    if [[ -L $STATE/current ]]; then
        config_load
        [[ $(cfg status) != ready ]] || die install_exists
        [[ ! -f $STATE/operation.json || $(jq -r .action "$STATE/operation.json") == install ]] || die recovery_notice "$STATE/operation.json"
        confirm install_resume || die cancelled
        [[ -f $STATE/operation.json ]] || journal_begin install
        installation_finish
        return
    fi
    check_resources
    ui_task ui_releases_loading release_fetch
    if [[ -n $requested ]]; then major=${requested%%.*}
    else
        select_major major "$(jq -r '[.[].version|split(".")[0]|tonumber]|max' "$STATE/cache/releases.json")" 10 false install
    fi
    [[ $major =~ ^[1-9][0-9]{1,2}$ ]] || die invalid major
    select_version "$major" "$requested"
    ui_task setup_loading_images support_images_lookup
    id=$(openssl rand -hex 8)
    file=$(mktemp "$STATE/.install.XXXXXX"); clean_file=$(mktemp "$STATE/.validated.XXXXXX")
    CLEANUP_PATHS+=("$file" "$clean_file")
    detected_host=$(server_primary_address)
    jq -n --arg id "$id" --arg major "$major" --arg version "$SELECTED_VERSION" --arg image "$SELECTED_IMAGE" \
        --arg mysql_version "$mysql_version" --arg mysql_image "$mysql_image" --arg caddy_image "$caddy_image" \
        --arg language "$LANGUAGE" --arg cert_dir "$CERT_ROOT" --arg host "$detected_host" \
        '{format:1,id:$id,project:("gdm_"+$id),major:($major|tonumber),glpi_version:$version,glpi_image:$image,
          mysql_version:$mysql_version,mysql_image:$mysql_image,caddy_image:$caddy_image,
          http_port:80,https_port:443,timezone:"UTC",db_name:"glpi",db_user:"glpi",
          db_password:"",root_password:"",language:$language,cert_dir:$cert_dir,expose_db:false,
          hostname:$host,_detected_host:$host,tls:"off",storage:"directory",status:"configured"}' > "$file"
    while :; do
        if python3 "$GDM_ROOT/tools/setup.py" "$file" "$LANGUAGE"; then editor_result=0; else editor_result=$?; fi
        case $editor_result in
            0)
                config_validate "$file"
                if draft_ports_check "$file"; then break; fi
                jq --arg notice "$(t port_busy "$BUSY_PORT")" '._notice=$notice' "$file" > "$clean_file"
                cp -- "$clean_file" "$file";;
            10|130) exit "$editor_result";;
            20)
                select_major major "$(jq -r .major "$file")" 10 true install
                [[ $major != back ]] || continue
                if select_version "$major" '' true; then
                    jq --arg version "$SELECTED_VERSION" --arg image "$SELECTED_IMAGE" \
                        '.glpi_version=$version | .major=($version|split(".")[0]|tonumber) | .glpi_image=$image' "$file" > "$clean_file"
                    cp -- "$clean_file" "$file"
                fi;;
            *) return "$editor_result";;
        esac
    done
    ui_task setup_staging install_stage "$file" "$clean_file"
    installation_finish
}
# Validation, certificates and Compose checks take a few seconds after the form.
install_stage() {
    local file=$1 clean_file=$2
    jq 'del(._detected_host,._notice)' "$file" > "$clean_file"
    config_validate "$clean_file"
    draft_ports_check "$clean_file" || die port_busy "$BUSY_PORT"
    config_stage "$clean_file"
    draft_ports_check "$clean_file" || die port_busy "$BUSY_PORT"
    config_activate "$REVISION"
    journal_begin install
}
# MySQL and Caddy lookups are independent registry round trips: run both at once.
# Sets the caller's mysql_version/mysql_image/caddy_image (dynamic scope).
support_images_lookup() {
    local work mysql_pid caddy_pid
    work=$(mktemp -d "$STATE/cache/.support-XXXXXX")
    ui_status "$(t status_resolving 'mysql:8.4 · caddy:2')"
    ( trap - ERR EXIT; official_image_lookup mysql 8.4 > "$work/mysql" 2> "$work/mysql.err" || rm -f -- "$work/mysql" ) &
    mysql_pid=$!
    ( trap - ERR EXIT; official_image_lookup caddy 2 > "$work/caddy" 2> "$work/caddy.err" || rm -f -- "$work/caddy" ) &
    caddy_pid=$!
    wait "$mysql_pid" || true
    wait "$caddy_pid" || true
    registry_limit_check "$work/mysql.err" "$work/caddy.err"
    [[ -s $work/mysql ]] || { rm -rf -- "$work"; die image_missing mysql; }
    [[ -s $work/caddy ]] || { rm -rf -- "$work"; die image_missing caddy; }
    IFS=$'\t' read -r mysql_version mysql_image < "$work/mysql"
    IFS=$'\t' read -r _ caddy_image < "$work/caddy"
    rm -rf -- "$work"
}
draft_ports_check() {
    local input=$1 port
    while IFS= read -r port; do
        if ! port_free "$port"; then BUSY_PORT=$port; return 1; fi
    done < <(
        jq -r '.http_port, (if .tls!="off" then .https_port else empty end),
               (if .expose_db then 3306 else empty end)' "$input")
    return 0
}
check_updates() {
    ui_task ui_releases_loading release_fetch
    local newest current next_version
    newest=$(release_versions "$(cfg major)" | head -n 1); current=$(cfg glpi_version)
    [[ -n $newest ]] || die image_missing "$(cfg major)"
    ui_panel "$(t update_select_title)" "$(t update_latest "$current" "$newest")" "$(t update_select_help)"
    if version_gt "$newest" "$current"; then
        release_notice "$newest"
        image_resolve glpi/glpi "$newest" >/dev/null || say update_images_unavailable
    else say update_none; fi
    next_version=$(release_versions "$(( $(cfg major)+1 ))" | head -n 1)
    [[ -z $next_version ]] || say update_branch_available "$next_version"
}
write_target_config() {
    local target=$1 image=$2 output=$3
    jq --arg version "$target" --arg image "$image" \
        '.glpi_version=$version | .major=($version|split(".")[0]|tonumber) | .glpi_image=$image | .status="configured"' "$CONFIG" > "$output"
}
move_legacy_marketplace() {
    local folder=$1 source_major=$2
    if [[ $source_major == 10 && $(cfg major) != 10 ]]; then
        docker run --rm -i --network none --user 0 --mount "type=volume,src=$(volume_name glpi_data),dst=/data" \
            --entrypoint sh "$(cfg glpi_image)" -c 'mkdir -p /data/marketplace; tar -C /data/marketplace -xzf -; chown -R www-data:www-data /data/marketplace' < "$folder/marketplace.tar.gz"
    fi
}
rehearsal_cleanup() {
    local role name label complete=true directory
    dc down --remove-orphans >/dev/null 2>&1 || complete=false
    for role in glpi_data db_data plugins marketplace caddy_data caddy_config; do
        name=$(volume_name "$role")
        if ! label=$(docker volume inspect -f '{{index .Labels "org.glpidm.installation"}}' "$name" 2>/dev/null); then
            complete=false; continue
        fi
        if [[ $label != "$(cfg id)" ]] || ! docker volume rm "$name" >/dev/null; then complete=false; fi
    done
    # Local-driver bind volumes leave host files behind after volume removal.
    # Only erase the exact disposable data ID after all owned mounts are gone.
    if [[ $complete == true && $(cfg storage) == directory && $STATE =~ /rehearsals/[a-f0-9]{16}$ ]]; then
        directory="$STATE/data/$(cfg id)"
        if [[ ! -L $STATE && ! -L $STATE/data && ! -L $directory && -d $directory ]]; then
            rm -rf --one-file-system -- "$directory" || say cleanup_deferred "$STATE"
        fi
    fi
    return 0
}
rehearse() (
    # A subshell confines the temporary state/configuration to the rehearsal.
    set -Eeuo pipefail
    local folder=$1 target=$2 image=$3 mysql_version=${4:-} mysql_image=${5:-} source_major id temporary file
    source_major=$(jq -r .major "$folder/config.json")
    temporary="$STATE/rehearsals/$(openssl rand -hex 8)"
    STATE=$temporary
    unset GDM_BIND_STATE
    mkdir -p "$STATE/revisions" "$STATE/backups" "$STATE/cache"
    file="$STATE/target.json"; id=$(openssl rand -hex 8)
    jq --arg id "$id" --arg target "$target" --arg image "$image" --arg mv "$mysql_version" --arg mi "$mysql_image" \
        '.id=$id | .project=("gdm_"+$id) | .tls="off" | .expose_db=false | .glpi_version=$target |
         .major=($target|split(".")[0]|tonumber) | .glpi_image=$image | .status="configured" | .storage="directory" |
         if $mv!="" then .mysql_version=$mv | .mysql_image=$mi else . end' "$folder/config.json" > "$file"
    config_stage "$file"
    jq 'del(.services.glpi.ports) | .networks.backend.internal=true | .services.glpi.environment.GLPI_CRONTAB_ENABLED="0"' \
        "$REVISION/compose.json" > "$REVISION/isolated.json"
    mv "$REVISION/isolated.json" "$REVISION/compose.json"
    config_activate "$REVISION"
    trap rehearsal_cleanup EXIT
    restore_into_current "$folder"
    move_legacy_marketplace "$folder" "$source_major"
    oneoff_action requirements
    oneoff_action update --no-telemetry
    oneoff_action version --quiet
    oneoff_action schema --quiet
    say rehearsal_ok
)
update_glpi() {
    local kind=${1:-update} requested=${2:-} target image current file old source_major
    assert_running
    current=$(cfg glpi_version); source_major=$(cfg major)
    ui_task ui_releases_loading release_fetch
    if [[ $kind == update && -z $requested ]]; then
        select_update_target "$current" "$source_major"
        requested=$SELECTED_UPDATE
        [[ -n $requested ]] || return 0
        if [[ $requested == refresh ]]; then kind=refresh-image requested=''; fi
    fi
    if [[ $kind == update && -n $requested ]] && valid_version "$requested" && (( ${requested%%.*} > source_major )); then kind=migrate; fi
    if [[ $kind == refresh-image ]]; then
        target=$current; image=$(image_resolve glpi/glpi "$target") || die image_missing "$target"
        [[ $image != "$(cfg glpi_image)" ]] || { say same_image; return; }
        release_notice "$target"
    elif [[ $kind == migrate ]]; then
        if [[ -n $requested ]]; then
            target=$requested
            if ! valid_version "$target" || (( ${target%%.*} != source_major+1 )); then die update_boundary; fi
            select_version "${target%%.*}" "$target"
        else
            local major
            select_major major "$((source_major+1))" "$source_major" false migrate
            if [[ ! $major =~ ^[1-9][0-9]{1,2}$ ]] || (( major != source_major+1 )); then die update_boundary; fi
            select_version "$major"
        fi
        target=$SELECTED_VERSION; image=$SELECTED_IMAGE
        say migration_warning
        plugins_panel "${target%%.*}"
        confirm migration_review || die cancelled
    else
        target=${requested:-$(release_versions "$source_major" | head -n 1)}
        if ! valid_version "$target" || [[ ${target%%.*} != "$source_major" ]] || ! version_gt "$target" "$current"; then die update_boundary; fi
        select_version "$source_major" "$target"
        image=$SELECTED_IMAGE
    fi
    say update_current "$current" "$target"
    confirm update_confirm || die cancelled
    ui_run 1/3 update_step_backup backup_create true "$kind" "$target"
    printf '%s\n' "$LAST_BACKUP" > "$STATE/recovery-backup"
    backup_extract "$LAST_BACKUP"
    ui_panel "$(t backup_recovery_ready)" "$LAST_BACKUP" "$(t backup_recovery_help)"
    # Rehearse every application version change, including patch updates.
    ui_run 2/3 update_step_rehearsal rehearse "$EXTRACTED" "$target" "$image"
    [[ $kind != migrate ]] || typed_confirm "MIGRATE-$source_major-${target%%.*}"
    update_apply_guarded apply_glpi_update "$kind" "$target" "$image" "$source_major"
    ui_panel "✓ $(t updated "$target")" "$(t ready "$(installation_url)")" "$LAST_BACKUP" "$(t backup_recovery_help)"
}
apply_glpi_update() {
    local kind=$1 target=$2 image=$3 source_major=$4 file old
    file=$(mktemp "$STATE/.update.XXXXXX"); CLEANUP_PATHS+=("$file")
    write_target_config "$target" "$image" "$file"
    config_stage "$file"
    # The rehearsal already pulled it; never depend on the network once GLPI is down.
    ui_status "$(t status_pulling "${image%@*}")"
    docker image inspect "$image" >/dev/null 2>&1 || docker pull --quiet "$image"
    old=$(readlink -f "$STATE/current")
    journal_begin "$kind"
    printf '%s\n' "$old" > "$STATE/previous-revision"
    printf '%s\n' "$LAST_BACKUP" > "$STATE/recovery-backup"
    dc stop glpi
    [[ $(cfg tls) == off ]] || dc stop proxy
    config_activate "$REVISION"
    journal_phase migration
    move_legacy_marketplace "$EXTRACTED" "$source_major"
    oneoff_action requirements
    oneoff_action update --no-telemetry
    oneoff_action version --quiet
    oneoff_action schema --quiet
    dc up -d
    verify_services
    config_set_status ready
    journal_done
}
# Later releases plus the current version's digest (to detect a refreshed image).
update_choices_scan() {
    build_update_choices "$1" "$2"
    REFRESH_REF=$(image_resolve glpi/glpi "$1" 2>/dev/null) || REFRESH_REF=''
}
# Plugins registered in GLPI, read from its database before a branch change.
plugins_panel() {
    local target_major=$1 rows directory version state label
    local -a lines=()
    # Expand credentials inside the container, never in host command arguments.
    # shellcheck disable=SC2016
    rows=$(dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" exec mysql -u"$GDM_DB_USER" "$MYSQL_DATABASE" -Nse "SELECT directory, version, state FROM glpi_plugins ORDER BY state, directory"' 2>/dev/null) || rows=''
    while IFS=$'\t' read -r directory version state; do
        [[ -n $directory ]] || continue
        # GLPI plugin states: 1 activated, 4 not activated; others need attention.
        case $state in 1) label=$(t plugin_active);; 4) label=$(t plugin_inactive);; *) label=$(t plugin_other);; esac
        lines+=("${directory//[^A-Za-z0-9_.-]/}"$'\t'"${version//[^A-Za-z0-9_.+-]/} · $label")
    done <<< "$rows"
    if (( ${#lines[@]} == 0 )); then ui_panel "$(t plugins_title 0)" "$(t plugins_none)"
    else ui_panel "$(t plugins_title "${#lines[@]}")" "${lines[@]}" "$(t plugins_help "$target_major")"; fi
}
# The apply stage runs in a subshell: when it fails, the pre-update backup is
# offered at once instead of leaving stopped services and a manual recovery.
update_apply_guarded() {
    local rc
    set +e
    trap - ERR
    ( set -Eeuo pipefail; trap on_error ERR; ui_run 3/3 update_step_apply "$@" )
    rc=$?
    trap on_error ERR
    set -e
    (( rc != 0 )) || return 0
    if (( rc == 74 )); then GDM_STORAGE_FAILURE=true; exit 74; fi
    rollback_offer "$rc"
}
rollback_offer() {
    local rc=$1 action
    [[ -t 0 && -n ${LAST_BACKUP:-} && -f $LAST_BACKUP ]] || exit "$rc"
    ui_panel "$(t rollback_title)" "$(t rollback_body)" "$(t rollback_backup)"$'\t'"${LAST_BACKUP##*/}"
    choose action rollback_prompt restore restore "$(ui_opt warn "$(t rollback_restore)" "$(t opt_rollback_restore)")" \
        keep "$(ui_opt back "$(t rollback_keep)" "$(t opt_rollback_keep)")" || exit "$rc"
    [[ $action == restore ]] || exit "$rc"
    restore_backup "$LAST_BACKUP"
    exit 0
}
build_update_choices() {
    local current=$1 major=$2 version image resolved
    local -a candidates=()
    valid_version "$current" || die invalid version
    # Later releases of this and the next branch (numeric array comparison in jq).
    mapfile -t candidates < <(jq -r --argjson major "$major" --arg current "$current" '
        ($current|split(".")|map(tonumber)) as $installed |
        [.[]|.version | select((split(".")[0]|tonumber) as $branch | $branch==$major or $branch==$major+1) |
         select((split(".")|map(tonumber)) > $installed)] |
        sort_by(split(".")|map(tonumber)) | .[]' "$STATE/cache/releases.json")
    UPDATE_CANDIDATES=${#candidates[@]}
    : > "$UPDATE_CHOICES_FILE"
    (( UPDATE_CANDIDATES > 0 )) || return 0
    resolved=$(mktemp "$STATE/cache/.updates.XXXXXX"); CLEANUP_PATHS+=("$resolved")
    images_resolve glpi/glpi "$resolved" "${candidates[@]}"
    while IFS=$'\t' read -r version image; do
        printf '%s\t%s\t%s\n' "$version" "${version%%.*}" "$image"
    done < "$resolved" > "$UPDATE_CHOICES_FILE"
}
select_update_target() {
    local current=$1 major=$2 version branch image choice default='' UPDATE_CHOICES_FILE UPDATE_CANDIDATES=0 REFRESH_REF=''
    local -a choices=()
    SELECTED_UPDATE=''
    UPDATE_CHOICES_FILE=$(mktemp "$STATE/.updates.XXXXXX"); CLEANUP_PATHS+=("$UPDATE_CHOICES_FILE")
    ui_run 0 update_loading update_choices_scan "$current" "$major"
    # Newest patch of the installed branch is the recommended choice.
    while IFS=$'\t' read -r version branch image; do
        [[ $branch != "$major" ]] || default=$version
    done < "$UPDATE_CHOICES_FILE"
    while IFS=$'\t' read -r version branch image; do
        if [[ $version == "$default" ]]; then
            choices+=("$version" "$(ui_opt primary "$(t update_label_patch "GLPI $version" "$branch") · $(t opt_recommended)" "$(t opt_update_patch "$branch")")")
        elif [[ $branch == "$major" ]]; then
            choices+=("$version" "$(ui_opt ok "$(t update_label_patch "GLPI $version" "$branch")" "$(t opt_update_patch "$branch")")")
        else
            choices+=("$version" "$(ui_opt warn "$(t update_label_major "GLPI $version" "$major" "$branch")" "$(t opt_update_major "$major" "$branch")")")
        fi
    done < "$UPDATE_CHOICES_FILE"
    # Same version, newer image digest (base-system fixes): formerly "Refresh image".
    if [[ -n $REFRESH_REF && -n ${CONFIG:-} && -r $CONFIG && $REFRESH_REF != "$(cfg glpi_image)" ]]; then
        choices+=(refresh "$(ui_opt ok "$(t update_label_refresh "GLPI $current")" "$(t opt_update_refresh)")")
    fi
    if (( ${#choices[@]} == 0 )); then
        if (( UPDATE_CANDIDATES > 0 )); then say update_images_unavailable; else say update_none; fi
        return 0
    fi
    if [[ -z $default ]]; then say update_no_patches; default=${choices[0]}; fi
    choices+=(back "$(ui_opt back "$(t ui_back_menu)")")
    ui_panel "$(t update_select_title)" "$(t opt_installed)"$'\t'"GLPI $current" "$(t update_select_help)"
    choose choice update_select_prompt "$default" "${choices[@]}" || exit 10
    [[ $choice != back ]] || exit 10
    SELECTED_UPDATE=$choice
}
update_database() {
    local target image mysql_lookup
    assert_running
    mysql_lookup=$(mktemp "$STATE/.mysql-lookup.XXXXXX"); CLEANUP_PATHS+=("$mysql_lookup")
    ui_task setup_loading_images mysql_target_lookup "$mysql_lookup"
    IFS=$'\t' read -r target image < "$mysql_lookup" || die image_missing mysql
    version_gt "$target" "$(cfg mysql_version)" || { say update_none; return; }
    say db_update_warning
    ui_panel "$(t ui_db_update)" "$(t db_update_versions "$(cfg mysql_version)" "$target")"
    confirm db_update_confirm || die cancelled
    ui_run 1/3 update_step_backup backup_create true db-update "$target"
    backup_extract "$LAST_BACKUP"
    ui_panel "$(t backup_recovery_ready)" "$LAST_BACKUP" "$(t backup_recovery_help)"
    ui_run 2/3 update_step_rehearsal rehearse "$EXTRACTED" "$(cfg glpi_version)" "$(cfg glpi_image)" "$target" "$image"
    typed_confirm UPDATE-MYSQL
    update_apply_guarded apply_database_update "$target" "$image"
    ui_panel "✓ $(t db_updated "$target")" "$(t ready "$(installation_url)")" "$LAST_BACKUP" "$(t backup_recovery_help)"
}
mysql_target_lookup() { official_image_lookup mysql 8.4 > "$1" || die image_missing mysql; }
apply_database_update() {
    local target=$1 image=$2 file
    file=$(mktemp "$STATE/.mysql.XXXXXX"); CLEANUP_PATHS+=("$file")
    jq --arg version "$target" --arg image "$image" '.mysql_version=$version | .mysql_image=$image | .status="configured"' "$CONFIG" > "$file"
    config_stage "$file"
    docker image inspect "$image" >/dev/null 2>&1 || docker pull --quiet "$image"
    journal_begin db-update
    printf '%s\n' "$LAST_BACKUP" > "$STATE/recovery-backup"
    dc stop
    config_activate "$REVISION"
    dc up -d
    verify_services
    config_set_status ready
    journal_done
}
apply_settings() {
    local file=$1 old confirmed=${2:-false}
    config_stage "$file"
    [[ $confirmed == true ]] || confirm config_confirm || die cancelled
    old=$(readlink -f "$STATE/current")
    journal_begin configure
    dc stop
    config_activate "$REVISION"
    if dc up -d --remove-orphans && verify_services; then
        journal_done
    else
        dc stop || true
        config_activate "$old"
        dc up -d --remove-orphans
        verify_services
        journal_done
        say config_restored
        return 1
    fi
}
db_exposure_prompt() {
    local exposure_choice current=no state
    [[ $(cfg expose_db) != true ]] || current=yes
    if [[ $current == yes ]]; then state=$(t ui_db_public); else state=$(t ui_db_private); fi
    ui_panel "$(t ui_db_access_title)" "$(t ui_db_current)"$'\t'"$state" "$(t ui_db_access_body)" "$(t ui_db_access_later)"
    local yes_label no_label
    yes_label=$(t ui_db_expose_yes); no_label=$(t ui_db_expose_no)
    if [[ $current == yes ]]; then yes_label+=" $(t opt_current)"; else no_label+=" $(t opt_current)"; fi
    choose exposure_choice expose_prompt "$current" \
        no "$(ui_opt ok "$no_label" "$(t opt_db_internal)")" yes "$(ui_opt warn "$yes_label" "$(t opt_db_public)")" || exit 10
    if [[ $exposure_choice == "$current" ]]; then say ui_db_unchanged; exit 10; fi
    [[ $exposure_choice != yes ]] || say firewall_docker 3306
    [[ $exposure_choice == yes ]]
}
settings_command() {
    local command=$1 file exposed=false editor_result cleaned
    file=$(mktemp "$STATE/.settings.XXXXXX"); CLEANUP_PATHS+=("$file")
    if [[ $command == address ]]; then
        jq --arg host "$(server_primary_address)" '._access_only=true | ._detected_host=$host |
          ._active_ports=[.http_port,.https_port,(if .expose_db then 3306 else empty end)] |
          if .hostname=="localhost" then .hostname=$host else . end' "$CONFIG" > "$file"
        if python3 "$GDM_ROOT/tools/setup.py" "$file" "$LANGUAGE"; then editor_result=0; else editor_result=$?; fi
        [[ $editor_result == 0 ]] || exit "$editor_result"
        cleaned=$(mktemp "$STATE/.access.XXXXXX"); CLEANUP_PATHS+=("$cleaned")
        jq 'del(._access_only,._active_ports,._detected_host)' "$file" > "$cleaned"
        ui_run 0 settings_step_apply apply_settings "$cleaned" true
        ui_panel "$(t ui_service_ready)" "$(t ready "$(installation_url)")"
        return
    elif [[ $command == https ]]; then tls_wizard "$CONFIG" "$file"
    else
        if db_exposure_prompt; then exposed=true; fi
        jq --argjson exposed "$exposed" '.expose_db=$exposed' "$CONFIG" > "$file"
    fi
    confirm config_confirm || exit 10
    ui_run 0 settings_step_apply apply_settings "$file" true
    ui_panel "$(t ui_service_ready)" "$(t ready "$(installation_url)")"
}
diagnose_section() { printf '\n' >&2; ui_log info "$1"; }
diagnose() {
    say diagnose_note
    os_detect /etc/os-release
    diagnose_section "$OS_NAME / $ARCH"
    docker version --format 'Docker client {{.Client.Version}} / server {{.Server.Version}}'
    docker compose version
    diagnose_section "df -h $STATE"
    df -h "$STATE"
    if [[ -L $STATE/current ]]; then
        config_load
        diagnose_section "$CONFIG"
        jq '{format,project,status,major,glpi_version,mysql_version,http_port,https_port,expose_db,tls,hostname}' "$CONFIG"
        diagnose_section "docker compose ps"
        dc ps --all
        if [[ -f $STATE/current/tls/fullchain.pem ]]; then
            diagnose_section TLS
            openssl x509 -in "$STATE/current/tls/fullchain.pem" -noout -subject -issuer -dates
        fi
    fi
    if [[ -f $STATE/maintenance-last.json ]]; then
        diagnose_section "$STATE/maintenance-last.json · $(maintenance_summary)"
        jq . "$STATE/maintenance-last.json"
    fi
    if [[ -f $STATE/operation.json ]]; then
        diagnose_section "$STATE/operation.json"
        jq '{action,phase,started_at}' "$STATE/operation.json"
    fi
    return 0
}
dispatch() {
    local command=$1 argument=${2:-} tmp backup_title
    if [[ -f $STATE/operation.json ]]; then
        case $command in status|logs|diagnose|recover|restore|install|backups|maintenance|uninstall|self-update) ;; *) die recovery_notice "$STATE/operation.json";; esac
    fi
    case $command in
        install) install_wizard "$argument";;
        restore) restore_backup "$argument";;
        diagnose) diagnose;;
        maintenance) maintenance_command;;
        uninstall) uninstall_command;;
        self-update)
            manager_self_update
            if [[ -f $STATE/cache/manager-update.pending ]]; then
                # The menu shell owns the lock and performs the handover (75).
                if [[ ${GDM_IN_MENU:-false} == true ]]; then exit 75; else manager_handover; fi
            fi;;
        backups) if [[ -t 0 && -t 1 ]]; then backup_manage; else backup_list; fi;;
        *)
            config_load
            case $command in
                status) service_status; [[ ! -f $STATE/operation.json ]] || say recovery_notice "$STATE/operation.json";;
                start) service_start;;
                stop)
                    confirm stop_confirm || return 0
                    ui_run 0 service_step_stop dc stop
                    ui_panel "✓ $(t service_stopped_done)";;
                logs) say diagnose_note; service_logs;;
                check-updates) check_updates;;
                update|migrate|refresh-image) update_glpi "$command" "$argument";;
                db-update) update_database;;
                backup|transfer)
                    if [[ $command == backup && ${GDM_IN_MENU:-false} == true ]]; then
                        choose command backup_kind_prompt backup \
                            backup "$(ui_opt primary "$(t backup_kind_manual)" "$(t opt_backup_manual)")" \
                            transfer "$(ui_opt warn "$(t backup_kind_transfer)" "$(t opt_backup_transfer)")" \
                            back "$(ui_opt back "$(t ui_back_menu)")" || exit 10
                        [[ $command != back ]] || exit 10
                    fi
                    if [[ $command == transfer ]]; then confirm transfer_confirm || return 0; fi
                    journal_begin "$command"
                    if [[ $command == transfer ]]; then ui_run 0 update_step_backup backup_create false transfer
                    else ui_run 0 update_step_backup backup_create; fi
                    journal_done
                    backup_title=backup_manual_done
                    [[ $command != transfer ]] || backup_title=backup_transfer_done
                    ui_panel "$(t "$backup_title")" "$LAST_BACKUP" "$(t backup_manual_help)"
                    [[ $command != transfer ]] || say transfer "$LAST_BACKUP";;
                https|db-exposure|address) settings_command "$command";;
                certificates) certificates_menu;;
                cleanup) cleanup_menu;;
                schedule) schedule_menu;;
                credentials)
                    say credentials_note
                    if confirm credentials_warning; then
                        # Plain stdout lines: never truncated by a card and never kept
                        # in UI_CONTEXT, so the values can be copied exactly.
                        ui_log info "$(t menu_credentials)"
                        jq -r '["GLPI_DB_NAME",.db_name],["GLPI_DB_USER",.db_user],["GLPI_DB_PASSWORD",.db_password],
                               ["MYSQL_ROOT_PASSWORD",.root_password] | "      \(.[0])\t\(.[1])"' "$CONFIG"
                    fi;;
                language)
                    choose_language || die cancelled
                    tmp=$(mktemp "$STATE/.language.XXXXXX"); CLEANUP_PATHS+=("$tmp")
                    jq --arg language "$LANGUAGE" '.language=$language' "$CONFIG" > "$tmp"
                    mv -- "$tmp" "$(readlink -f "$CONFIG")"; cfg_cache; tr_load; say language_saved;;
                recover)
                    say recover_prompt; typed_confirm RESUME
                    ui_run 0 ui_service_starting recover_services; say recover_done;;
                *) die unknown_command "$command";;
            esac;;
    esac
}
# Read by tools/main_menu.py: certificate days and maintenance state.
dashboard_environment() {
    local CERT_DAYS='' CERT_END_DATE=''
    local folder count=0
    GDM_DASH_CERT_DAYS='' GDM_DASH_MAINTENANCE=$(maintenance_summary)
    # Replaced installations still on disk (normally none, at most one).
    for folder in "$STATE"/data/*/; do
        [[ -d $folder && ${folder%/} != "$STATE/data/$(cfg id)" ]] && count=$((count+1))
    done
    GDM_DASH_PREVIOUS=$count
    export GDM_DASH_PREVIOUS
    if [[ $(cfg tls) == self-signed || $(cfg tls) == custom ]] && cert_days "$STATE/current/tls/fullchain.pem"; then
        GDM_DASH_CERT_DAYS=$CERT_DAYS
        (( CERT_DAYS >= 30 )) || say cert_expiring "$CERT_DAYS"
    fi
    export GDM_DASH_CERT_DAYS GDM_DASH_MAINTENANCE
}
menu() {
    local command menu_result action_file GDM_IN_MENU=true
    while :; do
        # Start-up checks and earlier actions must not reappear inside the next action.
        UI_NOTICES=() UI_CONTEXT=()
        if [[ ! -L $STATE/current ]]; then
            ui_panel "$(t ui_first_title)" "$(t ui_first_body)"
            choose command first_action install install "$(ui_opt primary "$(t ui_install)" "$(t opt_install)")" \
                restore "$(ui_opt ok "$(t ui_restore_backup)" "$(t opt_restore)")" quit "$(ui_opt back "$(t ui_exit)")" || return 0
        else
            config_load
            if [[ $(cfg status) != ready || -f $STATE/operation.json ]]; then
                ui_panel "$(t ui_pending_title)" "$(t ui_pending_body)"
                choose command ui_menu_prompt install install "$(ui_opt primary "$(t ui_resume_install)" "$(t opt_resume)")" \
                    recover "$(ui_opt warn "$(t ui_recover)" "$(t opt_recover)")" \
                    restore "$(ui_opt ok "$(t ui_restore_backup)" "$(t opt_restore)")" \
                    logs "$(ui_opt '' "$(t ui_logs)" "$(t desc_logs)")" diagnose "$(ui_opt '' "$(t ui_diagnose)" "$(t desc_diagnose)")" \
                    uninstall "$(ui_opt danger "$(t menu_uninstall)" "$(t desc_uninstall)")" quit "$(ui_opt back "$(t ui_exit)")" || return 0
            else
                service_snapshot
                dashboard_environment
                action_file=$(mktemp "$STATE/.action.XXXXXX"); CLEANUP_PATHS+=("$action_file")
                if python3 "$GDM_ROOT/tools/main_menu.py" "$CONFIG" "$SERVICE_DATA" "$LANGUAGE" "$action_file"; then :
                else menu_result=$?; [[ $menu_result != 130 ]] || ui_interrupted; return 0; fi
                IFS= read -r command < "$action_file"
            fi
        fi
        [[ $command != quit ]] || return 0
        # Never put dispatch in an if/|| condition: Bash would disable errexit
        # throughout the called functions, allowing a failed migration to continue.
        set +e
        trap - ERR
        (
            set -Eeuo pipefail
            trap on_error ERR
            trap cleanup EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM
            dispatch "$command"
        )
        menu_result=$?
        trap on_error ERR
        set -e
        [[ $menu_result != 130 ]] || return 0
        [[ $menu_result != 10 ]] || continue
        [[ $menu_result != 75 ]] || manager_handover
        if [[ $command == uninstall && $menu_result == 0 ]]; then return 0; fi
        if [[ $menu_result == 74 ]]; then GDM_STORAGE_FAILURE=true; exit 74; fi
        if [[ $command == language && $menu_result == 0 ]]; then
            LANGUAGE_OVERRIDE=''
            config_load
        fi
        if [[ ( $command == status || $command == logs || $command == backups ) && $menu_result == 0 ]]; then continue; fi
        ui_pause
    done
}
main() {
    while (( $# )); do
        # LANGUAGE_OVERRIDE is read by config_load in config.sh.
        # shellcheck disable=SC2034
        case $1 in
            --lang) [[ $# -ge 2 ]] || exit 2; LANGUAGE=$2; LANGUAGE_OVERRIDE=$2; shift 2;;
            --state-dir) [[ $# -ge 2 ]] || exit 2; STATE=$2; shift 2;;
            --help|-h) set -- help; break;;
            --version) set -- version; break;;
            --*) printf 'Unknown option: %s\n' "$1" >&2; exit 2;;
            *) break;;
        esac
    done
    CERT_ROOT=${GDM_CERT_DIR:-$STATE/certs}
    if [[ -z $LANGUAGE_OVERRIDE && -r $STATE/current/config.json ]] && command -v jq >/dev/null; then
        LANGUAGE=$(jq -r '.language // "en"' "$STATE/current/config.json" 2>/dev/null) || LANGUAGE=en
    fi
    tr_load
    case ${1:-menu} in help) ui_help; return;; version) printf '%s\n' "$GDM_VERSION"; return;; esac
    trap on_error ERR
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if (( $# == 0 )) && [[ -z $LANGUAGE_OVERRIDE && -t 0 && ! -L $STATE/current ]]; then
        choose_language || return 0
    fi
    # Used by require_admin in system.sh to display the exact resume command.
    # shellcheck disable=SC2034
    GDM_COMMAND_ARGS=("$@")
    # The daily job waits for an open interactive session instead of failing.
    [[ ${1:-} != maintenance ]] || GDM_LOCK_WAIT=${GDM_LOCK_WAIT:-900}
    ui_welcome
    ui_log info "$(t ui_checking)"
    require_runtime
    init_state
    layout_install_code
    logs_rotate
    say ui_prerequisites_done
    if (( $# == 0 )); then menu; else dispatch "$@"; fi
}

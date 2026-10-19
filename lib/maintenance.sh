#!/usr/bin/env bash
# Host-side maintenance: scheduled backups, log rotation, certificates,
# uninstallation and manager self-update. GLPI's own settings stay in GLPI.
# Requires core.sh to be sourced first: it defines the shared globals STATE,
# GDM_ROOT, GDM_VERSION, LANGUAGE and GDM_LOCK_FD (set by init_state), and
# config.sh defines CONFIG. SC2153 is disabled because ShellCheck cannot see
# those cross-module assignments and suggests the unrelated local "state".
# shellcheck disable=SC2016,SC2034,SC2153
AUTO_BACKUP_KEEP=5
LOG_RETENTION_DAYS=30
GDM_REPOSITORY=${GDM_REPOSITORY:-solqubit/glpi-docker-manager}

# ---------------------------------------------------------------- schedule
maintenance_settings() {
    local file="$STATE/maintenance.json"
    MAINT_BACKUPS=false MAINT_HOUR=3
    [[ -r $file ]] || return 0
    MAINT_BACKUPS=$(jq -r 'if .backups==true then "true" else "false" end' "$file" 2>/dev/null) || MAINT_BACKUPS=false
    MAINT_HOUR=$(jq -r '(.hour // 3)|tostring' "$file" 2>/dev/null) || MAINT_HOUR=3
    [[ $MAINT_HOUR =~ ^([01]?[0-9]|2[0-3])$ ]] || MAINT_HOUR=3
    MAINT_HOUR=$((10#$MAINT_HOUR))
}
maintenance_save() {
    local tmp
    tmp=$(mktemp "$STATE/.maintenance.XXXXXX")
    jq -n --argjson backups "$1" --argjson hour "$2" --argjson keep "$AUTO_BACKUP_KEEP" \
        '{format:1,backups:$backups,hour:$hour,keep:$keep}' > "$tmp"
    mv -- "$tmp" "$STATE/maintenance.json"
}
# One unit per installation root, so several roots never share a timer.
maintenance_unit() { printf 'gdm-maintenance-%s\n' "$(printf '%s' "$STATE" | sha256sum | cut -c1-8)"; }
scheduler_kind() {
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then printf 'systemd\n'
    elif [[ -d /etc/cron.d ]]; then printf 'cron\n'
    else printf 'none\n'; fi
}
scheduler_installed() {
    local unit
    unit=$(maintenance_unit)
    [[ -f /etc/systemd/system/$unit.timer || -f /etc/cron.d/$unit ]]
}
# Daily job: log rotation, certificate renewal and (if enabled) a backup.
scheduler_install() {
    local unit entry kind
    maintenance_settings
    unit=$(maintenance_unit)
    entry="$STATE/start.sh"
    # Disposable test roots (GDM_INTEGRATION) and GDM_SCHEDULER=off never touch the host scheduler.
    [[ -z ${GDM_INTEGRATION:-} && ${GDM_SCHEDULER:-auto} != off ]] || return 1
    [[ -f $entry && $STATE != *[\"\\%]* ]] || return 1
    kind=$(scheduler_kind)
    case $kind in
        systemd)
            printf '[Unit]\nDescription=GLPI Docker Manager maintenance (%s)\nAfter=docker.service\nWants=docker.service\n\n[Service]\nType=oneshot\nExecStart=/usr/bin/env bash "%s" maintenance\n' \
                "$STATE" "$entry" > "/etc/systemd/system/$unit.service"
            printf '[Unit]\nDescription=Daily GLPI Docker Manager maintenance (%s)\n\n[Timer]\nOnCalendar=*-*-* %02d:00:00\nRandomizedDelaySec=10min\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' \
                "$STATE" "$MAINT_HOUR" > "/etc/systemd/system/$unit.timer"
            chmod 644 "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"
            systemctl daemon-reload
            systemctl enable --now "$unit.timer" >/dev/null 2>&1;;
        cron)
            printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n0 %d * * * root bash %q maintenance >/dev/null 2>&1\n' \
                "$MAINT_HOUR" "$entry" > "/etc/cron.d/$unit"
            chmod 644 "/etc/cron.d/$unit";;
        *) return 1;;
    esac
}
scheduler_remove() {
    local unit
    unit=$(maintenance_unit)
    if [[ -f /etc/systemd/system/$unit.timer ]]; then
        systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
        rm -f -- "/etc/systemd/system/$unit.timer" "/etc/systemd/system/$unit.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f -- "/etc/cron.d/$unit"
}
# Short state for the dashboard: off, on:HH or missing (no timer installed).
maintenance_summary() {
    maintenance_settings
    if ! scheduler_installed; then printf 'missing\n'
    elif [[ $MAINT_BACKUPS == true ]]; then printf 'on:%02d\n' "$MAINT_HOUR"
    else printf 'off\n'; fi
}
maintenance_record() {
    local tmp
    tmp=$(mktemp "$STATE/.maintenance-last.XXXXXX")
    jq -n --arg time "$(date -u +%FT%TZ)" --arg status "$1" --arg backup "${2:-}" \
        '{time:$time,status:$status,backup:$backup}' > "$tmp"
    mv -- "$tmp" "$STATE/maintenance-last.json"
}
# The scheduled job. It never prompts; its output goes to a dated log.
maintenance_run() {
    local backup=''
    MAINT_STATUS=ok
    logs_rotate
    [[ -L $STATE/current ]] || return 0
    config_load
    if [[ -f $STATE/operation.json || $(cfg status) != ready ]]; then
        say maint_skipped; maintenance_record skipped; return 0
    fi
    maintenance_record running
    # Not in an if/|| context: errexit must stay active while services restart.
    tls_auto_renew
    maintenance_settings
    if [[ $MAINT_BACKUPS == true ]]; then
        if [[ -n $(dc ps --status running --quiet glpi) && -n $(dc ps --status running --quiet db) ]]; then
            journal_begin backup
            ui_run 0 update_step_backup backup_create true auto
            journal_done
            backup_prune_auto
            backup=$LAST_BACKUP
        else say maint_services_stopped; MAINT_STATUS=warning; fi
    fi
    maintenance_record "$MAINT_STATUS" "$backup"
    say maint_done
}
maintenance_command() {
    local log
    mkdir -p "$STATE/logs"
    if [[ -t 0 && -t 2 ]]; then maintenance_run; return; fi
    log="$STATE/logs/maintenance-$(date -u +%Y%m%d).log"
    printf '\n=== %s ===\n' "$(date -u +%FT%TZ)" >> "$log"
    maintenance_run >> "$log" 2>&1
}
# Interactive settings: automatic backups on/off, time, run now.
schedule_menu() {
    local action hour state scheduler choice
    local -a hours=()
    maintenance_settings
    state=$(t maint_off); [[ $MAINT_BACKUPS != true ]] || state=$(t maint_on)
    if scheduler_installed; then scheduler=$(t maint_scheduler_on "$(scheduler_kind)"); else scheduler=$(t maint_scheduler_missing); fi
    ui_panel "$(t maint_title)" \
        "$(t maint_backups)"$'\t'"$state" "$(t maint_hour)"$'\t'"$(printf '%02d:00' "$MAINT_HOUR")" \
        "$(t maint_keep)"$'\t'"$AUTO_BACKUP_KEEP" "$(t maint_scheduler)"$'\t'"$scheduler" "$(t maint_body "$AUTO_BACKUP_KEEP")"
    if [[ $MAINT_BACKUPS == true ]]; then choice=$(t maint_disable); else choice=$(t maint_enable); fi
    choose action maint_prompt toggle toggle "$choice" hour "$(t maint_change_hour)" \
        run "$(t maint_run_now)" back "$(t ui_back_menu)" || exit 10
    case $action in
        toggle)
            if [[ $MAINT_BACKUPS == true ]]; then maintenance_save false "$MAINT_HOUR"; else maintenance_save true "$MAINT_HOUR"; fi;;
        hour)
            for hour in {0..23}; do hours+=("$hour" "$(printf '%02d:00' "$hour")"); done
            choose hour maint_hour_prompt "$MAINT_HOUR" "${hours[@]}" || exit 10
            maintenance_save "$MAINT_BACKUPS" "$hour";;
        run) maintenance_run; return;;
        *) exit 10;;
    esac
    scheduler_install || true
    maintenance_settings
    state=$(t maint_off); [[ $MAINT_BACKUPS != true ]] || state=$(t maint_on)
    ui_panel "$(t maint_saved)" "$(t maint_backups)"$'\t'"$state" "$(t maint_hour)"$'\t'"$(printf '%02d:00' "$MAINT_HOUR")"
}

# ---------------------------------------------------------------- logs
# Private stage/maintenance logs and the operation history never grow unbounded.
logs_rotate() {
    local folder="$STATE/logs" file update
    if [[ -d $folder && ! -L $folder ]]; then
        find "$folder" -maxdepth 1 -type f \( -name 'install-*.log' -o -name 'install-*.status' -o -name 'maintenance-*.log' \) \
            -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
        find "$folder" -maxdepth 1 -type f -name 'install-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -rn |
            tail -n +201 | cut -d' ' -f2- | while IFS= read -r file; do rm -f -- "$file"; done
    fi
    if [[ -f $STATE/history.jsonl ]] && (( $(wc -l < "$STATE/history.jsonl") > 1000 )); then
        file=$(mktemp "$STATE/.history.XXXXXX")
        tail -n 1000 "$STATE/history.jsonl" > "$file" && mv -- "$file" "$STATE/history.jsonl"
    fi
    # Downloads from previous self-updates, except the one running now.
    for update in "$STATE"/cache/manager-update-*; do
        [[ -d $update && ! -L $update && $GDM_ROOT != "$update"* ]] || continue
        rm -rf --one-file-system -- "$update" 2>/dev/null || true
    done
}
backup_prune_auto() {
    local file
    find "$STATE/backups" -maxdepth 1 -type f -name 'glpi-*-auto-*.tar.gz' -printf '%T@ %p\n' | sort -rn |
        tail -n +"$((AUTO_BACKUP_KEEP+1))" | cut -d' ' -f2- | while IFS= read -r file; do
            python3 "$GDM_ROOT/tools/backup_ops.py" delete "$STATE" "$file" || say backups_prune_skipped "$file"
        done
}

# ---------------------------------------------------------------- certificates
# Sets CERT_DAYS (negative once expired) and CERT_END_DATE for a PEM file.
cert_days() {
    local end now
    CERT_DAYS='' CERT_END_DATE=''
    end=$(openssl x509 -in "$1" -noout -enddate 2>/dev/null) || return 1
    end=$(date -u -d "${end#notAfter=}" +%s 2>/dev/null) || return 1
    printf -v now '%(%s)T' -1
    CERT_END_DATE=$(date -u -d "@$end" +%F)
    CERT_DAYS=$(( (end-now)/86400 ))
}
# Let's Encrypt certificates live in Caddy's volume; read the served one.
cert_served_file() {
    timeout 8 openssl s_client -connect "127.0.0.1:$(cfg https_port)" -servername "$(cfg hostname)" </dev/null 2>/dev/null |
        openssl x509 > "$1" 2>/dev/null
}
# Sets CERT_DAYS/CERT_END_DATE for the active installation's certificate.
tls_days() {
    local file
    case $(cfg tls) in
        off) return 1;;
        acme)
            file=$(mktemp "$STATE/.served.XXXXXX"); CLEANUP_PATHS+=("$file")
            cert_served_file "$file" || return 1
            cert_days "$file";;
        *) cert_days "$STATE/current/tls/fullchain.pem";;
    esac
}
tls_days_lookup() { tls_days || true; }
# New revision with the same settings; tls_prepare copies (or regenerates) PEMs.
tls_reapply() {
    local file
    file=$(mktemp "$STATE/.tls.XXXXXX"); CLEANUP_PATHS+=("$file")
    cp -- "$CONFIG" "$file"
    apply_settings "$file" true
}
tls_force_renew() { GDM_TLS_FORCE_RENEW=1 tls_reapply; }
# Daily: self-signed certificates are renewed 30 days before expiry; imported
# and Let's Encrypt certificates produce warnings (Caddy renews the latter).
tls_auto_renew() {
    local mode
    mode=$(cfg tls)
    [[ $mode != off ]] || return 0
    tls_days || return 0
    (( CERT_DAYS < 30 )) || return 0
    case $mode in
        self-signed) say cert_auto_renewing "$CERT_DAYS"; tls_force_renew;;
        custom) say cert_custom_expiring "$CERT_DAYS"; MAINT_STATUS=warning;;
        acme) say cert_acme_expiring "$CERT_DAYS"; dc restart proxy; MAINT_STATUS=warning;;
    esac
}
certificates_menu() {
    local mode expiry action help CERT_DAYS='' CERT_END_DATE=''
    mode=$(cfg tls)
    if [[ $mode == off ]]; then
        ui_panel "$(t cert_title)" "$(t cert_off)"
        choose action cert_prompt https https "$(t cert_enable_https)" back "$(t ui_back_menu)" || exit 10
        [[ $action == https ]] || exit 10
        settings_command https
        return
    fi
    ui_task cert_checking tls_days_lookup
    if [[ -z $CERT_DAYS ]]; then expiry=$(t cert_unknown)
    elif (( CERT_DAYS < 0 )); then expiry=$(t cert_expired "$((-CERT_DAYS))" "$CERT_END_DATE")
    else expiry=$(t cert_days "$CERT_DAYS" "$CERT_END_DATE"); fi
    [[ -z $CERT_DAYS ]] || (( CERT_DAYS >= 30 )) || say cert_expiring "$CERT_DAYS"
    if [[ $mode == custom ]]; then help=$(t cert_help_custom "$(cfg cert_dir)/custom/fullchain.pem" "$(cfg cert_dir)/custom/privkey.pem")
    else help=$(t "cert_help_$mode"); fi
    ui_panel "$(t cert_title)" "$(t cert_mode)"$'\t'"$(t "ui_tls_$mode")" "$(t ui_host)"$'\t'"$(cfg hostname)" \
        "$(t cert_expiry)"$'\t'"$expiry" "$help"
    case $mode in
        self-signed) choose action cert_prompt renew renew "$(t cert_renew_now)" back "$(t ui_back_menu)" || exit 10;;
        custom) choose action cert_prompt reload reload "$(t cert_reload)" back "$(t ui_back_menu)" || exit 10;;
        acme) choose action cert_prompt restart restart "$(t cert_restart_proxy)" back "$(t ui_back_menu)" || exit 10;;
    esac
    case $action in
        renew) ui_run 0 cert_step_apply tls_force_renew;;
        reload) ui_run 0 cert_step_apply tls_reapply;;
        restart) ui_run 0 cert_step_restart dc restart proxy;;
        *) exit 10;;
    esac
    ui_panel "$(t cert_applied)" "$(t ready "$(installation_url)")"
}

# ---------------------------------------------------------------- uninstall
# Every installation ID ever used under this root (restores assign new IDs).
installation_ids() {
    local file
    for file in "$STATE"/revisions/*/config.json; do
        [[ -f $file ]] && jq -r '.id // empty' "$file" 2>/dev/null
    done | grep -E '^[a-f0-9]{16}$' | sort -u
}
uninstall_services() {
    local id role name label container
    while IFS= read -r id; do
        ui_status "gdm_$id"
        docker compose --project-name "gdm_$id" down --remove-orphans >/dev/null 2>&1 || true
        while IFS= read -r container; do
            [[ -z $container ]] || docker rm -f "$container" >/dev/null 2>&1 || true
        done < <(docker ps -aq --filter "label=com.docker.compose.project=gdm_$id")
        for role in glpi_data db_data plugins marketplace caddy_data caddy_config; do
            name="gdm_${id}_$role"
            label=$(docker volume inspect -f '{{index .Labels "org.glpidm.installation"}}' "$name" 2>/dev/null) || continue
            # Only volumes this manager labelled for exactly this installation.
            if [[ $label == "$id" ]]; then docker volume rm "$name" >/dev/null; else say foreign_resource "$name"; fi
        done
    done < <(installation_ids)
}
uninstall_data() {
    local scope=$1 path name
    [[ $STATE == /* && $STATE != / && ! -L $STATE && -f $STATE/manager.lock ]] || die bad_path
    for path in "$STATE"/* "$STATE"/.[!.]*; do
        [[ -e $path || -L $path ]] || continue
        name=${path##*/}
        case $name in
            manager|manager-releases|start.sh|.gdm-entrypoint|manager.lock) continue;;
            backups|certs) [[ $scope == all ]] || continue;;
        esac
        ui_status "$name"
        rm -rf --one-file-system -- "$path"
    done
}
uninstall_command() {
    local scope
    [[ -t 0 ]] || die interactive_required
    ui_panel "$(t uninstall_title)" "$(t uninstall_body "$STATE")" "$(t uninstall_images)"
    choose scope uninstall_prompt cancel keep "$(t uninstall_keep)" all "$(t uninstall_all)" cancel "$(t ui_back_menu)" || exit 10
    [[ $scope != cancel ]] || exit 10
    typed_confirm UNINSTALL
    ui_run 1/3 uninstall_step_services uninstall_services
    ui_run 2/3 uninstall_step_data uninstall_data "$scope"
    ui_run 3/3 uninstall_step_scheduler scheduler_remove
    if [[ $scope == all ]]; then
        # The running code is already loaded; remove it last and leave.
        rm -rf --one-file-system -- "$STATE/manager-releases" "$STATE/manager" "$STATE/start.sh" "$STATE/.gdm-entrypoint"
        ui_panel "$(t uninstall_done)" "$(t uninstall_all_done "$STATE")" "$(t uninstall_images)"
        rm -rf --one-file-system -- "$STATE/logs"; rm -f -- "$STATE/manager.lock"
        rmdir -- "$STATE" 2>/dev/null || true
        exit 0
    fi
    ui_panel "$(t uninstall_done)" "$(t uninstall_kept "$STATE/backups")" "$(t uninstall_images)"
    exit 0
}

# ---------------------------------------------------------------- self-update
manager_latest_release() {
    local data tag
    data=$(http_get "https://api.github.com/repos/$GDM_REPOSITORY/releases/latest") || return 1
    tag=$(jq -r '.tag_name // empty' <<< "$data")
    [[ $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    MANAGER_TAG=$tag MANAGER_LATEST=${tag#v}
}
manager_latest_lookup() { manager_latest_release || MANAGER_LATEST=''; }
manager_download() {
    local work archive
    work=$(mktemp -d "$STATE/cache/manager-update-XXXXXX")
    archive="$work/source.tar.gz"
    http_get "https://api.github.com/repos/$GDM_REPOSITORY/tarball/$MANAGER_TAG" > "$archive"
    mkdir "$work/src"
    tar -xzf "$archive" -C "$work/src" --strip-components=1 --no-same-owner --no-same-permissions
    rm -f -- "$archive"
    MANAGER_SOURCE="$work/src"
}
manager_self_update() {
    local file version
    if [[ -d $GDM_ROOT/.git ]]; then say self_update_git "$GDM_ROOT"; return 0; fi
    MANAGER_LATEST=''
    ui_task self_update_checking manager_latest_lookup
    if [[ -z $MANAGER_LATEST ]]; then say self_update_unavailable; return 0; fi
    if ! version_gt "$MANAGER_LATEST" "$GDM_VERSION"; then say self_update_none "$GDM_VERSION"; return 0; fi
    ui_panel "$(t self_update_title)" "$(t self_update_versions "$GDM_VERSION" "$MANAGER_LATEST")" "$(t self_update_help)"
    confirm self_update_confirm || exit 10
    ui_task self_update_downloading manager_download
    IFS= read -r version < "$MANAGER_SOURCE/VERSION" || true
    [[ $version == "$MANAGER_LATEST" && -f $MANAGER_SOURCE/start.sh ]] || die self_update_invalid
    for file in "$MANAGER_SOURCE"/start.sh "$MANAGER_SOURCE"/lib/*.sh; do bash -n "$file" || die self_update_invalid; done
    printf '%s\n' "$MANAGER_SOURCE" > "$STATE/cache/manager-update.pending"
    say self_update_restart
}
# Runs in the shell that owns the lock: release it and start the new code,
# which installs itself into manager-releases on start-up.
manager_handover() {
    local source
    IFS= read -r source < "$STATE/cache/manager-update.pending" || return 0
    rm -f -- "$STATE/cache/manager-update.pending"
    [[ $source == "$STATE"/cache/manager-update-*/src && -f $source/start.sh ]] || return 0
    exec {GDM_LOCK_FD}>&-
    trap - EXIT ERR INT TERM
    ui_restore
    exec bash "$source/start.sh" --state-dir "$STATE" --lang "$LANGUAGE"
}

#!/usr/bin/env bash
# Host-side maintenance: scheduled backups, log rotation, certificates,
# uninstallation and manager self-update. GLPI's own settings stay in GLPI.
# Requires core.sh to be sourced first: it defines the shared globals STATE,
# GDM_ROOT, GDM_VERSION, LANGUAGE and GDM_LOCK_FD (set by init_state), and
# config.sh defines CONFIG. SC2153 is disabled because ShellCheck cannot see
# those cross-module assignments and suggests the unrelated local "state".
# shellcheck disable=SC2016,SC2034,SC2153
AUTO_BACKUP_KEEP=5
PRE_BACKUP_KEEP=3
# Log rotation: recommended values and the only ones offered (see logs_menu).
LOG_DEFAULTS='manager_days=30 glpi_mb=20 glpi_days=30 container_mb=10 container_files=3 binlog_days=30'
GDM_REPOSITORY=${GDM_REPOSITORY:-solqubit/glpi-docker-manager}

# ---------------------------------------------------------------- schedule
# maintenance.json (format 2): backups on/off, time (hour:minute) and frequency.
# The job itself runs every day at that time (log rotation, certificates) and
# decides whether a backup is due:
#   mode=days      every N days, counted from the newest automatic backup
#   mode=weekdays  on the listed ISO weekdays (1 Monday … 7 Sunday)
maintenance_settings() {
    local file="$STATE/maintenance.json" values weekdays='' day logs=''
    MAINT_BACKUPS=false MAINT_HOUR=3 MAINT_MINUTE=0 MAINT_MODE=days MAINT_EVERY=1 MAINT_WEEKDAYS=''
    log_settings_read ''
    [[ -r $file ]] || return 0
    values=$(jq -r '[(if .backups==true then "true" else "false" end), ((.hour // 3)|tostring), ((.minute // 0)|tostring),
        (if .mode=="weekdays" then "weekdays" else "days" end), ((.every // 1)|tostring),
        ((.weekdays // [])|map(tostring)|join(",")),
        ((.logs // {})|to_entries|map("\(.key)=\(.value)")|join(" "))] | join("\t")' "$file" 2>/dev/null) || return 0
    IFS=$'\t' read -r MAINT_BACKUPS MAINT_HOUR MAINT_MINUTE MAINT_MODE MAINT_EVERY weekdays logs <<< "$values" || true
    log_settings_read "$logs"
    [[ $MAINT_BACKUPS == true ]] || MAINT_BACKUPS=false
    [[ $MAINT_HOUR =~ ^([01]?[0-9]|2[0-3])$ ]] || MAINT_HOUR=3
    [[ $MAINT_MINUTE =~ ^[0-5]?[0-9]$ ]] || MAINT_MINUTE=0
    [[ $MAINT_EVERY =~ ^[0-9]{1,2}$ ]] && (( 10#$MAINT_EVERY >= 1 && 10#$MAINT_EVERY <= 30 )) || MAINT_EVERY=1
    MAINT_HOUR=$((10#$MAINT_HOUR)) MAINT_MINUTE=$((10#$MAINT_MINUTE)) MAINT_EVERY=$((10#$MAINT_EVERY))
    for day in ${weekdays//,/ }; do
        [[ $day =~ ^[1-7]$ && " $MAINT_WEEKDAYS " != *" $day "* ]] && MAINT_WEEKDAYS+="${MAINT_WEEKDAYS:+ }$day"
    done
    [[ $MAINT_MODE == weekdays && -n $MAINT_WEEKDAYS ]] || MAINT_MODE=days
}
maintenance_write() {
    local tmp days
    # Word splitting of the space-separated weekday list is intended here.
    # shellcheck disable=SC2086
    days=$(printf '%s\n' $MAINT_WEEKDAYS | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber) | sort')
    tmp=$(mktemp "$STATE/.maintenance.XXXXXX")
    jq -n --argjson backups "$MAINT_BACKUPS" --argjson hour "$MAINT_HOUR" --argjson minute "$MAINT_MINUTE" \
        --arg mode "$MAINT_MODE" --argjson every "$MAINT_EVERY" --argjson weekdays "$days" --argjson keep "$AUTO_BACKUP_KEEP" \
        --argjson logs "$(log_settings_json)" \
        '{format:2,backups:$backups,hour:$hour,minute:$minute,mode:$mode,every:$every,weekdays:$weekdays,keep:$keep,logs:$logs}' > "$tmp"
    mv -- "$tmp" "$STATE/maintenance.json"
}
# Compatibility with format 1 callers: maintenance_save BACKUPS HOUR.
maintenance_save() { maintenance_settings; MAINT_BACKUPS=$1 MAINT_HOUR=$2; maintenance_write; }
# Sets LOG_* from "key=value" pairs over the defaults; unknown or out-of-range
# values fall back to the recommended ones.
log_settings_read() {
    local pair key value
    LOG_MANAGER_DAYS=30 LOG_GLPI_MB=20 LOG_GLPI_DAYS=30 LOG_CONTAINER_MB=10 LOG_CONTAINER_FILES=3 LOG_BINLOG_DAYS=30
    for pair in $1; do
        key=${pair%%=*} value=${pair#*=}
        [[ $value =~ ^[0-9]{1,3}$ ]] || continue
        case $key in
            manager_days) [[ " 7 14 30 90 " == *" $value "* ]] && LOG_MANAGER_DAYS=$value;;
            glpi_mb) [[ " 10 20 50 " == *" $value "* ]] && LOG_GLPI_MB=$value;;
            glpi_days) [[ " 7 14 30 90 " == *" $value "* ]] && LOG_GLPI_DAYS=$value;;
            container_mb) [[ " 10 20 50 100 " == *" $value "* ]] && LOG_CONTAINER_MB=$value;;
            container_files) [[ " 3 5 " == *" $value "* ]] && LOG_CONTAINER_FILES=$value;;
            binlog_days) [[ " 1 3 7 30 " == *" $value "* ]] && LOG_BINLOG_DAYS=$value;;
        esac
    done
    return 0
}
log_settings_json() {
    jq -n --argjson manager_days "$LOG_MANAGER_DAYS" --argjson glpi_mb "$LOG_GLPI_MB" --argjson glpi_days "$LOG_GLPI_DAYS" \
        --argjson container_mb "$LOG_CONTAINER_MB" --argjson container_files "$LOG_CONTAINER_FILES" --argjson binlog_days "$LOG_BINLOG_DAYS" \
        '$ARGS.named'
}
maintenance_time_text() { printf '%02d:%02d\n' "$MAINT_HOUR" "$MAINT_MINUTE"; }
# "every day", "every 3 days", "Monday to Friday", "every Monday", "Mon, Wed, Fri".
maintenance_frequency_text() {
    local day text=''
    if [[ $MAINT_MODE == days ]]; then
        if (( MAINT_EVERY == 1 )); then t freq_daily; else t freq_every "$MAINT_EVERY"; fi
        return
    fi
    if [[ $MAINT_WEEKDAYS == '1 2 3 4 5' ]]; then t freq_workdays; return; fi
    if [[ $MAINT_WEEKDAYS =~ ^[1-7]$ ]]; then t freq_weekly "$(t "day_long_$MAINT_WEEKDAYS")"; return; fi
    for day in $MAINT_WEEKDAYS; do text+="${text:+, }$(t "day_short_$day")"; done
    printf '%s\n' "$text"
}
# Days of history the kept automatic backups cover with this frequency.
maintenance_coverage_days() {
    local count
    if [[ $MAINT_MODE == days ]]; then printf '%s\n' "$((AUTO_BACKUP_KEEP*MAINT_EVERY))"; return; fi
    count=$(wc -w <<< "$MAINT_WEEKDAYS")
    printf '%s\n' "$(((AUTO_BACKUP_KEEP*7+count-1)/count))"
}
# Midnight (local time) of the newest automatic backup's day, or nothing.
newest_auto_backup_day() {
    local newest
    newest=$(find "$STATE/backups" -maxdepth 1 -type f -name 'glpi-*-auto-*.tar.gz' -printf '%T@\n' 2>/dev/null | sort -rn | head -n 1)
    [[ -n $newest ]] || return 0
    date -d "$(date -d "@${newest%.*}" +%F)" +%s
}
backup_due() {
    local last today
    if [[ $MAINT_MODE == weekdays ]]; then [[ " $MAINT_WEEKDAYS " == *" $(date +%u) "* ]]; return; fi
    last=$(newest_auto_backup_day)
    [[ -n $last ]] || return 0
    today=$(date -d "$(date +%F)" +%s)
    # Half a day of slack absorbs daylight-saving changes.
    (( (today-last+43200)/86400 >= MAINT_EVERY ))
}
# Next COUNT backup moments as "Mon 20/10 03:00", following the same rules.
maintenance_next_runs() {
    local count=${1:-3} now day offset found=0 moment next last start clock
    clock=$(maintenance_time_text)
    now=$(date +%s)
    start=0
    (( $(date -d "$(date +%F) $clock" +%s) > now )) || start=1
    if [[ $MAINT_MODE == weekdays ]]; then
        for (( offset=start; offset<start+21 && found<count; offset++ )); do
            day=$(date -d "+$offset day" +%F)
            [[ " $MAINT_WEEKDAYS " == *" $(date -d "$day" +%u) "* ]] || continue
            printf '%s %s %s\n' "$(t "day_short_$(date -d "$day" +%u)")" "$(date -d "$day" +%d/%m)" "$clock"
            found=$((found+1))
        done
        return
    fi
    next=$(date -d "$(date -d "+$start day" +%F)" +%s)
    last=$(newest_auto_backup_day)
    if [[ -n $last ]]; then
        moment=$(date -d "$(date -d "@$last" +%F) + $MAINT_EVERY day" +%s)
        (( moment <= next )) || next=$moment
    fi
    for (( found=0; found<count; found++ )); do
        day=$(date -d "@$next" +%F)
        printf '%s %s %s\n' "$(t "day_short_$(date -d "$day" +%u)")" "$(date -d "$day" +%d/%m)" "$clock"
        next=$(date -d "$day + $MAINT_EVERY day" +%s)
    done
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
# Daily job at the chosen hour:minute. Persistent timers catch up after downtime.
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
            printf '[Unit]\nDescription=Daily GLPI Docker Manager maintenance (%s)\n\n[Timer]\nOnCalendar=*-*-* %02d:%02d:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' \
                "$STATE" "$MAINT_HOUR" "$MAINT_MINUTE" > "/etc/systemd/system/$unit.timer"
            chmod 644 "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"
            systemctl daemon-reload
            systemctl enable --now "$unit.timer" >/dev/null 2>&1
            systemctl restart "$unit.timer" >/dev/null 2>&1 || true;;
        cron)
            printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%d %d * * * root bash %q maintenance >/dev/null 2>&1\n' \
                "$MAINT_MINUTE" "$MAINT_HOUR" "$entry" > "/etc/cron.d/$unit"
            chmod 644 "/etc/cron.d/$unit";;
        *) return 1;;
    esac
}
# After an installation or a restore (also on a new server): default settings
# and the daily job (log rotation, certificate renewal, optional backups).
maintenance_ensure() {
    if [[ ! -f $STATE/maintenance.json ]]; then maintenance_settings; maintenance_write; fi
    if ! scheduler_install; then say maint_no_scheduler; fi
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
# Short state for the dashboard: off, on:<frequency · time> or missing.
maintenance_summary() {
    maintenance_settings
    if ! scheduler_installed; then printf 'missing\n'
    elif [[ $MAINT_BACKUPS == true ]]; then printf 'on:%s · %s\n' "$(maintenance_frequency_text)" "$(maintenance_time_text)"
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
# FORCE=true ("Run now") backs up even when no backup is due today.
maintenance_run() {
    local force=${1:-false} backup='' next
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
    glpi_logs_rotate
    maintenance_settings
    if [[ $MAINT_BACKUPS == true ]] && { [[ $force == true ]] || backup_due; }; then
        if [[ -n $(dc ps --status running --quiet glpi) && -n $(dc ps --status running --quiet db) ]]; then
            journal_begin backup
            ui_run 0 update_step_backup backup_create true auto
            journal_done
            backup_prune_auto
            backup=$LAST_BACKUP
        else say maint_services_stopped; MAINT_STATUS=warning; fi
    elif [[ $MAINT_BACKUPS == true ]]; then
        next=$(maintenance_next_runs 1)
        say maint_backup_not_due "$next"
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
# Checkbox list of weekdays; Enter toggles, "Save these days" confirms.
weekday_picker() {
    local pick last=1 day name
    local -A marked=()
    local -a options=()
    for day in $MAINT_WEEKDAYS; do marked[$day]=1; done
    while :; do
        options=()
        for day in 1 2 3 4 5 6 7; do
            name=$(t "day_long_$day"); name=${name^}
            if [[ -n ${marked[$day]:-} ]]; then options+=("$day" "$(ui_opt ok "☑ $name")")
            else options+=("$day" "$(ui_opt '' "☐ $name")"); fi
        done
        options+=(save "$(ui_opt primary "$(t weekdays_save)" "$(t opt_weekdays_save)")" back "$(ui_opt back "$(t ui_back_menu)")")
        choose pick weekdays_prompt "$last" "${options[@]}" || return 1
        case $pick in
            save) if (( ${#marked[@]} == 0 )); then say weekdays_none; continue; fi; break;;
            back) return 1;;
            *) if [[ -n ${marked[$pick]:-} ]]; then unset "marked[$pick]"; else marked[$pick]=1; fi; last=$pick;;
        esac
    done
    MAINT_WEEKDAYS=$(printf '%s\n' "${!marked[@]}" | sort -n | paste -sd' ')
}
frequency_menu() {
    local choice current=custom day name
    local -a days=()
    if [[ $MAINT_MODE == days ]]; then (( MAINT_EVERY > 3 )) || current="d$MAINT_EVERY"
    elif [[ $MAINT_WEEKDAYS == '1 2 3 4 5' ]]; then current=work
    elif [[ $MAINT_WEEKDAYS =~ ^[1-7]$ ]]; then current=weekly
    else current=pick; fi
    choose choice maint_freq_prompt "$current" \
        d1 "$(ui_opt primary "$(t freq_label_daily) · $(t opt_recommended)" "$(t opt_freq_coverage "$AUTO_BACKUP_KEEP" "$AUTO_BACKUP_KEEP")")" \
        d2 "$(ui_opt '' "$(t freq_label_every 2)" "$(t opt_freq_coverage "$AUTO_BACKUP_KEEP" "$((AUTO_BACKUP_KEEP*2))")")" \
        d3 "$(ui_opt '' "$(t freq_label_every 3)" "$(t opt_freq_coverage "$AUTO_BACKUP_KEEP" "$((AUTO_BACKUP_KEEP*3))")")" \
        work "$(ui_opt '' "$(t freq_label_workdays)" "$(t opt_freq_workdays)")" \
        weekly "$(ui_opt '' "$(t freq_label_weekly)" "$(t opt_freq_coverage "$AUTO_BACKUP_KEEP" "$((AUTO_BACKUP_KEEP*7))")")" \
        pick "$(ui_opt '' "$(t freq_label_pick)" "$(t opt_freq_pick)")" \
        custom "$(ui_opt '' "$(t freq_label_custom)" "$(t opt_freq_custom)")" \
        back "$(ui_opt back "$(t ui_back_menu)")" || return 1
    case $choice in
        d1|d2|d3) MAINT_MODE=days MAINT_EVERY=${choice#d};;
        work) MAINT_MODE=weekdays MAINT_WEEKDAYS='1 2 3 4 5';;
        weekly)
            for day in 1 2 3 4 5 6 7; do name=$(t "day_long_$day"); days+=("$day" "${name^}"); done
            choose day maint_weekday_prompt "${MAINT_WEEKDAYS%% *}" "${days[@]}" || return 1
            MAINT_MODE=weekdays MAINT_WEEKDAYS=$day;;
        pick) weekday_picker || return 1; MAINT_MODE=weekdays;;
        custom)
            ask_value day maint_every_prompt "$MAINT_EVERY" days || return 1
            MAINT_MODE=days MAINT_EVERY=$day;;
        *) return 1;;
    esac
}
# Hours are tagged by impact: GLPI stops for a few minutes during a backup.
time_menu() {
    local hour minute kind label help
    local -a hours=() minutes=()
    for hour in {0..23}; do
        case $hour in
            2|3) kind=primary label=$(t hour_recommended) help=$(t opt_hour_recommended);;
            0|1|4|5|22|23) kind=ok label=$(t hour_quiet) help=$(t opt_hour_quiet);;
            8|9|10|11|12|13|14|15|16|17|18) kind=warn label=$(t hour_work) help=$(t opt_hour_work);;
            *) kind='' label='' help=$(t opt_hour_other);;
        esac
        hours+=("$hour" "$(ui_opt "$kind" "$(printf '%02d:00' "$hour")${label:+ · $label}" "$help")")
    done
    choose hour maint_hour_prompt "$MAINT_HOUR" "${hours[@]}" || return 1
    for minute in 0 15 30 45; do minutes+=("$minute" "$(printf '%02d:%02d' "$hour" "$minute")"); done
    choose minute maint_minute_prompt "$((MAINT_MINUTE/15*15))" "${minutes[@]}" || return 1
    MAINT_HOUR=$hour MAINT_MINUTE=$minute
}
# Settings in three clear sections with a preview of the next backup dates.
schedule_menu() {
    local action state toggle next=''
    local -a runs=() scheduler_row=()
    while :; do
        maintenance_settings
        if [[ $MAINT_BACKUPS == true ]]; then
            state=$(t maint_on)
            mapfile -t runs < <(maintenance_next_runs 3)
            next=$(IFS=,; printf '%s' "${runs[*]}"); next=${next//,/ · }
            toggle=$(ui_opt warn "$(t maint_disable)" "$(t opt_maint_disable)")
        else
            state=$(t maint_off) next='—'
            toggle=$(ui_opt primary "$(t maint_enable)" "$(t opt_maint_enable "$AUTO_BACKUP_KEEP")")
        fi
        # The scheduler row only appears when something is wrong with it.
        scheduler_row=()
        scheduler_installed || scheduler_row=("$(t maint_scheduler)"$'\t'"$(t maint_scheduler_missing)")
        ui_panel "$(t maint_title)" \
            "§$(t maint_section_backups)" \
            "$(t maint_state)"$'\t'"$state" \
            "$(t maint_frequency)"$'\t'"$(maintenance_frequency_text)" \
            "$(t maint_next)"$'\t'"$next" \
            "$(t maint_kept)"$'\t'"$(t maint_coverage "$AUTO_BACKUP_KEEP" "$(maintenance_coverage_days)")" \
            "§$(t maint_section_task)" \
            "$(t maint_time)"$'\t'"$(maintenance_time_text)" \
            "$(t maint_task_does)"$'\t'"$(t maint_task_list)" \
            "${scheduler_row[@]}" \
            "§$(t maint_section_logs)" \
            "$(t logs_summary_label)"$'\t'"$(t logs_summary "$LOG_GLPI_DAYS" "$LOG_BINLOG_DAYS")"
        choose action maint_prompt toggle toggle "$toggle" \
            frequency "$(ui_opt '' "$(t maint_frequency_option "$(maintenance_frequency_text)")" "$(t opt_maint_frequency)")" \
            time "$(ui_opt '' "$(t maint_time_option "$(maintenance_time_text)")" "$(t opt_maint_time)")" \
            logs "$(ui_opt '' "$(t maint_logs_option)" "$(t opt_maint_logs)")" \
            run "$(ui_opt ok "$(t maint_run_now)" "$(t opt_maint_run)")" back "$(ui_opt back "$(t ui_back_menu)")" || exit 10
        case $action in
            toggle) if [[ $MAINT_BACKUPS == true ]]; then MAINT_BACKUPS=false; else MAINT_BACKUPS=true; fi;;
            frequency) frequency_menu || continue;;
            time) time_menu || continue;;
            logs) logs_menu; continue;;
            run) maintenance_run true; return;;
            *) exit 10;;
        esac
        maintenance_write
        scheduler_install || say maint_no_scheduler
        say maint_saved
    done
}
# One row per kind of log: where it lives, current value and the recommended one.
logs_menu() {
    local action recommended
    recommended=$(t logs_recommended)
    while :; do
        maintenance_settings
        ui_panel "$(t logs_title)" \
            "$(t logs_manager)"$'\t'"$(t logs_days "$LOG_MANAGER_DAYS")$( (( LOG_MANAGER_DAYS == 30 )) && printf ' · %s' "$recommended")" \
            "$(t logs_glpi)"$'\t'"$(t logs_glpi_value "$LOG_GLPI_MB" "$LOG_GLPI_DAYS")$( (( LOG_GLPI_MB == 20 && LOG_GLPI_DAYS == 30 )) && printf ' · %s' "$recommended")" \
            "$(t logs_containers)"$'\t'"$(t logs_container_value "$LOG_CONTAINER_MB" "$LOG_CONTAINER_FILES")$( (( LOG_CONTAINER_MB == 10 && LOG_CONTAINER_FILES == 3 )) && printf ' · %s' "$recommended")" \
            "$(t logs_binlog)"$'\t'"$(t logs_days "$LOG_BINLOG_DAYS")$( (( LOG_BINLOG_DAYS == 30 )) && printf ' · %s' "$recommended")" \
            "$(t logs_history)"$'\t'"$(t logs_history_value)" \
            "$(t logs_body)"
        choose action logs_prompt manager \
            manager "$(ui_opt '' "$(t logs_manager)" "$(t opt_logs_manager)")" \
            glpi "$(ui_opt '' "$(t logs_glpi)" "$(t opt_logs_glpi)")" \
            containers "$(ui_opt warn "$(t logs_containers)" "$(t opt_logs_containers)")" \
            binlog "$(ui_opt warn "$(t logs_binlog)" "$(t opt_logs_binlog)")" \
            back "$(ui_opt back "$(t ui_back_menu)")" || return 0
        case $action in
            manager) log_days_choice LOG_MANAGER_DAYS logs_days_prompt 30 || continue;;
            glpi)
                log_size_choice || continue
                log_days_choice LOG_GLPI_DAYS logs_days_prompt 30 || continue;;
            containers) log_container_choice || continue; log_apply_services || continue;;
            binlog) log_binlog_choice || continue; log_apply_services || continue;;
            *) return 0;;
        esac
        maintenance_write
        say logs_saved
    done
}
# Days to keep: 7 / 14 / 30 (recommended) / 90.
log_days_choice() {
    local variable=$1 prompt=$2 recommended=$3 value days
    local -a options=()
    for days in 7 14 30 90; do
        if (( days == recommended )); then options+=("$days" "$(ui_opt primary "$(t logs_days "$days") · $(t logs_recommended)" "$(t opt_logs_days_default)")")
        elif (( days < recommended )); then options+=("$days" "$(ui_opt '' "$(t logs_days "$days")" "$(t opt_logs_days_short)")")
        else options+=("$days" "$(ui_opt '' "$(t logs_days "$days")" "$(t opt_logs_days_long)")"); fi
    done
    choose value "$prompt" "${!variable}" "${options[@]}" || return 1
    printf -v "$variable" '%s' "$value"
}
log_size_choice() {
    local value
    choose value logs_size_prompt "$LOG_GLPI_MB" \
        10 "$(ui_opt '' '10 MB' "$(t opt_logs_size_small)")" \
        20 "$(ui_opt primary "20 MB · $(t logs_recommended)" "$(t opt_logs_size_default)")" \
        50 "$(ui_opt '' '50 MB' "$(t opt_logs_size_large)")" || return 1
    LOG_GLPI_MB=$value
}
log_container_choice() {
    local value
    choose value logs_container_prompt "$LOG_CONTAINER_MB:$LOG_CONTAINER_FILES" \
        10:3 "$(ui_opt primary "$(t logs_container_value 10 3) · $(t logs_recommended)" "$(t opt_logs_container_default)")" \
        20:3 "$(ui_opt '' "$(t logs_container_value 20 3)" "$(t opt_logs_container_more)")" \
        50:5 "$(ui_opt '' "$(t logs_container_value 50 5)" "$(t opt_logs_container_more)")" \
        100:5 "$(ui_opt warn "$(t logs_container_value 100 5)" "$(t opt_logs_container_large)")" || return 1
    LOG_CONTAINER_MB=${value%%:*} LOG_CONTAINER_FILES=${value#*:}
}
log_binlog_choice() {
    local value
    choose value logs_binlog_prompt "$LOG_BINLOG_DAYS" \
        1 "$(ui_opt '' "$(t logs_days 1)" "$(t opt_binlog_short)")" \
        3 "$(ui_opt '' "$(t logs_days 3)" "$(t opt_binlog_short)")" \
        7 "$(ui_opt '' "$(t logs_days 7)" "$(t opt_binlog_week)")" \
        30 "$(ui_opt primary "$(t logs_days 30) · $(t logs_recommended)" "$(t opt_binlog_default)")" || return 1
    LOG_BINLOG_DAYS=$value
}
# Container and MySQL limits live in the generated Compose file: save, then
# render a new revision and restart the services (after confirmation).
log_apply_services() {
    confirm logs_restart_confirm || return 1
    maintenance_write
    ui_run 0 logs_step_apply tls_reapply
}

# ---------------------------------------------------------------- logs
# Private stage/maintenance logs and the operation history never grow unbounded.
logs_rotate() {
    local folder="$STATE/logs" file update
    maintenance_settings
    if [[ -d $folder && ! -L $folder ]]; then
        find "$folder" -maxdepth 1 -type f \( -name 'install-*.log' -o -name 'install-*.status' -o -name 'maintenance-*.log' \) \
            -mtime +"$LOG_MANAGER_DAYS" -delete 2>/dev/null || true
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
# Keeps the newest N backups of one kind ("auto" or "pre"); protected recovery
# points are skipped by backup_ops.py. Manual backups never match.
backup_prune() {
    local kind=$1 keep=$2 file
    find "$STATE/backups" -maxdepth 1 -type f -name "glpi-*-$kind-*.tar.gz" -printf '%T@ %p\n' | sort -rn |
        tail -n +"$((keep+1))" | cut -d' ' -f2- | while IFS= read -r file; do
            python3 "$GDM_ROOT/tools/backup_ops.py" delete "$STATE" "$file" || say backups_prune_skipped "$file"
        done
}
backup_prune_auto() { backup_prune auto "$AUTO_BACKUP_KEEP"; }
# GLPI never rotates its technical logs in /var/glpi/_log (PHP/SQL errors,
# cron, mail). Files over 20 MiB are compressed with the date and emptied;
# compressed copies are kept 30 days. GLPI's audit trail (item history and
# events) lives in the database and is not affected.
glpi_logs_rotate() {
    [[ -n $(dc ps --status running --quiet glpi) ]] || return 0
    maintenance_settings
    dc exec -T --user www-data -e "GDM_LOG_BYTES=$((LOG_GLPI_MB*1048576))" -e "GDM_LOG_DAYS=$LOG_GLPI_DAYS" glpi sh -c '
        stamp=$(date -u +%Y%m%d%H%M%S)
        for file in /var/glpi/_log/*.log; do
            [ -f "$file" ] || continue
            [ "$(wc -c < "$file")" -gt "$GDM_LOG_BYTES" ] || continue
            gzip -c "$file" > "$file.$stamp.gz" && : > "$file"
        done
        find /var/glpi/_log -maxdepth 1 -type f -name "*.log.*.gz" -mtime +"$GDM_LOG_DAYS" -delete' || say maint_glpi_logs_failed
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
# Only when the CA key is lost or compromised: every client must import the new one.
tls_new_ca() { GDM_TLS_NEW_CA=1 GDM_TLS_FORCE_RENEW=1 tls_reapply; }
# Card rows describing the local CA for GLPI Agents (fills the caller's ca_rows).
ca_rows_build() {
    local ca fingerprint CERT_DAYS='' CERT_END_DATE=''
    ca="$(cfg cert_dir)/self-signed/ca/gdm-ca.pem"
    [[ -f $ca ]] || return 0
    fingerprint=$(openssl x509 -in "$ca" -noout -fingerprint -sha256 2>/dev/null) || fingerprint=''
    cert_days "$ca" || true
    ca_rows=("§$(t ca_section)"
        "$(t ca_download)"$'\t'"$(tls_ca_url "$(cfg hostname)" "$(cfg http_port)")"
        "$(t ca_path)"$'\t'"$ca"
        "$(t ca_expiry)"$'\t'"${CERT_END_DATE:-?}"
        "$(t ca_fingerprint)"$'\t'"${fingerprint#*=}"
        "$(t ca_agent_help)")
}
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
        choose action cert_prompt https https "$(ui_opt primary "$(t cert_enable_https)")" back "$(ui_opt back "$(t ui_back_menu)")" || exit 10
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
    local -a ca_rows=()
    [[ $mode != self-signed ]] || ca_rows_build
    ui_panel "$(t cert_title)" "$(t cert_mode)"$'\t'"$(t "ui_tls_$mode")" "$(t ui_host)"$'\t'"$(cfg hostname)" \
        "$(t cert_expiry)"$'\t'"$expiry" "$help" "${ca_rows[@]}"
    case $mode in
        self-signed) choose action cert_prompt back renew "$(ui_opt warn "$(t cert_renew_now)" "$(t opt_cert_renew)")" \
            newca "$(ui_opt danger "$(t cert_new_ca)" "$(t opt_cert_new_ca)")" \
            mode "$(ui_opt '' "$(t cert_change_mode)" "$(t opt_cert_mode)")" back "$(ui_opt back "$(t ui_back_menu)")" || exit 10;;
        custom) choose action cert_prompt back reload "$(ui_opt warn "$(t cert_reload)" "$(t opt_cert_reload)")" \
            mode "$(ui_opt '' "$(t cert_change_mode)" "$(t opt_cert_mode)")" back "$(ui_opt back "$(t ui_back_menu)")" || exit 10;;
        acme) choose action cert_prompt back restart "$(ui_opt warn "$(t cert_restart_proxy)" "$(t opt_cert_restart)")" \
            mode "$(ui_opt '' "$(t cert_change_mode)" "$(t opt_cert_mode)")" back "$(ui_opt back "$(t ui_back_menu)")" || exit 10;;
    esac
    if [[ $action == mode ]]; then settings_command https; return; fi
    case $action in
        renew) ui_run 0 cert_step_apply tls_force_renew;;
        newca) typed_confirm NEW-CA; ui_run 0 cert_step_apply tls_new_ca;;
        reload) ui_run 0 cert_step_apply tls_reapply;;
        restart) ui_run 0 cert_step_restart dc restart proxy;;
        *) exit 10;;
    esac
    ui_panel "$(t cert_applied)" "$(t ready "$(installation_url)")"
}

# ---------------------------------------------------------------- free space
human_size() {
    local bytes=${1:-0}
    if (( bytes >= 1073741824 )); then printf '%d.%d GB\n' "$((bytes/1073741824))" "$((bytes%1073741824*10/1073741824))"
    elif (( bytes >= 1048576 )); then printf '%d MB\n' "$((bytes/1048576))"
    else printf '%d KB\n' "$(((bytes+1023)/1024))"; fi
}
path_bytes() {
    if (( $# == 0 )); then printf '0\n'; return; fi
    du -sbc -- "$@" 2>/dev/null | tail -n 1 | cut -f1
}
# Newest configuration revision of one installation ID.
installation_revision() {
    local file found=''
    for file in "$STATE"/revisions/*/config.json; do
        if [[ -f $file && $(jq -r '.id // empty' "$file" 2>/dev/null) == "$1" ]]; then found=${file%/config.json}; fi
    done
    printf '%s\n' "$found"
}
# Fills the caller's CLEAN_* arrays (dynamic scope) with what can be removed.
cleanup_scan() {
    local file ref revision previous='' id release current_release size index
    local -A keep_images=() keep_revisions=() seen=()
    local -a needed=() revisions=()
    CLEAN_IMAGES=() CLEAN_PREVIOUS=() CLEAN_BACKUPS=() CLEAN_REVISIONS=() CLEAN_RELEASES=()
    CLEAN_IMAGES_BYTES=0
    [[ ! -r $STATE/previous-revision ]] || IFS= read -r previous < "$STATE/previous-revision" || true
    mapfile -t CLEAN_PREVIOUS < <(previous_installations)
    # Needed: the active revision, the one before the last update, kept installations.
    needed=("$(readlink -f "$STATE/current" 2>/dev/null || true)")
    [[ -z $previous ]] || needed+=("$previous")
    for id in "${CLEAN_PREVIOUS[@]}"; do needed+=("$(installation_revision "$id")"); done
    for revision in "${needed[@]}"; do
        [[ -n $revision ]] || continue
        keep_revisions[$revision]=1
        [[ -f $revision/config.json ]] || continue
        while IFS= read -r ref; do keep_images[$ref]=1; done < <(jq -r '.glpi_image, .mysql_image, .caddy_image | select(. != null)' "$revision/config.json")
    done
    # Images this root pinned at some point and no longer needs.
    for file in "$STATE"/revisions/*/config.json; do
        [[ -f $file ]] || continue
        while IFS= read -r ref; do
            [[ -z ${keep_images[$ref]:-} && -z ${seen[$ref]:-} ]] || continue
            seen[$ref]=1
            ui_status "$ref"
            size=$(docker image inspect -f '{{.Size}}' "$ref" 2>/dev/null) || continue
            CLEAN_IMAGES+=("$ref"); CLEAN_IMAGES_BYTES=$((CLEAN_IMAGES_BYTES+size))
        done < <(jq -r '.glpi_image, .mysql_image, .caddy_image | select(. != null)' "$file")
    done
    # Pre-update/pre-restore backups except the newest one.
    mapfile -t CLEAN_BACKUPS < <(find "$STATE/backups" -maxdepth 1 -type f -name 'glpi-*-pre-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | tail -n +2 | cut -d' ' -f2-)
    # Old revisions (the 3 newest are always kept) and leftover rehearsals.
    mapfile -t revisions < <(find "$STATE/revisions" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}T[0-9]{6}-[a-f0-9]{8}' -printf '%f\n' 2>/dev/null | sort -r)
    for index in "${!revisions[@]}"; do
        revision="$STATE/revisions/${revisions[index]}"
        if (( index >= 3 )) && [[ -z ${keep_revisions[$revision]:-} ]]; then CLEAN_REVISIONS+=("$revision"); fi
    done
    for revision in "$STATE"/rehearsals/*; do
        if [[ -d $revision && ! -L $revision && ${revision##*/} =~ ^[a-f0-9]{16}$ ]]; then CLEAN_REVISIONS+=("$revision"); fi
    done
    # Older copies of this manager; the installed and the running one stay.
    current_release=$(readlink -f "$STATE/manager" 2>/dev/null) || current_release=''
    for release in "$STATE"/manager-releases/*; do
        [[ -d $release && ! -L $release && ${release##*/} =~ ^[a-f0-9]{16}$ ]] || continue
        [[ $release == "$current_release" || $GDM_ROOT == "$release"* ]] || CLEAN_RELEASES+=("$release")
    done
}
cleanup_images() {
    local ref
    for ref in "${CLEAN_IMAGES[@]}"; do
        ui_status "$ref"
        # By digest only; an image still used by another container is left alone.
        docker image rm "${ref%%:*}@${ref##*@}" >/dev/null 2>&1 || say cleanup_image_in_use "${ref%@*}"
    done
}
cleanup_previous() {
    local id
    for id in "${CLEAN_PREVIOUS[@]}"; do installation_remove "$id"; done
    rm -f -- "$STATE/previous-revision"
}
cleanup_backups() {
    local file
    for file in "${CLEAN_BACKUPS[@]}"; do
        ui_status "${file##*/}"
        python3 "$GDM_ROOT/tools/backup_ops.py" delete "$STATE" "$file" || say backups_prune_skipped "$file"
    done
}
cleanup_paths() {
    local path
    for path in "$@"; do
        [[ $path == "$STATE"/* && ! -L $path ]] || continue
        ui_status "${path##*/}"
        rm -rf --one-file-system -- "$path"
    done
}
cleanup_previous_bytes() {
    local id
    local -a folders=()
    for id in "${CLEAN_PREVIOUS[@]}"; do [[ ! -d $STATE/data/$id ]] || folders+=("$STATE/data/$id"); done
    path_bytes "${folders[@]}"
}
# Adds one entry to the caller's options; an empty category does nothing.
cleanup_option() {
    local value=$1 kind=$2 label=$3 help=$4 count=$5
    if (( count == 0 )); then options+=(nothing "$(ui_opt '' "$label · $(t cleanup_empty)" "$help")")
    else options+=("$value" "$(ui_opt "$kind" "$label" "$help")"); fi
}
# Everything removable, with sizes; nothing is deleted without choosing it.
cleanup_menu() {
    local action previous_text id
    local -a CLEAN_IMAGES=() CLEAN_PREVIOUS=() CLEAN_BACKUPS=() CLEAN_REVISIONS=() CLEAN_RELEASES=() options=()
    local CLEAN_IMAGES_BYTES=0
    while :; do
        ui_task cleanup_scanning cleanup_scan
        previous_text=''
        for id in "${CLEAN_PREVIOUS[@]}"; do previous_text+="${previous_text:+, }GLPI $(installation_version "$id")"; done
        ui_panel "$(t cleanup_title)" "$(t cleanup_body)"
        options=()
        cleanup_option images ok "$(t cleanup_images "${#CLEAN_IMAGES[@]}" "$(human_size "$CLEAN_IMAGES_BYTES")")" \
            "$(t cleanup_images_help)" "${#CLEAN_IMAGES[@]}"
        cleanup_option previous danger "$(t cleanup_previous "${#CLEAN_PREVIOUS[@]}" "$(human_size "$(cleanup_previous_bytes)")")" \
            "$(t cleanup_previous_help "${previous_text:--}")" "${#CLEAN_PREVIOUS[@]}"
        cleanup_option backups warn "$(t cleanup_backups "${#CLEAN_BACKUPS[@]}" "$(human_size "$(path_bytes "${CLEAN_BACKUPS[@]}")")")" \
            "$(t cleanup_backups_help)" "${#CLEAN_BACKUPS[@]}"
        cleanup_option revisions ok "$(t cleanup_revisions "${#CLEAN_REVISIONS[@]}" "$(human_size "$(path_bytes "${CLEAN_REVISIONS[@]}")")")" \
            "$(t cleanup_revisions_help)" "${#CLEAN_REVISIONS[@]}"
        cleanup_option releases ok "$(t cleanup_releases "${#CLEAN_RELEASES[@]}" "$(human_size "$(path_bytes "${CLEAN_RELEASES[@]}")")")" \
            "$(t cleanup_releases_help)" "${#CLEAN_RELEASES[@]}"
        options+=(back "$(ui_opt back "$(t ui_back_menu)")")
        choose action cleanup_prompt back "${options[@]}" || exit 10
        case $action in
            images) ui_run 0 cleanup_step_images cleanup_images;;
            previous) typed_confirm DELETE; ui_run 0 cleanup_step_previous cleanup_previous;;
            backups) confirm cleanup_backups_confirm || continue; ui_run 0 cleanup_step_backups cleanup_backups;;
            revisions) ui_run 0 cleanup_step_files cleanup_paths "${CLEAN_REVISIONS[@]}";;
            releases) ui_run 0 cleanup_step_files cleanup_paths "${CLEAN_RELEASES[@]}";;
            nothing) say cleanup_nothing; continue;;
            *) exit 10;;
        esac
        say cleanup_done
    done
}

# ---------------------------------------------------------------- uninstall
# Every installation ID ever used under this root (restores assign new IDs).
installation_ids() {
    local file
    for file in "$STATE"/revisions/*/config.json; do
        [[ -f $file ]] && jq -r '.id // empty' "$file" 2>/dev/null
    done | grep -E '^[a-f0-9]{16}$' | sort -u
}
# Removes one installation of this root: containers, labelled volumes and its
# data folder. Volumes labelled for another installation are never touched.
installation_remove() {
    local id=$1 role name label container directory
    [[ $id =~ ^[a-f0-9]{16}$ ]] || die invalid installation_id
    ui_status "gdm_$id"
    docker compose --project-name "gdm_$id" down --remove-orphans >/dev/null 2>&1 || true
    while IFS= read -r container; do
        [[ -z $container ]] || docker rm -f "$container" >/dev/null 2>&1 || true
    done < <(docker ps -aq --filter "label=com.docker.compose.project=gdm_$id")
    for role in glpi_data db_data plugins marketplace caddy_data caddy_config; do
        name="gdm_${id}_$role"
        label=$(docker volume inspect -f '{{index .Labels "org.glpidm.installation"}}' "$name" 2>/dev/null) || continue
        if [[ $label == "$id" ]]; then docker volume rm "$name" >/dev/null; else say foreign_resource "$name"; fi
    done
    directory="$STATE/data/$id"
    if [[ -d $directory && ! -L $directory && ! -L $STATE/data ]]; then
        rm -rf --one-file-system -- "$directory"
    fi
}
# Installations of this root that still have data, other than the active one.
previous_installations() {
    local id current=''
    [[ ! -r $STATE/current/config.json ]] || current=$(jq -r '.id // empty' "$STATE/current/config.json" 2>/dev/null)
    while IFS= read -r id; do
        [[ $id != "$current" ]] || continue
        if [[ -d $STATE/data/$id ]] || docker volume inspect "gdm_${id}_db_data" >/dev/null 2>&1; then
            printf '%s\n' "$id"
        fi
    done < <(installation_ids)
}
# GLPI version of an installation, read from its newest configuration revision.
installation_version() {
    local file version=''
    for file in "$STATE"/revisions/*/config.json; do
        [[ -f $file && $(jq -r '.id // empty' "$file" 2>/dev/null) == "$1" ]] || continue
        version=$(jq -r '.glpi_version // empty' "$file")
    done
    printf '%s\n' "${version:-?}"
}
uninstall_services() {
    local id
    while IFS= read -r id; do installation_remove "$id"; done < <(installation_ids)
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
    choose scope uninstall_prompt cancel keep "$(ui_opt danger "$(t uninstall_keep)" "$(t opt_uninstall_keep)")" \
        all "$(ui_opt danger "$(t uninstall_all)" "$(t opt_uninstall_all)")" cancel "$(ui_opt back "$(t ui_back_menu)")" || exit 10
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
# Git checkouts are updated with git itself, as the checkout's owner: running
# git as root would leave root-owned files in a user's clone and trip Git's
# "dubious ownership" protection.
git_as_owner() {
    local owner
    owner=$(stat -c %U -- "$GDM_ROOT")
    if [[ $owner == root || $owner == "$(id -un)" ]]; then git -C "$GDM_ROOT" "$@"
    else runuser -u "$owner" -- git -C "$GDM_ROOT" "$@"; fi
}
manager_git_fetch() { git_as_owner fetch --quiet || GIT_BEHIND=error; }
manager_git_pull() { git_as_owner pull --ff-only --quiet; }
manager_git_update() {
    local branch GIT_BEHIND=''
    command -v git >/dev/null || { say self_update_git "$GDM_ROOT"; return 0; }
    if [[ -n $(git_as_owner status --porcelain --untracked-files=no 2>/dev/null) ]]; then
        say self_update_git_dirty "$GDM_ROOT"; return 0
    fi
    if ! git_as_owner rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        say self_update_git_noupstream "$GDM_ROOT"; return 0
    fi
    ui_task self_update_checking manager_git_fetch
    [[ $GIT_BEHIND != error ]] || { say self_update_unavailable; return 0; }
    GIT_BEHIND=$(git_as_owner rev-list --count 'HEAD..@{u}')
    branch=$(git_as_owner rev-parse --abbrev-ref HEAD)
    if [[ $GIT_BEHIND == 0 ]]; then say self_update_git_none "$branch"; return 0; fi
    ui_panel "$(t self_update_title)" "$(t self_update_git_behind "$GIT_BEHIND" "$branch")" \
        "$GDM_ROOT" "$(t self_update_help)"
    confirm self_update_confirm || exit 10
    ui_task self_update_downloading manager_git_pull
    bash -n "$GDM_ROOT/start.sh" || die self_update_invalid
    printf '%s\n' "$GDM_ROOT" > "$STATE/cache/manager-update.pending"
    say self_update_restart
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
    if [[ -e $GDM_ROOT/.git ]]; then manager_git_update; return; fi
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
    [[ ( $source == "$STATE"/cache/manager-update-*/src || $source == "$GDM_ROOT" ) && -f $source/start.sh ]] || return 0
    exec {GDM_LOCK_FD}>&-
    trap - EXIT ERR INT TERM
    ui_restore
    exec bash "$source/start.sh" --state-dir "$STATE" --lang "$LANGUAGE"
}

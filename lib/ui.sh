#!/usr/bin/env bash
# Native terminal controls keep the first screen usable before package bootstrap.
# Visual language (shared with tools/terminal_ui.py):
#   [+] success · [*] information/progress · [!] warning · [✗] error · [?] question
# shellcheck disable=SC2034
UI_TTY_STATE=''
UI_CURSOR_HIDDEN=false
UI_SPINNER_PID=''
UI_LAST_LOG=''
UI_PROGRESS_FD=''
UI_STATUS_FILE=''
UI_CURRENT_STEP=''
UI_LAST_CLOCK='00:00'
UI_ACTIVE=false
UI_SECRET_ACTIVE=false
UI_SECRET_VISIBILITY=${GDM_PASSWORD_VISIBILITY:-visible}
[[ $UI_SECRET_VISIBILITY == hidden ]] || UI_SECRET_VISIBILITY=visible
UI_PAGE_LINES=0
UI_LEVEL=info
declare -a UI_CONTEXT=() UI_NOTICES=() UI_STEP_LABELS=()

ui_interactive() { [[ -t 0 && -t 2 && ${TERM:-dumb} != dumb && ${GDM_UI:-auto} != plain ]] && command -v stty >/dev/null; }
ui_colors() { [[ -z ${NO_COLOR+x} && -t 2 && ${TERM:-dumb} != dumb ]]; }
ui_color() { if ui_colors; then printf '\033[%sm' "$1" >&2; fi; }
ui_dimensions() {
    UI_ROWS=24 UI_COLS=80
    local ui_rows ui_cols
    if [[ -t 0 ]] && read -r ui_rows ui_cols < <(stty size 2>/dev/null); then
        (( ui_rows < 1 )) || UI_ROWS=$ui_rows
        (( ui_cols < 1 )) || UI_COLS=$ui_cols
    fi
    UI_WIDTH=$((UI_COLS-8))
    (( UI_WIDTH <= 100 )) || UI_WIDTH=100
    (( UI_WIDTH >= 20 )) || UI_WIDTH=20
}
ui_wrap() {
    local ui_text=$1 ui_width=$2 ui_word ui_line=''
    local -a ui_words=()
    read -r -a ui_words <<< "$ui_text"
    for ui_word in "${ui_words[@]}"; do
        if (( ${#ui_line}+${#ui_word}+1 > ui_width )) && [[ -n $ui_line ]]; then
            printf '%s\n' "$ui_line"; ui_line=''
        fi
        while (( ${#ui_word} > ui_width )); do
            [[ -z $ui_line ]] || { printf '%s\n' "$ui_line"; ui_line=''; }
            printf '%s\n' "${ui_word:0:ui_width}"; ui_word=${ui_word:ui_width}
        done
        ui_line+="${ui_line:+ }$ui_word"
    done
    printf '%s\n' "$ui_line"
}

# ---------------------------------------------------------------- messages
# Message keys map to a severity without parsing translated text.
ui_level_of() {
    case $1 in
        failed|invalid|unhealthy|docker_start_failed|host_io_error|host_readonly|host_no_space|port_busy|\
        storage_insufficient|storage_inodes|storage_temporary|backup_invalid|backup_space|low_resources|\
        foreign_resource|bad_path|locked|permissions|image_missing|remote_docker|linux_only|architecture|\
        update_boundary|unknown_command|services_required|not_installed|need_sudo|ui_interrupted|\
        self_update_invalid)
            UI_LEVEL=error;;
        *warning*|*notice*|*unknown*|*required*|*manual*|*_failed|cancelled|cleanup_deferred|config_restored|\
        destructive|older_release|security_release|resource_reference|bad_password|bad_root_password|\
        ui_bad_*|ui_invalid_choice|ui_error_log|docker_service_stopped|docker_storage_unavailable|\
        docker_plugins_missing|update_images_unavailable|update_no_patches|credentials_note|diagnose_note|\
        host_storage_steps|acme_requirements|cert_instructions|releases_stale|install_exists|admin_command|registry_rate_limited|\
        docker_context_help|maint_no_scheduler|maint_skipped|maint_services_stopped|backups_prune_skipped|\
        cert_expiring|cert_custom_expiring|cert_acme_expiring|cert_auto_renewing|firewall_docker|\
        self_update_git|self_update_unavailable|self_update_git_dirty|self_update_git_noupstream|cleanup_image_in_use|\
        weekdays_none)
            UI_LEVEL=warning;;
        ready|updated|detected|*_done|*_ok|*_ready|*_saved|*_cached|self_signed)
            UI_LEVEL=success;;
        *) UI_LEVEL=info;;
    esac
}
ui_marker_style() {
    case $1 in
        success) UI_MARK='+' UI_TONE='1;32' UI_BODY='0';;
        warning) UI_MARK='!' UI_TONE='1;33' UI_BODY='0;33';;
        error) UI_MARK='✗' UI_TONE='1;31' UI_BODY='0;31';;
        ask) UI_MARK='?' UI_TONE='1;35' UI_BODY='1';;
        *) UI_MARK='*' UI_TONE='1;34' UI_BODY='0';;
    esac
}
# Print one marked message to stderr; continuation lines are aligned.
ui_log() {
    local ui_level=$1 ui_text=$2
    ui_marker_style "$ui_level"
    [[ $ui_level != success ]] || ui_text=${ui_text#✓ }
    ui_text=${ui_text//$'\n'/$'\n      '}
    printf '  ' >&2; ui_color "$UI_TONE"; printf '[%s]' "$UI_MARK" >&2; ui_color 0
    printf ' ' >&2; ui_color "$UI_BODY"; printf '%s' "$ui_text" >&2; ui_color 0
    printf '\n' >&2
}
# Same as ui_log for a locale key, highlighting the printf arguments.
ui_say() {
    local ui_level=$1 ui_key=$2 ui_arg ui_text; shift 2
    local -a ui_args=()
    if ! ui_colors; then ui_log "$ui_level" "$(t "$ui_key" "$@")"; return; fi
    ui_marker_style "$ui_level"
    for ui_arg in "$@"; do ui_args+=($'\033[1;36m'"$ui_arg"$'\033['"${UI_BODY}m"); done
    ui_text=$(t "$ui_key" "${ui_args[@]}")
    [[ $ui_level != success ]] || ui_text=${ui_text#✓ }
    ui_text=${ui_text//$'\n'/$'\n      '}
    printf '  \033[%sm[%s]\033[0m \033[%sm%s\033[0m\n' "$UI_TONE" "$UI_MARK" "$UI_BODY" "$ui_text" >&2
}
ui_notice() {
    local ui_text=$1
    [[ ${2:-info} != success ]] || ui_text=${ui_text#✓ }
    if ui_interactive; then UI_NOTICES+=("${2:-info}"$'\t'"$ui_text"); fi
}

# ---------------------------------------------------------------- layout
# Compact "smslant" figlet banner; shown on start-up and in help only.
ui_banner() {
    local ui_fd=${1:-2} ui_line
    local -a ui_art=(
        '  _______   ___  ____  ___           __'
        ' / ___/ /  / _ \/  _/ / _ \___  ____/ /_____ ____'
        '/ (_ / /__/ ___// /  / // / _ \/ __/  '"'"'_/ -_) __/'
        '\___/____/_/  /___/ /____/\___/\__/_/\_\\__/_/'
    )
    local ui_on=false
    if [[ $ui_fd == 1 ]]; then [[ -z ${NO_COLOR+x} && -t 1 && ${TERM:-dumb} != dumb ]] && ui_on=true
    else ui_colors && ui_on=true; fi
    ui_dimensions
    printf '\n' >&"$ui_fd"
    if (( UI_COLS >= 56 )); then
        for ui_line in "${ui_art[@]}"; do
            if [[ $ui_on == true ]]; then printf '  \033[1;35m%s\033[0m\n' "$ui_line" >&"$ui_fd"
            else printf '  %s\n' "$ui_line" >&"$ui_fd"; fi
        done
        if [[ $ui_on == true ]]; then printf '  \033[1;37mManager\033[0m \033[2mv%s · %s\033[0m\n\n' "$GDM_VERSION" "$(t ui_subtitle)" >&"$ui_fd"
        else printf '  Manager v%s · %s\n\n' "$GDM_VERSION" "$(t ui_subtitle)" >&"$ui_fd"; fi
    else
        if [[ $ui_on == true ]]; then printf '  \033[1;35mGLPI Docker Manager\033[0m \033[2mv%s\033[0m\n\n' "$GDM_VERSION" >&"$ui_fd"
        else printf '  GLPI Docker Manager v%s\n\n' "$GDM_VERSION" >&"$ui_fd"; fi
    fi
}
# Three-line page header: title, rule, blank line.
ui_header() {
    local ui_subtitle ui_rule
    ui_subtitle=" · $(t ui_subtitle)"
    (( 20+${#GDM_VERSION}+${#ui_subtitle} <= UI_WIDTH+4 )) || ui_subtitle=''
    printf '  ' >&2
    ui_color '1;35'; printf 'GLPI Docker Manager' >&2; ui_color 0
    ui_color 2; printf ' v%s%s' "$GDM_VERSION" "$ui_subtitle" >&2; ui_color 0
    printf -v ui_rule '%*s' "$((UI_WIDTH+4))" ''
    printf '\n  ' >&2; ui_color 35; printf '%s' "${ui_rule// /─}" >&2; ui_color 0
    printf '\n\n' >&2
}
ui_page() {
    UI_PAGE_LINES=0
    if ! ui_interactive; then return; fi
    ui_dimensions
    local ui_entry ui_part ui_first UI_DRAW_LINES=0
    printf '\033[2J\033[H' >&2
    ui_header
    UI_PAGE_LINES=3
    if (( ${#UI_CONTEXT[@]} > 0 )); then
        ui_box "${UI_CONTEXT[@]}"
        ((UI_PAGE_LINES+=UI_DRAW_LINES))
    fi
    for ui_entry in "${UI_NOTICES[@]}"; do
        ui_marker_style "${ui_entry%%$'\t'*}"
        ui_first=true
        while IFS= read -r ui_part; do
            if [[ $ui_first == true ]]; then
                printf '  ' >&2; ui_color "$UI_TONE"; printf '[%s]' "$UI_MARK" >&2; ui_color 0; printf ' ' >&2
                ui_first=false
            else printf '      ' >&2; fi
            ui_color "$UI_BODY"; printf '%s' "$ui_part" >&2; ui_color 0; printf '\n' >&2
            ((UI_PAGE_LINES+=1))
        done < <(ui_wrap "${ui_entry#*$'\t'}" "$UI_WIDTH")
    done
    if (( ${#UI_NOTICES[@]} > 0 )); then printf '\n' >&2; ((UI_PAGE_LINES+=1)); fi
    UI_CONTEXT=() UI_NOTICES=()
}
ui_border() {
    local ui_rule
    printf -v ui_rule '%*s' "$((UI_WIDTH+2))" ''
    ui_rule=${ui_rule// /─}
    printf '  %s%s%s\n' "$1" "$ui_rule" "$2" >&2
    ((UI_DRAW_LINES+=1))
}
ui_line() {
    local ui_text=${1:-} ui_style=${2:-} ui_padding
    ui_text=${ui_text:0:UI_WIDTH}
    ui_padding=$((UI_WIDTH-${#ui_text}))
    ui_color 35; printf '  │ ' >&2; ui_color 0
    [[ -z $ui_style ]] || ui_color "$ui_style"
    printf '%s%*s' "$ui_text" "$ui_padding" '' >&2
    [[ -z $ui_style ]] || ui_color 0
    ui_color 35; printf ' │\n' >&2; ui_color 0
    ((UI_DRAW_LINES+=1))
}
# "label<TAB>value" rows. The label column fits the longest label of the card
# (UI_PAIR_COLUMN, set by ui_box); padding counts characters, not bytes, so
# accented labels never push values or the right border out of line.
ui_pair() {
    local ui_label=$1 ui_value=$2 ui_column=${UI_PAIR_COLUMN:-24} ui_gap ui_padding
    if ((UI_WIDTH < 40)); then ui_line "$ui_label" 2; ui_line "$ui_value" '1;36'; return; fi
    ui_label=${ui_label:0:ui_column-2}
    ui_gap=$((ui_column-${#ui_label}))
    ui_value=${ui_value:0:UI_WIDTH-ui_column}
    ui_padding=$((UI_WIDTH-ui_column-${#ui_value}))
    ui_color 35; printf '  │ ' >&2; ui_color 0
    ui_color 2; printf '%s%*s' "$ui_label" "$ui_gap" '' >&2; ui_color 0
    ui_color '1;36'; printf '%s' "$ui_value" >&2; ui_color 0
    printf '%*s' "$ui_padding" '' >&2
    ui_color 35; printf ' │\n' >&2; ui_color 0
    ((UI_DRAW_LINES+=1))
}
# A titled information card. Titles starting with ✓ become green success cards.
# Rows: plain text (wrapped), "label<TAB>value" pairs, "§Section" headings.
ui_box() {
    local ui_title=$1; shift
    local ui_text ui_part ui_label ui_tone=35 ui_mark='[*]' ui_longest=0 UI_PAIR_COLUMN ui_first=true
    UI_DRAW_LINES=0
    if [[ $ui_title == '✓'* ]]; then ui_tone=32 ui_mark='[+]'; fi
    while [[ $ui_title == '✓ '* ]]; do ui_title=${ui_title#✓ }; done
    for ui_text in "$@"; do
        [[ $ui_text == *$'\t'* ]] || continue
        ui_label=${ui_text%%$'\t'*}
        (( ${#ui_label} <= ui_longest )) || ui_longest=${#ui_label}
    done
    UI_PAIR_COLUMN=$((ui_longest+3))
    (( UI_PAIR_COLUMN <= UI_WIDTH/2 )) || UI_PAIR_COLUMN=$((UI_WIDTH/2))
    (( UI_PAIR_COLUMN >= 12 )) || UI_PAIR_COLUMN=12
    ui_color "$ui_tone"; ui_border ╭ ╮; ui_color 0
    ui_line "$ui_mark $ui_title" "1;$ui_tone"
    for ui_text in "$@"; do
        if [[ $ui_text == '§'* ]]; then
            ui_line
            ui_line "${ui_text#§}" '1;35'
            ui_first=false
            continue
        fi
        if [[ $ui_first == true ]]; then ui_line; ui_first=false; fi
        if [[ $ui_text == *$'\t'* ]]; then ui_pair "${ui_text%%$'\t'*}" "${ui_text#*$'\t'}"
        else while IFS= read -r ui_part; do ui_line "$ui_part"; done < <(ui_wrap "$ui_text" "$UI_WIDTH"); fi
    done
    ui_color "$ui_tone"; ui_border ╰ ╯; ui_color 0
    printf '\n' >&2
    ((UI_DRAW_LINES+=1))
}
# The card and pending notices stay as context for the next page, so a prompt
# that follows keeps both on screen instead of erasing the notices.
ui_panel() {
    local UI_DRAW_LINES=0
    local -a ui_carried=()
    ui_dimensions
    if ! ui_interactive; then ui_box "$@"; return; fi
    ui_carried=("${UI_NOTICES[@]}")
    UI_CONTEXT=("$@")
    ui_page
    UI_CONTEXT=("$@") UI_NOTICES=("${ui_carried[@]}")
}
# A question heading: "[?] text" with aligned continuation lines.
ui_question() {
    local ui_part ui_first=true
    while IFS= read -r ui_part; do
        if [[ $ui_first == true ]]; then
            printf '  ' >&2; ui_color '1;35'; printf '[?]' >&2; ui_color 0; printf ' ' >&2; ui_first=false
        else printf '      ' >&2; fi
        ui_color 1; printf '%s' "$ui_part" >&2; ui_color 0; printf '\033[K\n' >&2
        ((UI_DRAW_LINES+=1))
    done < <(ui_wrap "$1" "$((UI_WIDTH-2))")
}
ui_field() {
    local ui_key=$1 ui_default=${2:-} UI_DRAW_LINES=0
    if ui_interactive; then
        ui_question "$(t "$ui_key")"
        if [[ -n $ui_default ]]; then printf '      ' >&2; ui_color 2; printf '%s' "$(t ui_default_value "$ui_default")" >&2; ui_color 0; printf '\n' >&2; fi
        printf '      ' >&2; ui_color 2; printf '%s' "$(t ui_field_keys)" >&2; ui_color 0; printf '\n\n' >&2
        if [[ ${3:-input} == input ]]; then printf '  ' >&2; ui_color '1;36'; printf '> ' >&2; ui_color 0; fi
    else
        t "$ui_key" >&2
        [[ -z $ui_default ]] || printf '[%s] ' "$ui_default" >&2
        printf '> ' >&2
    fi
}

# ---------------------------------------------------------------- input
# Raw single-line editor for every Bash text prompt. No readline: Tab never
# lists files and Esc always cancels (returns 1), like every other screen.
# Keys: ←/→, Home/End, Backspace/Delete, Ctrl+A/E/U; Enter accepts.
ui_read_line() {
    local ui_out=$1 ui_prefix=${2:-'> '} ui_tone=${3:-'1;36'} ui_text='' ui_char ui_next ui_seq
    local ui_pos=0 ui_start=0 ui_room ui_shown ui_cursor
    UI_TTY_STATE=$(stty -g)
    stty -echo -icanon min 1 time 0
    UI_ACTIVE=true
    while :; do
        ui_dimensions
        ui_room=$((UI_COLS-${#ui_prefix}-6)); ((ui_room >= 4)) || ui_room=4
        ((ui_pos >= ui_start)) || ui_start=$ui_pos
        ((ui_pos < ui_start+ui_room)) || ui_start=$((ui_pos-ui_room+1))
        ui_shown=${ui_text:ui_start:ui_room}
        printf '\r\033[2K  ' >&2; ui_color "$ui_tone"; printf '%s' "$ui_prefix" >&2; ui_color 0
        printf '%s' "$ui_shown" >&2
        ui_cursor=$((${#ui_shown}-(ui_pos-ui_start)))
        ((ui_cursor <= 0)) || printf '\033[%sD' "$ui_cursor" >&2
        if ! IFS= read -rsn 1 ui_char; then ui_restore; return 1; fi
        case $ui_char in
            '')
                ui_restore; printf '\n' >&2
                printf -v "$ui_out" '%s' "$ui_text"
                return 0;;
            $'\004') ui_restore; printf '\n' >&2; return 1;;
            $'\t') ;;
            $'\177'|$'\b')
                if ((ui_pos > 0)); then ui_text=${ui_text:0:ui_pos-1}${ui_text:ui_pos}; ((ui_pos-=1)) || true; fi;;
            $'\025') ui_text=''; ui_pos=0; ui_start=0;;
            $'\001') ui_pos=0;;
            $'\005') ui_pos=${#ui_text};;
            $'\e')
                # A lone Esc (nothing follows quickly) cancels the prompt.
                if ! IFS= read -rsn 1 -t 0.1 ui_next; then ui_restore; printf '\n' >&2; return 1; fi
                [[ $ui_next == '[' || $ui_next == O ]] || continue
                IFS= read -rsn 1 -t 0.1 ui_seq || continue
                case $ui_seq in
                    D) if ((ui_pos > 0)); then ((ui_pos-=1)) || true; fi;;
                    C) ((ui_pos >= ${#ui_text})) || ((ui_pos+=1));;
                    H) ui_pos=0;; F) ui_pos=${#ui_text};;
                    1|3|4|7|8)
                        IFS= read -rsn 1 -t 0.1 ui_next || continue
                        [[ $ui_next == '~' ]] || continue
                        case $ui_seq in
                            1|7) ui_pos=0;; 4|8) ui_pos=${#ui_text};;
                            3) ui_text=${ui_text:0:ui_pos}${ui_text:ui_pos+1};;
                        esac;;
                esac;;
            *)
                [[ $ui_char != *[$'\001'-$'\037'$'\177']* ]] || continue
                ui_text=${ui_text:0:ui_pos}$ui_char${ui_text:ui_pos}; ((ui_pos+=1));;
        esac
    done
}
# Keep password editing in Bash: Tab changes visibility without losing input.
# The line is erased on submission and secrets are never put in UI_CONTEXT.
ui_secret_read() {
    local ui_out=$1 ui_label=$2 ui_secret='' ui_char ui_next ui_seq ui_pos=0 ui_start=0
    local ui_display ui_shown ui_marker ui_room ui_cursor
    ui_page
    if ! ui_interactive; then
        t "$ui_label" >&2; t password_prompt >&2
        if [[ $UI_SECRET_VISIBILITY == hidden ]]; then IFS= read -rs ui_secret || return 1
        else IFS= read -er ui_secret || return 1; fi
        printf '\n' >&2
        printf -v "$ui_out" '%s' "$ui_secret"
        return
    fi
    UI_TTY_STATE=$(stty -g)
    stty -echo -icanon min 1 time 0
    UI_ACTIVE=true
    UI_SECRET_ACTIVE=true
    ui_field "$ui_label" '' title
    printf '  %s\n  ' "$(t password_prompt)" >&2
    ui_color 2; printf '%s' "$(t ui_password_keys)" >&2; ui_color 0
    printf '\n\n' >&2
    while :; do
        ui_dimensions
        ui_marker=$(t "ui_password_$UI_SECRET_VISIBILITY")
        ui_room=$((UI_COLS-${#ui_marker}-10)); ((ui_room >= 4)) || ui_room=4
        ((ui_pos >= ui_start)) || ui_start=$ui_pos
        ((ui_pos < ui_start+ui_room)) || ui_start=$((ui_pos-ui_room+1))
        ui_display=$ui_secret
        if [[ $UI_SECRET_VISIBILITY == hidden ]]; then
            printf -v ui_display '%*s' "${#ui_secret}" ''; ui_display=${ui_display// /*}
        fi
        ui_shown=${ui_display:ui_start:ui_room}
        printf '\r\033[2K  ' >&2; ui_color '1;36'
        printf '[%s] > ' "$ui_marker" >&2; ui_color 0
        printf '%s' "$ui_shown" >&2
        ui_cursor=$((${#ui_shown}-(ui_pos-ui_start)))
        ((ui_cursor <= 0)) || printf '\033[%sD' "$ui_cursor" >&2
        if ! IFS= read -rsn 1 ui_char; then ui_restore; return 1; fi
        case $ui_char in
            '')
                printf '\r\033[2K' >&2
                UI_SECRET_ACTIVE=false
                ui_restore
                printf -v "$ui_out" '%s' "$ui_secret"
                return;;
            $'\t')
                if [[ $UI_SECRET_VISIBILITY == visible ]]; then UI_SECRET_VISIBILITY=hidden
                else UI_SECRET_VISIBILITY=visible; fi;;
            $'\177'|$'\b')
                if ((ui_pos > 0)); then ui_secret=${ui_secret:0:ui_pos-1}${ui_secret:ui_pos}; ((ui_pos-=1)) || true; fi;;
            $'\025') ui_secret=''; ui_pos=0; ui_start=0;;
            $'\001') ui_pos=0;;
            $'\005') ui_pos=${#ui_secret};;
            $'\004') ui_restore; return 1;;
            $'\e')
                if ! IFS= read -rsn 1 -t 0.2 ui_next; then ui_restore; return 1; fi
                [[ $ui_next == '[' || $ui_next == O ]] || continue
                IFS= read -rsn 1 -t 0.2 ui_seq || continue
                case $ui_seq in
                    D) if ((ui_pos > 0)); then ((ui_pos-=1)) || true; fi;;
                    C) ((ui_pos >= ${#ui_secret})) || ((ui_pos+=1));;
                    H) ui_pos=0;; F) ui_pos=${#ui_secret};;
                    1|3|4|7|8)
                        IFS= read -rsn 1 -t 0.2 ui_next || continue
                        [[ $ui_next == '~' ]] || continue
                        case $ui_seq in
                            1|7) ui_pos=0;; 4|8) ui_pos=${#ui_secret};;
                            3) ui_secret=${ui_secret:0:ui_pos}${ui_secret:ui_pos+1};;
                        esac;;
                esac;;
            *)
                [[ $ui_char != *[$'\001'-$'\037'$'\177']* ]] || continue
                ui_secret=${ui_secret:0:ui_pos}$ui_char${ui_secret:ui_pos}; ((ui_pos+=1));;
        esac
    done
}
ui_stop_spinner() {
    if [[ -n $UI_SPINNER_PID ]]; then
        kill "$UI_SPINNER_PID" 2>/dev/null || true
        wait "$UI_SPINNER_PID" 2>/dev/null || true
        UI_SPINNER_PID=''
        printf '\r\033[2K' >&2
    fi
    if [[ -n $UI_STATUS_FILE ]]; then rm -f -- "$UI_STATUS_FILE" 2>/dev/null || true; UI_STATUS_FILE=''; fi
}
ui_restore() {
    ui_stop_spinner
    if [[ $UI_SECRET_ACTIVE == true ]]; then
        printf '\r\033[2K' >&2
        UI_SECRET_ACTIVE=false
    fi
    if [[ -n $UI_TTY_STATE ]]; then
        stty "$UI_TTY_STATE" 2>/dev/null || true
        UI_TTY_STATE=''
    fi
    if [[ $UI_CURSOR_HIDDEN == true ]]; then printf '\033[?25h' >&2; UI_CURSOR_HIDDEN=false; fi
    UI_ACTIVE=false
}
# Option kinds make the consequence of each choice visible before Enter:
#   primary ▶ recommended · ok ● safe · warn ▲ restarts/risk · danger ✖ destroys
#   back ← cancel/return. A label is "KIND::text" plus an optional "\thelp"
#   line shown under the list while that option is highlighted (ui_opt builds it).
ui_opt() {
    [[ -z $1 ]] || printf '%s::' "$1"
    printf '%s%s' "$2" "${3:+$'\t'$3}"
}
ui_kind_style() {
    case $1 in
        primary) UI_GLYPH='▶' UI_KIND_TONE='1;36' UI_BAR='1;37;44';;
        ok) UI_GLYPH='●' UI_KIND_TONE='32' UI_BAR='1;37;44';;
        warn) UI_GLYPH='▲' UI_KIND_TONE='33' UI_BAR='1;30;43';;
        danger) UI_GLYPH='✖' UI_KIND_TONE='1;31' UI_BAR='1;37;41';;
        back) UI_GLYPH='←' UI_KIND_TONE='2' UI_BAR='1;37;44';;
        *) UI_GLYPH='·' UI_KIND_TONE='' UI_BAR='1;37;44';;
    esac
}
ui_draw_choices() {
    # Arrays and drawing state are scoped by choose; Bash dynamic scope avoids
    # evaluating input or transporting selected values through terminal output.
    local ui_i ui_last ui_label ui_keys ui_part ui_count UI_DRAW_LINES=0
    ui_question "$ui_title"
    printf '\033[K\n' >&2; ((UI_DRAW_LINES+=1))
    ui_last=$((ui_offset+ui_visible))
    (( ui_last <= ${#ui_values[@]} )) || ui_last=${#ui_values[@]}
    for (( ui_i=ui_offset; ui_i<ui_last; ui_i++ )); do
        ui_label=${ui_labels[ui_i]:0:UI_WIDTH-4}
        ui_kind_style "${ui_kinds[ui_i]}"
        if (( ui_i == ui_selected )); then
            printf '  ' >&2; ui_color "$UI_BAR"
            printf '> %s %s%*s' "$UI_GLYPH" "$ui_label" "$((UI_WIDTH-2-${#ui_label}))" '' >&2; ui_color 0
        else
            printf '    ' >&2
            [[ -z $UI_KIND_TONE ]] || ui_color "$UI_KIND_TONE"
            printf '%s %s' "$UI_GLYPH" "$ui_label" >&2
            [[ -z $UI_KIND_TONE ]] || ui_color 0
        fi
        printf '\033[K\n' >&2; ((UI_DRAW_LINES+=1))
    done
    printf '\033[K\n' >&2; ((UI_DRAW_LINES+=1))
    if (( ui_help_lines > 0 )); then
        # Fixed height: exactly two description lines, so redraws stay aligned.
        ui_kind_style "${ui_kinds[ui_selected]}"
        ui_count=0
        while IFS= read -r ui_part && (( ui_count < 2 )); do
            if (( ui_count == 0 )); then printf '  ' >&2; ui_color 2; printf '[*] ' >&2; ui_color 0
            else printf '      ' >&2; fi
            [[ -z $UI_KIND_TONE || ${ui_kinds[ui_selected]} == back ]] && ui_color 0 || ui_color "${UI_KIND_TONE#1;}"
            printf '%s' "$ui_part" >&2; ui_color 0; printf '\033[K\n' >&2
            ((ui_count+=1)); ((UI_DRAW_LINES+=1))
        done < <(ui_wrap "${ui_helps[ui_selected]:- }" "$((UI_WIDTH-4))")
        while (( ui_count < 2 )); do printf '\033[K\n' >&2; ((ui_count+=1)); ((UI_DRAW_LINES+=1)); done
        printf '\033[K\n' >&2; ((UI_DRAW_LINES+=1))
    fi
    if (( UI_WIDTH < 50 )); then ui_keys=$(t ui_keys_short); else ui_keys=$(t ui_keys); fi
    printf '  ' >&2; ui_color 2; printf '%s · %s/%s' "$ui_keys" "$((ui_selected+1))" "${#ui_values[@]}" >&2; ui_color 0
    printf '\033[K\n' >&2; ((UI_DRAW_LINES+=1))
    ui_drawn=$UI_DRAW_LINES
}
choose() {
    local ui_out=$1 ui_key=$2 ui_default=$3; shift 3
    local -a ui_values=() ui_labels=() ui_kinds=() ui_helps=()
    local ui_i ui_selected=0 ui_offset=0 ui_visible ui_drawn=0 ui_keypress ui_next ui_sequence ui_search=''
    local ui_reply ui_match ui_title ui_previous_cols=0 ui_question_lines ui_label ui_kind ui_help ui_help_lines=0
    [[ -t 0 ]] || die interactive_required
    while (( $# >= 2 )); do
        ui_label=$2 ui_kind='' ui_help=''
        if [[ $ui_label =~ ^(primary|ok|warn|danger|back)::(.*)$ ]]; then ui_kind=${BASH_REMATCH[1]} ui_label=${BASH_REMATCH[2]}; fi
        if [[ $ui_label == *$'\t'* ]]; then ui_help=${ui_label#*$'\t'} ui_label=${ui_label%%$'\t'*}; fi
        [[ -z $ui_help ]] || ui_help_lines=3
        ui_values+=("$1"); ui_labels+=("$ui_label"); ui_kinds+=("$ui_kind"); ui_helps+=("$ui_help")
        shift 2
    done
    (( ${#ui_values[@]} > 0 )) || return 1
    for ui_i in "${!ui_values[@]}"; do [[ ${ui_values[ui_i]} != "$ui_default" ]] || ui_selected=$ui_i; done
    ui_title=$(t "$ui_key")
    # Older locale suffixes are no longer needed beside selectable Yes/No rows.
    ui_title=${ui_title% \[*\]}
    ui_dimensions
    if ! ui_interactive || (( UI_COLS < 36 || UI_ROWS < 16 )); then
        while :; do
            printf '\n%s\n' "$ui_title" >&2
            for ui_i in "${!ui_values[@]}"; do
                ui_kind_style "${ui_kinds[ui_i]}"
                printf '  %s) %s %s\n' "$((ui_i+1))" "$UI_GLYPH" "${ui_labels[ui_i]}" >&2
                [[ -z ${ui_helps[ui_i]} ]] || printf '       %s\n' "${ui_helps[ui_i]}" >&2
            done
            printf '%s\n' "$(t ui_plain_keys)" >&2
            printf '[%s] ' "$((ui_selected+1))" >&2
            IFS= read -r ui_reply || return 1
            [[ -n $ui_reply ]] || ui_reply=${ui_values[ui_selected]}
            ui_match=-1
            for ui_i in "${!ui_values[@]}"; do
                if [[ ${ui_values[ui_i],,} == "${ui_reply,,}" ]]; then ui_match=$ui_i; break; fi
                if [[ ${ui_values[ui_i]} == yes && ${ui_reply,,} =~ ^(y|s|si|sí)$ ]]; then ui_match=$ui_i; break; fi
                if [[ ${ui_values[ui_i]} == no && ${ui_reply,,} == n ]]; then ui_match=$ui_i; break; fi
            done
            if (( ui_match < 0 )) && [[ $ui_reply =~ ^[1-9][0-9]?$ ]] && (( ui_reply <= ${#ui_values[@]} )); then ui_match=$((ui_reply-1)); fi
            if (( ui_match >= 0 )); then printf -v "$ui_out" '%s' "${ui_values[ui_match]}"; return; fi
            say ui_invalid_choice
        done
    fi
    ui_page
    UI_TTY_STATE=$(stty -g)
    stty -echo -icanon min 1 time 0
    UI_ACTIVE=true UI_CURSOR_HIDDEN=true
    printf '\033[?25l' >&2
    while :; do
        ui_dimensions
        if (( ui_drawn > 0 && UI_COLS == ui_previous_cols )); then printf '\033[%sA' "$ui_drawn" >&2
        else ui_question_lines=$(ui_wrap "$ui_title" "$((UI_WIDTH-2))" | wc -l); fi
        ui_previous_cols=$UI_COLS
        ui_visible=$((UI_ROWS-ui_question_lines-4-UI_PAGE_LINES-ui_help_lines))
        (( ui_visible <= 10 )) || ui_visible=10
        (( ui_visible >= 1 )) || ui_visible=1
        (( ui_selected >= ui_offset )) || ui_offset=$ui_selected
        (( ui_selected < ui_offset+ui_visible )) || ui_offset=$((ui_selected-ui_visible+1))
        ui_draw_choices
        if ! IFS= read -rsn 1 ui_keypress; then ui_restore; return 1; fi
        case $ui_keypress in
            $'\004') ui_restore; return 1;;
            '')
                ui_restore
                printf -v "$ui_out" '%s' "${ui_values[ui_selected]}"
                return;;
            $'\e')
                if ! IFS= read -rsn 1 -t 0.2 ui_next; then ui_restore; return 1; fi
                [[ $ui_next == '[' || $ui_next == O ]] || continue
                IFS= read -rsn 1 -t 0.2 ui_sequence || continue
                case $ui_sequence in
                    A|Z) ui_selected=$(((ui_selected+${#ui_values[@]}-1)%${#ui_values[@]}));;
                    B) ui_selected=$(((ui_selected+1)%${#ui_values[@]}));;
                    H) ui_selected=0;; F) ui_selected=$((${#ui_values[@]}-1));;
                    1|4|5|6|7|8)
                        IFS= read -rsn 1 -t 0.2 ui_next || continue
                        [[ $ui_next == '~' ]] || continue
                        case $ui_sequence in
                            1|7) ui_selected=0;; 4|8) ui_selected=$((${#ui_values[@]}-1));;
                            5) ui_selected=$((ui_selected-ui_visible)); (( ui_selected >= 0 )) || ui_selected=0;;
                            6) ui_selected=$((ui_selected+ui_visible)); (( ui_selected < ${#ui_values[@]} )) || ui_selected=$((${#ui_values[@]}-1));;
                        esac;;
                esac
                ui_search='';;
            $'\t') ui_selected=$(((ui_selected+1)%${#ui_values[@]})); ui_search='';;
            $'\177'|$'\b') ui_search='';;
            *)
                ui_search+="${ui_keypress,,}"
                for ui_i in "${!ui_values[@]}"; do
                    if [[ ${ui_values[ui_i],,} == "$ui_search"* || ${ui_labels[ui_i],,} == "$ui_search"* ]]; then ui_selected=$ui_i; break; fi
                    if [[ ${ui_values[ui_i]} == yes && $ui_search =~ ^(y|s|si|sí)$ ]]; then ui_selected=$ui_i; break; fi
                    if [[ ${ui_values[ui_i]} == no && $ui_search == n ]]; then ui_selected=$ui_i; break; fi
                done;;
        esac
    done
}
choose_language() {
    local ui_language
    choose ui_language language_prompt "$LANGUAGE" en English es Español || return 1
    LANGUAGE=$ui_language
    tr_load
}
ask_value() {
    local ui_out=$1 ui_prompt=$2 ui_default=$3 ui_kind=$4 ui_input_value ui_valid
    while :; do
        ask ui_input_value "$ui_prompt" "$ui_default" || return 1
        ui_valid=false
        case $ui_kind in
            port) [[ $ui_input_value =~ ^[0-9]{1,5}$ ]] && (( 10#$ui_input_value >= 1 && 10#$ui_input_value <= 65535 )) && ui_valid=true;;
            identifier|db-user)
                if [[ $ui_input_value =~ ^[a-zA-Z][a-zA-Z0-9_]{0,31}$ ]]; then
                    [[ $ui_kind == db-user && $ui_input_value == root ]] || ui_valid=true
                fi;;
            timezone) [[ $ui_input_value != *..* && $ui_input_value =~ ^[A-Za-z0-9_+/-]+$ && -f /usr/share/zoneinfo/$ui_input_value ]] && ui_valid=true;;
            hostname) [[ $ui_input_value =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] && ui_valid=true;;
            days) [[ $ui_input_value =~ ^[0-9]{1,2}$ ]] && (( 10#$ui_input_value >= 1 && 10#$ui_input_value <= 30 )) && ui_valid=true;;
        esac
        if [[ $ui_valid == true ]]; then
            [[ $ui_kind != port && $ui_kind != days ]] || ui_input_value=$((10#$ui_input_value))
            printf -v "$ui_out" '%s' "$ui_input_value"
            return
        fi
        say "ui_bad_$ui_kind"
    done
}

# ---------------------------------------------------------------- progress
ui_clock() { printf -v "$1" '%02d:%02d' "$(($2/60))" "$(($2%60))"; }
# "[+] text · 00:12" once a stage has completed.
ui_done_line() {
    printf '  ' >&2; ui_color '1;32'; printf '[+]' >&2; ui_color 0
    printf ' %s ' "$1" >&2; ui_color 2; printf '· %s' "$2" >&2; ui_color 0; printf '\n' >&2
}
# pwntools-like progress line, redrawn in place: "[⠹] text · 00:12 · status".
# The status comes only from ui_status (trusted text), never from command logs.
ui_spinner_start() {
    local ui_text=$1
    UI_CURSOR_HIDDEN=true
    printf '\033[?25l' >&2
    (
        trap - EXIT ERR
        trap 'exit 0' TERM INT
        local ui_i=0 ui_started=$SECONDS ui_elapsed ui_status ui_head ui_tail ui_room ui_clock_text ui_on=false
        local -a ui_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        [[ -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]] && ui_on=true
        while :; do
            ui_elapsed=$((SECONDS-ui_started))
            ui_clock ui_clock_text "$ui_elapsed"
            ui_status=''
            [[ ! -r $UI_STATUS_FILE ]] || { IFS= read -r ui_status < "$UI_STATUS_FILE" || :; }
            ui_head=" $ui_text"
            ui_tail=" · $ui_clock_text${ui_status:+ · $ui_status}"
            ui_room=$((UI_COLS-8-${#ui_head}))
            if (( ui_room < 9 )); then ui_head=${ui_head:0:UI_COLS-17}; ui_room=8; fi
            ui_tail=${ui_tail:0:ui_room}
            if [[ $ui_on == true ]]; then
                printf '\r\033[2K  \033[1;34m[%s]\033[0m%s\033[2m%s\033[0m' "${ui_frames[ui_i]}" "$ui_head" "$ui_tail" >&"$UI_PROGRESS_FD"
            else printf '\r\033[2K  [%s]%s%s' "${ui_frames[ui_i]}" "$ui_head" "$ui_tail" >&"$UI_PROGRESS_FD"; fi
            ui_i=$(((ui_i+1)%${#ui_frames[@]}))
            sleep 0.1 || exit 0
        done
    ) 2>> "$UI_LAST_LOG" &
    UI_SPINNER_PID=$!
}
# Runs "$@" in this shell (errexit and shared state keep working) with output
# captured in a private log. Interactive terminals see a spinner instead.
ui_exec() {
    local ui_text=$1 ui_tag=$2; shift 2
    local ui_started=$SECONDS
    UI_CURRENT_STEP=$ui_text
    if ui_interactive; then
        ui_dimensions
        mkdir -p "$STATE/logs"
        UI_LAST_LOG=$(mktemp "$STATE/logs/install-$(date -u +%Y%m%dT%H%M%S)-$ui_tag-XXXXXX.log")
        UI_STATUS_FILE="$UI_LAST_LOG.status"
        : > "$UI_STATUS_FILE"
        exec {UI_PROGRESS_FD}>&2
        ui_spinner_start "$ui_text"
        # This call stays outside if/|| contexts so errexit remains effective
        # inside lifecycle functions; shared state remains in this shell.
        "$@" > "$UI_LAST_LOG" 2>&1
        ui_stop_spinner
        exec {UI_PROGRESS_FD}>&-
        UI_PROGRESS_FD=''
        if [[ $UI_CURSOR_HIDDEN == true ]]; then printf '\033[?25h' >&2; UI_CURSOR_HIDDEN=false; fi
    else
        ui_log info "$ui_text"
        "$@"
    fi
    UI_LAST_LOG=''
    UI_CURRENT_STEP=''
    ui_clock UI_LAST_CLOCK "$((SECONDS-ui_started))"
    ui_done_line "$ui_text" "$UI_LAST_CLOCK"
}
# A numbered stage on its own page: STEP is "N/T", 0 (unnumbered) or N.
# The first stage of a sequence ("1/T", 1 or 0) clears the completed list.
ui_run() {
    local ui_step=$1 ui_label=$2; shift 2
    local ui_text ui_entry
    case $ui_step in 0|1|1/*) UI_STEP_LABELS=();; esac
    ui_text=$(t "$ui_label")
    [[ $ui_step == 0 ]] || ui_text="[$ui_step] $ui_text"
    if ui_interactive; then
        UI_CONTEXT=()
        ui_page
        for ui_entry in "${UI_STEP_LABELS[@]}"; do ui_done_line "${ui_entry%%$'\t'*}" "${ui_entry#*$'\t'}"; done
    fi
    ui_exec "$ui_text" "${ui_step//\//of}" "$@"
    UI_STEP_LABELS+=("$ui_text"$'\t'"$UI_LAST_CLOCK")
}
# An inline spinner for slow lookups that do not deserve their own page.
ui_task() {
    local ui_label=$1; shift
    ui_exec "$(t "$ui_label")" task "$@"
}
# Live detail for the running spinner (for example the image being pulled).
ui_status() {
    if [[ -n $UI_STATUS_FILE ]]; then printf '%s\n' "$*" > "$UI_STATUS_FILE" 2>/dev/null || true; fi
    printf '      · %s\n' "$*" >&2
}
ui_pause() {
    local ui_pause_input
    [[ -t 0 ]] || return 0
    printf '\n  ' >&2; ui_color 2; printf '%s' "$(t "${1:-ui_continue}")" >&2; ui_color 0
    if ui_interactive; then
        # Enter or Esc continue; arrow keys are swallowed silently.
        UI_TTY_STATE=$(stty -g)
        stty -echo -icanon min 1 time 0
        while IFS= read -rsn 1 ui_pause_input; do
            [[ -n $ui_pause_input && $ui_pause_input != $'\e' ]] || break
        done
        if [[ $ui_pause_input == $'\e' ]]; then IFS= read -rsn 8 -t 0.05 ui_pause_input || true; fi
        ui_restore
    else
        IFS= read -rs ui_pause_input || true
    fi
    printf '\n' >&2
}
ui_progress_note() {
    say "$@"
    if [[ -n ${UI_PROGRESS_FD:-} ]]; then
        printf '\r\033[2K' >&"$UI_PROGRESS_FD"
        ui_say info "$@" 2>&"$UI_PROGRESS_FD"
    fi
}

# ---------------------------------------------------------------- screens
ui_interrupted() {
    printf '\n\n  ' >&2; ui_color '1;31'; printf '[!] %s' "$(t ui_interrupted)" >&2; ui_color 0; printf '\n\n' >&2
}
ui_welcome() {
    [[ -t 2 ]] || return 0
    ! ui_interactive || printf '\033[2J\033[H' >&2
    ui_banner 2
}
# Help panel on stdout, grouped like the dashboard. Colours only on a terminal.
ui_help() {
    local on=false group entry name key
    [[ -z ${NO_COLOR+x} && -t 1 && ${TERM:-dumb} != dumb ]] && on=true
    ! [[ -t 1 ]] || ui_banner 1
    # "group_key;name=description_key;..." — names never contain ";" or "=".
    local -a groups=(
        "help_group_options;--lang en|es=help_opt_lang;--state-dir PATH=help_opt_state;-h, --help=help_opt_help;--version=help_opt_version"
        "help_group_service;status=menu_status;start=menu_start;stop=menu_stop;logs=menu_logs"
        "help_group_updates;install [x.y.z]=help_cmd_install;check-updates=menu_versions;update [x.y.z]=menu_update;migrate [x.y.z]=help_cmd_migrate;refresh-image=menu_refresh;db-update=menu_database_update"
        "help_group_data;backup=menu_backup;backups=menu_backups;restore [file]=menu_restore;schedule=menu_schedule;cleanup=menu_cleanup;transfer=menu_transfer"
        "help_group_settings;address=menu_address;https=menu_https;certificates=menu_certificates;db-exposure=menu_exposure;credentials=menu_credentials;language=menu_language"
        "help_group_manager;diagnose=menu_diagnose;recover=menu_recover;maintenance=help_cmd_maintenance;self-update=menu_self_update;uninstall=menu_uninstall;version=help_opt_version;help=help_opt_help"
    )
    local -a entries=()
    local out line yellow='' blue='' purple='' bold='' reset=''
    if [[ $on == true ]]; then
        yellow=$'\033[1;33m' blue=$'\033[1;34m' purple=$'\033[1;35m' bold=$'\033[1m' reset=$'\033[0m'
    fi
    # Built first and written once, so "start.sh help | grep -q" cannot break
    # the pipe halfway through the output.
    printf -v out '  %s[+]%s %s%s%s\n' "$yellow" "$reset" "$bold" "$(t help_usage)" "$reset"
    for group in "${groups[@]}"; do
        IFS=';' read -r -a entries <<< "$group"
        printf -v line '\n  %s[*]%s %s%s%s\n' "$blue" "$reset" "$bold" "$(t "${entries[0]}")" "$reset"; out+=$line
        for entry in "${entries[@]:1}"; do
            name=${entry%=*}; key=${entry##*=}
            printf -v line '      %s%-18s%s %s\n' "$purple" "$name" "$reset" "$(t "$key")"; out+=$line
        done
    done
    printf -v line '\n  %s[!]%s %s\n  %s[*]%s %s\n\n' "$yellow" "$reset" "$(t help_notes)" "$blue" "$reset" "$(t help_paths)"
    printf '%s' "$out$line"
}

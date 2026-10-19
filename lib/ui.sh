#!/usr/bin/env bash
# Native terminal controls keep the first screen usable before package bootstrap.
# shellcheck disable=SC2034
UI_TTY_STATE=''
UI_CURSOR_HIDDEN=false
UI_SPINNER_PID=''
UI_LAST_LOG=''
UI_PROGRESS_FD=''
UI_ACTIVE=false
UI_SECRET_ACTIVE=false
UI_SECRET_VISIBILITY=${GDM_PASSWORD_VISIBILITY:-visible}
[[ $UI_SECRET_VISIBILITY == hidden ]] || UI_SECRET_VISIBILITY=visible
UI_PAGE_LINES=0
declare -a UI_CONTEXT=() UI_NOTICES=() UI_STEP_LABELS=()

ui_interactive() { [[ -t 0 && -t 2 && ${TERM:-dumb} != dumb && ${GDM_UI:-auto} != plain ]] && command -v stty >/dev/null; }
ui_color() { if [[ -z ${NO_COLOR+x} && -t 2 && ${TERM:-dumb} != dumb ]]; then printf '\033[%sm' "$1" >&2; fi; }
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
ui_notice() {
    if ui_interactive; then UI_NOTICES+=("$1"); fi
}
ui_page() {
    UI_PAGE_LINES=0
    if ! ui_interactive; then return; fi
    ui_dimensions
    local ui_text ui_part UI_DRAW_LINES=0
    printf '\033[2J\033[H' >&2
    ui_color '1;35'; printf '  GLPI Docker Manager\n' >&2; ui_color 0
    ui_color 37; printf '  %s\n\n' "$(t ui_subtitle)" >&2; ui_color 0
    UI_PAGE_LINES=3
    if (( ${#UI_CONTEXT[@]} > 0 )); then
        ui_box "${UI_CONTEXT[@]}"
        ((UI_PAGE_LINES+=UI_DRAW_LINES))
    fi
    for ui_text in "${UI_NOTICES[@]}"; do
        while IFS= read -r ui_part; do
            ui_color '1;37'; printf '  %s\n' "$ui_part" >&2; ui_color 0
            ((UI_PAGE_LINES+=1))
        done < <(ui_wrap "$ui_text" "$UI_WIDTH")
    done
    if (( ${#UI_NOTICES[@]} > 0 )); then printf '\n' >&2; ((UI_PAGE_LINES+=1)); fi
    UI_CONTEXT=() UI_NOTICES=()
}
ui_field() {
    local ui_key=$1 ui_default=${2:-} ui_part UI_DRAW_LINES=0
    if ui_interactive; then
        ui_color 35; ui_border ╭ ╮; ui_color 0
        while IFS= read -r ui_part; do ui_line "$ui_part" '1;36'; done < <(ui_wrap "$(t "$ui_key")" "$UI_WIDTH")
        [[ -z $ui_default ]] || ui_line "$(t ui_default_value "$ui_default")" '2'
        ui_color 35; ui_border ╰ ╯; ui_color 0
        if [[ ${3:-input} == input ]]; then ui_color '1;36'; printf '  > ' >&2; ui_color 0; fi
    else
        t "$ui_key" >&2
        [[ -z $ui_default ]] || printf '[%s] ' "$ui_default" >&2
        printf '> ' >&2
    fi
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
    printf '  %s\n  %s\n\n' "$(t password_prompt)" "$(t ui_password_keys)" >&2
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
    printf '  │ ' >&2
    [[ -z $ui_style ]] || ui_color "$ui_style"
    printf '%s%*s' "$ui_text" "$ui_padding" '' >&2
    [[ -z $ui_style ]] || ui_color 0
    printf ' │\n' >&2
    ((UI_DRAW_LINES+=1))
}
ui_pair() {
    local ui_label=$1 ui_value=$2 ui_column=24 ui_padding
    if ((UI_WIDTH < 40)); then ui_line "$ui_label" 2; ui_line "$ui_value" '1;36'; return; fi
    ui_value=${ui_value:0:UI_WIDTH-ui_column}
    ui_padding=$((UI_WIDTH-ui_column-${#ui_value}))
    printf '  │ %-*s' "$ui_column" "$ui_label" >&2
    ui_color '1;36'; printf '%s' "$ui_value" >&2; ui_color 0
    printf '%*s │\n' "$ui_padding" '' >&2
    ((UI_DRAW_LINES+=1))
}
ui_box() {
    local ui_title=$1; shift
    local ui_text ui_part ui_tone=35
    UI_DRAW_LINES=0
    [[ $ui_title != '✓'* ]] || ui_tone=32
    ui_color "$ui_tone"; ui_border ╭ ╮; ui_color 0
    ui_line "$ui_title" "1;$ui_tone"
    for ui_text in "$@"; do
        if [[ $ui_text == *$'\t'* ]]; then ui_pair "${ui_text%%$'\t'*}" "${ui_text#*$'\t'}"
        else while IFS= read -r ui_part; do ui_line "$ui_part"; done < <(ui_wrap "$ui_text" "$UI_WIDTH"); fi
    done
    ui_color "$ui_tone"; ui_border ╰ ╯; ui_color 0
    printf '\n' >&2
    ((UI_DRAW_LINES+=1))
}
ui_panel() {
    local UI_DRAW_LINES=0
    ui_dimensions
    UI_CONTEXT=()
    ui_page
    ui_box "$@"
    if ui_interactive; then UI_CONTEXT=("$@"); fi
}
ui_stop_spinner() {
    if [[ -n $UI_SPINNER_PID ]]; then
        kill "$UI_SPINNER_PID" 2>/dev/null || true
        wait "$UI_SPINNER_PID" 2>/dev/null || true
        UI_SPINNER_PID=''
        printf '\r\033[2K' >&2
    fi
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
ui_draw_choices() {
    # Arrays and drawing state are scoped by choose; Bash dynamic scope avoids
    # evaluating input or transporting selected values through terminal output.
    local ui_i ui_last ui_title_line UI_DRAW_LINES=0
    ui_color 35; ui_border ╭ ╮; ui_color 0
    for ui_title_line in "${ui_questions[@]}"; do ui_line "$ui_title_line" '1'; done
    ui_line
    ui_last=$((ui_offset+ui_visible))
    (( ui_last <= ${#ui_values[@]} )) || ui_last=${#ui_values[@]}
    for (( ui_i=ui_offset; ui_i<ui_last; ui_i++ )); do
        if (( ui_i == ui_selected )); then ui_line "> ${ui_labels[ui_i]}" '1;37;44'
        else ui_line "  ${ui_labels[ui_i]}"; fi
    done
    ui_line
    if (( UI_WIDTH < 50 )); then ui_line "$(t ui_keys_short)" '36'; else ui_line "$(t ui_keys)" '36'; fi
    ui_line "$((ui_selected+1)) / ${#ui_values[@]}" '37'
    ui_color 35; ui_border ╰ ╯; ui_color 0
    ui_drawn=$UI_DRAW_LINES
}
choose() {
    local ui_out=$1 ui_key=$2 ui_default=$3; shift 3
    local -a ui_values=() ui_labels=() ui_questions=()
    local ui_i ui_selected=0 ui_offset=0 ui_visible ui_drawn=0 ui_keypress ui_next ui_sequence ui_search=''
    local ui_reply ui_match ui_title ui_previous_cols=0
    [[ -t 0 ]] || die interactive_required
    while (( $# >= 2 )); do ui_values+=("$1"); ui_labels+=("$2"); shift 2; done
    (( ${#ui_values[@]} > 0 )) || return 1
    for ui_i in "${!ui_values[@]}"; do [[ ${ui_values[ui_i]} != "$ui_default" ]] || ui_selected=$ui_i; done
    ui_title=$(t "$ui_key")
    # Older locale suffixes are no longer needed beside selectable Yes/No rows.
    ui_title=${ui_title% \[*\]}
    ui_dimensions
    if ! ui_interactive || (( UI_COLS < 36 || UI_ROWS < 16 )); then
        while :; do
            printf '\n%s\n' "$ui_title" >&2
            for ui_i in "${!ui_values[@]}"; do printf '  %s) %s\n' "$((ui_i+1))" "${ui_labels[ui_i]}" >&2; done
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
        if (( ui_drawn > 0 && UI_COLS == ui_previous_cols )); then printf '\033[%sA' "$ui_drawn" >&2; fi
        ui_previous_cols=$UI_COLS
        mapfile -t ui_questions < <(ui_wrap "$ui_title" "$UI_WIDTH")
        ui_visible=$((UI_ROWS-${#ui_questions[@]}-7-UI_PAGE_LINES))
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
        esac
        if [[ $ui_valid == true ]]; then
            [[ $ui_kind != port ]] || ui_input_value=$((10#$ui_input_value))
            printf -v "$ui_out" '%s' "$ui_input_value"
            return
        fi
        say "ui_bad_$ui_kind"
    done
}
ui_run() {
    local ui_step=$1 ui_label=$2; shift 2
    local ui_previous
    if ui_interactive; then
        [[ $ui_step != 1 && $ui_step != 0 ]] || UI_STEP_LABELS=()
        UI_CONTEXT=()
        ui_page
        for ui_previous in "${UI_STEP_LABELS[@]}"; do
            ui_color 32; printf '  ✓ %s\n' "$ui_previous" >&2; ui_color 0
        done
    fi
    printf '\n' >&2
    ui_color '1;36'
    if [[ $ui_step == 0 ]]; then printf '  %s\n' "$(t "$ui_label")" >&2
    else printf '  [%s/8] %s\n' "$ui_step" "$(t "$ui_label")" >&2; fi
    ui_color 0
    if ui_interactive; then
        mkdir -p "$STATE/logs"
        UI_LAST_LOG=$(mktemp "$STATE/logs/install-$(date -u +%Y%m%dT%H%M%S)-$ui_step-XXXXXX.log")
        exec {UI_PROGRESS_FD}>&2
        (
            trap - EXIT ERR
            trap 'exit 0' TERM INT
            local ui_frame ui_started=$SECONDS ui_elapsed
            while :; do
                for ui_frame in '◐' '◓' '◑' '◒'; do
                    ui_elapsed=$((SECONDS-ui_started))
                    printf '\r  %s %s · %02d:%02d' "$ui_frame" "$(t ui_working)" "$((ui_elapsed/60))" "$((ui_elapsed%60))" >&"$UI_PROGRESS_FD"
                    sleep 0.2 || exit 0
                done
            done
        ) 2>> "$UI_LAST_LOG" &
        UI_SPINNER_PID=$!
        # This call stays outside if/|| contexts so errexit remains effective
        # inside lifecycle functions; shared state remains in this shell.
        "$@" > "$UI_LAST_LOG" 2>&1
        ui_stop_spinner
        exec {UI_PROGRESS_FD}>&-
        UI_PROGRESS_FD=''
    else "$@"; fi
    UI_LAST_LOG=''
    UI_STEP_LABELS+=("$(t "$ui_label")")
    ui_color 32; printf '  ✓ %s\n' "$(t ui_step_done)" >&2; ui_color 0
}
ui_pause() {
    local ui_pause_input
    [[ -t 0 ]] || return 0
    printf '\n%s' "$(t "${1:-ui_continue}")" >&2
    IFS= read -r ui_pause_input || true
}
ui_progress_note() {
    say "$@"
    if [[ -n ${UI_PROGRESS_FD:-} ]]; then
        printf '\r\033[2K  %s\n' "$(t "$@")" >&"$UI_PROGRESS_FD"
    fi
}

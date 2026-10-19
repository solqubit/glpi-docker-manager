#!/usr/bin/env bash
# Shared state is consumed by other sourced modules.
# shellcheck disable=SC2034
# Translations are trusted repository files; configuration is never evaluated.
LANGUAGE=${GDM_LANG:-en}
LANGUAGE_OVERRIDE=${GDM_LANG:-}
STATE=${GDM_STATE_DIR:-/opt/glpi-docker-manager}
CERT_ROOT=${GDM_CERT_DIR:-$STATE/certs}
declare -A MSG=()
declare -a CLEANUP_PATHS=()
declare -a CLEANUP_DIRECTORIES=()
declare -a GDM_COMMAND_ARGS=()
GDM_STORAGE_FAILURE=false
GDM_VERSION=dev
if [[ -r $GDM_ROOT/VERSION ]]; then IFS= read -r GDM_VERSION < "$GDM_ROOT/VERSION" || :; fi

tr_load() {
    [[ $LANGUAGE == en || $LANGUAGE == es ]] || LANGUAGE=en
    local key value
    # Locale files use a literal tab between key and text. No eval or source.
    while IFS=$'\t' read -r key value; do
        [[ -n $key ]] && MSG["$key"]=$value
    done < "$GDM_ROOT/locales/$LANGUAGE.tsv"
}
t() {
    local key=$1; shift
    # Formats come exclusively from trusted locale files, never configuration.
    # shellcheck disable=SC2059
    printf "${MSG[$key]:-$key}\n" "$@"
}
say() {
    ui_level_of "$1"
    say_as "$UI_LEVEL" "$@"
}
say_as() {
    local level=$1; shift
    ui_notice "$(t "$@")" "$level"
    ui_say "$level" "$@"
}
die() {
    if [[ -n $UI_PROGRESS_FD ]]; then
        exec 2>&"$UI_PROGRESS_FD"
        ui_restore
    fi
    if [[ $1 == cancelled ]]; then say_as warning "$@"
    else
        [[ -z $UI_CURRENT_STEP ]] || ui_log error "$UI_CURRENT_STEP"
        say_as error "$@"
    fi
    [[ -z $UI_LAST_LOG ]] || say ui_error_log "$UI_LAST_LOG"
    if storage_failure_report "$UI_LAST_LOG"; then GDM_STORAGE_FAILURE=true; exit 74; fi
    exit 1
}
ask() {
    local var=$1 key=$2 default=${3:-} prompt_input
    [[ -t 0 ]] || die interactive_required
    ui_page
    if ui_interactive; then
        # Own editor (no readline): Esc returns 1 so callers can go back.
        ui_field "$key" "$default" title
        ui_read_line prompt_input || return 1
    else
        ui_field "$key" "$default"
        IFS= read -r prompt_input || return 1
    fi
    printf -v "$var" '%s' "${prompt_input:-$default}"
}
confirm() {
    local answer kind=ok
    local default=no
    [[ ${2:-n} != y ]] || default=yes
    # "Yes" is drawn as a risk when it stops services, migrates data or shows secrets.
    case $1 in
        stop_confirm|transfer_confirm|update_confirm|migration_review|db_update_confirm|config_confirm|\
        unsupported_confirm|credentials_warning|self_update_confirm|install_docker|install_dependencies|logs_restart_confirm|\
        docker_plugins_confirm) kind=warn;;
    esac
    choose answer "$1" "$default" yes "$(ui_opt "$kind" "$(t ui_yes)")" no "$(ui_opt back "$(t ui_no)")" || return 1
    [[ $answer == yes ]]
}
typed_confirm() {
    local answer
    say destructive "$1"
    [[ -t 0 ]] || die interactive_required
    if ui_interactive; then
        printf '  ' >&2; ui_color 2; printf '%s' "$(t ui_typed_keys)" >&2; ui_color 0; printf '\n' >&2
        ui_read_line answer '> ' '1;31' || die cancelled
    else
        printf '  > ' >&2
        IFS= read -r answer || die cancelled
    fi
    [[ $answer == "$1" ]] || die cancelled
}
secret_prompt() {
    local var=$1 answer secret_label=ui_app_password
    [[ $var != root_password ]] || secret_label=ui_root_password
    while :; do
        ui_secret_read answer "$secret_label" || die cancelled
        [[ -n $answer ]] || answer=$(openssl rand -hex 24)
        if [[ $answer == *[$'\001'-$'\037'$'\177']* ]]; then say bad_password; continue; fi
        if [[ $var == root_password && ( $answer == *\'* || $answer == *\"* || $answer == *\\* ) ]]; then
            say bad_root_password
            continue
        fi
        break
    done
    ui_log success "$(t ui_password_saved)"
    printf -v "$var" '%s' "$answer"
}
init_state() {
    [[ $STATE == /* && $STATE != / && $STATE != *$'\n'* ]] || die bad_path
    [[ ! -L $STATE ]] || die bad_path
    if ! mkdir -p -- "$STATE" 2>/dev/null; then
        die permissions "$STATE"
    fi
    chmod 700 "$STATE"
    mkdir -p -- "$STATE/revisions" "$STATE/backups" "$STATE/cache"
    exec {GDM_LOCK_FD}>"$STATE/manager.lock"
    if (( ${GDM_LOCK_WAIT:-0} > 0 )); then flock -w "$GDM_LOCK_WAIT" "$GDM_LOCK_FD" || die locked
    else flock -n "$GDM_LOCK_FD" || die locked; fi
}
cleanup() {
    local rc=$? path
    trap - EXIT
    [[ -z $UI_PROGRESS_FD ]] || exec 2>&"$UI_PROGRESS_FD"
    ui_restore
    if [[ $GDM_STORAGE_FAILURE != true && ${RESUME_GLPI_ON_EXIT:-false} == true && -r ${CONFIG:-/nonexistent} ]]; then
        dc start glpi >/dev/null 2>&1 || true
        [[ $(cfg tls) == off ]] || dc start proxy >/dev/null 2>&1 || true
    fi
    for path in "${CLEANUP_PATHS[@]}"; do
        # Only remove our own single temporary files; never recurse here.
        [[ -f $path && ! -L $path ]] || continue
        if [[ $GDM_STORAGE_FAILURE == true ]]; then
            say cleanup_deferred "$STATE"
            break
        fi
        if ! rm -f -- "$path" 2>/dev/null; then say cleanup_deferred "$STATE"; fi
    done
    for path in "${CLEANUP_DIRECTORIES[@]}"; do
        [[ -d $path && ! -L $path ]] || continue
        if [[ $GDM_STORAGE_FAILURE == true ]]; then say cleanup_deferred "$STATE"; break; fi
        # Only private, uniquely allocated backup staging directories. Saved
        # archives, application data and retained restore points never match.
        if [[ ! -L $STATE/backups && ${path%/*} == "$STATE/backups" && ${path##*/} =~ ^\.(restore-[a-f0-9]{16}|work-[a-zA-Z0-9]{6})$ ]]; then
            rm -rf --one-file-system -- "$path" 2>/dev/null || say cleanup_deferred "$STATE"
        fi
    done
    if [[ $rc == 130 ]]; then ui_interrupted; fi
    if [[ -f ${STATE:-/nonexistent}/operation.json ]]; then
        say recovery_notice "$STATE/operation.json" >&2
    fi
    exit "$rc"
}
on_error() {
    local rc=$?
    [[ -z $UI_PROGRESS_FD ]] || exec 2>&"$UI_PROGRESS_FD"
    ui_restore
    [[ -z $UI_CURRENT_STEP ]] || ui_log error "$UI_CURRENT_STEP"
    say failed "${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}" >&2
    [[ -z $UI_LAST_LOG ]] || say ui_error_log "$UI_LAST_LOG"
    if storage_failure_report "$UI_LAST_LOG"; then GDM_STORAGE_FAILURE=true; exit 74; fi
    return "$rc"
}
storage_failure_report() {
    # Use Bash builtins: host executables themselves may fail with EIO.
    local log=${1:-} line issue=''
    [[ -r $log ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        case ${line,,} in
            *'input/output error'*|*'i/o error'*|*'error de entrada/salida'*) issue=host_io_error; break;;
            *'read-only file system'*|*'sistema de archivos de solo lectura'*) issue=host_readonly;;
            *'no space left on device'*|*'no queda espacio en el dispositivo'*) [[ -n $issue ]] || issue=host_no_space;;
        esac
    done < "$log"
    [[ -n $issue ]] || return 1
    say "$issue"
    say host_storage_steps
}
# shellcheck source=lib/ui.sh
source "$GDM_ROOT/lib/ui.sh"
# shellcheck source=lib/layout.sh
source "$GDM_ROOT/lib/layout.sh"
journal_begin() {
    [[ ! -f $STATE/operation.json ]] || die recovery_notice "$STATE/operation.json"
    jq -n --arg action "$1" --arg time "$(date -u +%FT%TZ)" \
       '{action:$action,started_at:$time,phase:"started"}' > "$STATE/operation.json"
}
journal_phase() {
    local tmp
    tmp=$(mktemp "$STATE/.journal.XXXXXX")
    jq --arg phase "$1" '.phase=$phase' "$STATE/operation.json" > "$tmp"
    mv -- "$tmp" "$STATE/operation.json"
}
journal_done() {
    [[ -f $STATE/operation.json ]] || return 0
    jq -c --arg time "$(date -u +%FT%TZ)" '. + {completed_at:$time}' "$STATE/operation.json" >> "$STATE/history.jsonl"
    rm -- "$STATE/operation.json"
}
http_get() {
    # Tokens, if needed, are passed via curl config on stdin, not command arguments.
    local url=$1
    if [[ $url == https://api.github.com/* && -n ${GITHUB_TOKEN:-} ]]; then
        # GitHub installation tokens now include JWT punctuation. Accept bearer
        # token characters while rejecting curl-config/header injection.
        [[ $GITHUB_TOKEN =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || die invalid token
        printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
            curl --config - --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 90 "$url"
    else
        curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 90 "$url"
    fi
}

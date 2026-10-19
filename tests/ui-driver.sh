#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
# shellcheck source=lib/core.sh
source "$GDM_ROOT/lib/core.sh"
tr_load
trap ui_restore EXIT
trap 'exit 130' INT
trap on_error ERR
before=$(stty -g)
choice=''
root_password=''
case ${1:-select} in
    select|cancel)
        if choose choice mode_prompt test test "$(t ui_mode_test)" production "$(t ui_mode_production)" custom Custom; then
            printf 'RESULT=%s\n' "$choice"
        else printf 'CANCELLED\n'; fi;;
    language) choose_language; printf 'RESULT=%s\n' "$LANGUAGE";;
    confirm) if confirm install_confirm; then printf 'ACCEPTED\n'; else printf 'DECLINED\n'; fi;;
    long)
        options=()
        for ((i=1; i<=22; i++)); do options+=("$i" "Action $i"); done
        choose choice ui_menu_prompt 1 "${options[@]}"
        printf 'RESULT=%s\n' "$choice";;
    ask) ask choice port_prompt 8080; printf 'RESULT=%s\n' "$choice";;
    valid-port) ask_value choice port_prompt 8080 port; printf 'RESULT=%s\n' "$choice";;
    secret|secret-hidden|secret-toggle|secret-long)
        secret_prompt choice
        [[ $choice == "${GDM_UI_EXPECT_SECRET:-abc}" ]]
        printf 'SECRET_OK\n';;
    secret-generated)
        secret_prompt choice
        [[ $choice =~ ^[a-f0-9]{48}$ ]]
        printf 'GENERATED_OK\n';;
    root-secret)
        secret_prompt root_password
        [[ $root_password == 1 ]]
        printf 'ROOT_OK\n';;
    pages)
        ask choice db_name_prompt glpi
        [[ $choice == glpi ]]
        secret_prompt choice
        [[ $choice == x ]]
        choose choice expose_prompt no yes "$(t ui_yes)" no "$(t ui_no)"
        [[ $choice == no ]]
        printf 'PAGES_OK\n';;
    fail)
        STATE=${GDM_UI_TEST_STATE:?}
        fail_inner() { printf 'private failure details\n'; return 42; }
        fail_action() { fail_inner; printf 'UNSAFE_INNER_CONTINUATION\n'; }
        ui_run 1 ui_step_volumes fail_action
        printf 'UNSAFE_CONTINUATION\n';;
    io-fail|spinner-fail)
        STATE=${GDM_UI_TEST_STATE:?}
        if [[ $1 == spinner-fail ]]; then
            sleep() { printf 'sleep: Input/output error\n' >&2; return 1; }
            fail_action() { command sleep 0.5; return 42; }
        else fail_action() { printf 'docker: Input/output error\n' >&2; return 42; }; fi
        ui_run 2 ui_step_images fail_action
        printf 'UNSAFE_CONTINUATION\n';;
    menu-back)
        source "$GDM_ROOT/lib/operations.sh"
        STATE=$(mktemp -d)
        trap 'ui_restore; rm -rf -- "$STATE"' EXIT
        dispatch() { exit 10; }
        menu
        printf 'MENU_CLOSED\n';;
    resource-back)
        source "$GDM_ROOT/lib/system.sh"
        source "$GDM_ROOT/lib/operations.sh"
        STATE=$(mktemp -d)
        trap 'ui_restore; rm -rf -- "$STATE"' EXIT
        df() { printf 'Filesystem 1M-blocks Used Available Use%% Mounted\nfixture 15000 5000 10000 33%% /\n'; }
        awk() { if [[ ${*: -1} == /proc/meminfo ]]; then printf '1959\n'; else command awk "$@"; fi; }
        storage_preflight() { :; }
        dispatch() { check_resources; printf 'UNSAFE_CONTINUATION\n'; }
        menu
        printf 'MENU_CLOSED\n';;
    defaults-card)
        ui_panel "$(t ui_defaults_title)" $'GLPI_DB_HOST\tdb' $'GLPI_DB_PORT\t3306' $'GLPI_DB_NAME\tglpi'
        choose choice ui_settings_prompt defaults defaults "$(t ui_settings_defaults)" custom "$(t ui_settings_custom)"
        printf 'RESULT=%s\n' "$choice";;
    screen) ui_panel "$(t ui_first_title)" "$(t ui_first_body)"; choose choice first_action install install "$(t ui_install)" restore "$(t ui_restore_backup)" quit "$(t ui_exit)"; printf 'RESULT=%s\n' "$choice";;
    menu-cancel)
        # shellcheck source=lib/operations.sh
        source "$GDM_ROOT/lib/operations.sh"
        STATE=$(mktemp -d)
        trap 'ui_restore; rm -rf -- "$STATE"' EXIT
        dispatch() { printf 'private fixture' > "$STATE/temporary-credential"; CLEANUP_PATHS+=("$STATE/temporary-credential"); die cancelled; }
        menu
        [[ ! -e $STATE/temporary-credential ]]
        printf 'MENU_CLOSED\n';;
    saved-language)
        # shellcheck source=lib/operations.sh
        source "$GDM_ROOT/lib/operations.sh"
        STATE=$(mktemp -d)
        trap 'ui_restore; rm -rf -- "$STATE"' EXIT
        mkdir -p "$STATE/current"
        printf '{"language":"es"}\n' > "$STATE/current/config.json"
        LANGUAGE_OVERRIDE=''
        main help
        main --lang en help;;
esac
[[ $(stty -g) == "$before" ]]
printf 'TERMINAL_RESTORED\n'

#!/usr/bin/env bash
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
GDM_STATE_DIR="${GDM_STATE_DIR:?}/release-cases"
export GDM_ROOT GDM_STATE_DIR
for module in core releases; do
    # shellcheck source=/dev/null
    source "$GDM_ROOT/lib/$module.sh"
done
tr_load
mkdir -p "$STATE/cache"
http_get() {
    case $1 in
        *SECURITY.md) printf '| 13.0.x | ✔ |\n| 12.0.x | ✔ |\n';;
        *page=1) printf '%s\n' '[{"tag_name":"14.0.0-rc1","draft":false,"prerelease":true},{"tag_name":"13.0.0","draft":true,"prerelease":false},{"tag_name":"v12.0.0","draft":false,"prerelease":false,"body":"Official notice"}]';;
        *page=2) printf '%s\n' '[{"tag_name":"11.0.11","draft":false,"prerelease":false,"body":"Security release"},{"tag_name":"11.0.10","draft":false,"prerelease":false},{"tag_name":"11.0.9","draft":false,"prerelease":false},{"tag_name":"11.0.8","draft":false,"prerelease":false},{"tag_name":"11.0.7","draft":false,"prerelease":false}]';;
        *) printf '[]\n';;
    esac
}
release_fetch
[[ $(jq length "$STATE/cache/releases.json") == 6 ]]
[[ $(release_versions 11 | head -n 1) == 11.0.11 ]]
[[ $(jq -r '.[0].version' "$STATE/cache/releases.json") == 12.0.0 ]]
image_resolve() {
    [[ $2 != 11.0.11 ]] || return 1
    printf '%s:%s@sha256:fixture\n' "$1" "$2"
}
choose() { printf -v "$1" '%s' 11.0.10; }
release_notice() { :; }
select_version 11
[[ $SELECTED_VERSION == 11.0.10 ]]
[[ $SELECTED_IMAGE == glpi/glpi:11.0.10@sha256:fixture ]]
command_select_fixture=$'system:check_requirements Description\ndatabase:update Description'
# shellcheck source=lib/docker.sh
source "$GDM_ROOT/lib/docker.sh"
[[ $(command_select requirements "$command_select_fixture") == system:check_requirements ]]
[[ $(command_select update "$command_select_fixture") == database:update ]]
if command_select schema "$command_select_fixture" >/dev/null 2>&1; then exit 1; fi
# All later installable patches remain selectable, followed by the next major.
# shellcheck source=lib/operations.sh
source "$GDM_ROOT/lib/operations.sh"
UPDATE_CHOICES_FILE="$STATE/update-choices.tsv"
build_update_choices 11.0.7 11
[[ $(cut -f1 "$UPDATE_CHOICES_FILE" | paste -sd, -) == 11.0.8,11.0.9,11.0.10,12.0.0 ]]
build_update_choices 11.0.10 11
[[ $(cut -f1 "$UPDATE_CHOICES_FILE") == 12.0.0 ]]
build_update_choices 12.0.0 12
[[ ! -s $UPDATE_CHOICES_FILE ]]
select_update_target 12.0.0 12
[[ -z $SELECTED_UPDATE ]]

# Migrations appear once per branch, then list the newest three installable
# releases. The selector can show older releases or return without applying.
(
    printf '%s\n' '[{"version":"11.0.12"},{"version":"11.0.13"},{"version":"11.0.14"},
      {"version":"12.0.0"},{"version":"12.0.1"},{"version":"12.0.2"},{"version":"12.0.3"},
      {"version":"12.0.4"},{"version":"13.0.0"},{"version":"14.0.0"}]' > "$STATE/cache/releases.json"
    # Invoked indirectly by the sourced parallel image resolver.
    # shellcheck disable=SC2317
    image_resolve() {
        [[ $2 != 12.0.4 ]] || return 1
        printf '%s:%s@sha256:fixture\n' "$1" "$2"
    }
    choose() {
        local output=$1 prompt=$2 selected=$3
        shift 3
        local -a options=("$@")
        ((update_calls+=1))
        case "$update_plan:$update_calls" in
            latest:1|all:1|back:1|back:3|back:5)
                [[ $prompt == update_select_prompt && $selected == branch:12 && ${#options[@]} == 4 ]] || exit 99
                [[ ${options[0]} == branch:12 && ${options[2]} == back ]] || exit 99
                [[ ${options[1]} == "$(ui_opt warn "$(t update_label_major 'GLPI 12' 11 12)" "$(t opt_update_major 11 12)")" ]] || exit 99
                if [[ $update_plan == back && $update_calls == 5 ]]; then printf -v "$output" back
                else printf -v "$output" branch:12; fi;;
            latest:2|all:2|back:2|back:4)
                [[ $prompt == choose_version_update && $selected == 12.0.3 && ${#options[@]} == 10 ]] || exit 99
                [[ ${options[0]} == 12.0.3 && ${options[2]} == 12.0.2 && ${options[4]} == 12.0.1 ]] || exit 99
                [[ ${options[6]} == other && ${options[8]} == back ]] || exit 99
                [[ ${options[1]} == "$(ui_opt warn "GLPI 12.0.3 · $(t opt_recommended)" "$(t opt_update_major 11 12)")" ]] || exit 99
                case $update_plan in
                    latest) printf -v "$output" 12.0.2;;
                    all) printf -v "$output" other;;
                    back) if (( update_calls == 2 )); then return 1; else printf -v "$output" back; fi;;
                esac;;
            all:3)
                [[ $prompt == choose_version_update && ${#options[@]} == 10 ]] || exit 99
                [[ ${options[6]} == 12.0.0 && ${options[8]} == back ]] || exit 99
                printf -v "$output" 12.0.0;;
            patch:1)
                [[ $prompt == update_select_prompt && $selected == 11.0.14 && ${#options[@]} == 8 ]] || exit 99
                [[ ${options[0]} == 11.0.13 && ${options[2]} == 11.0.14 && ${options[4]} == branch:12 ]] || exit 99
                printf -v "$output" 11.0.13;;
            future:1)
                [[ $prompt == update_select_prompt && ${options[0]} == branch:13 && ${#options[@]} == 4 ]] || exit 99
                printf -v "$output" branch:13;;
            future:2)
                [[ $prompt == choose_version_update && ${options[0]} == 13.0.0 && ${#options[@]} == 4 ]] || exit 99
                printf -v "$output" 13.0.0;;
            *) exit 99;;
        esac
    }
    for LANGUAGE in en es; do
        tr_load
        update_plan=latest update_calls=0
        select_update_target 11.0.14 11
        [[ $SELECTED_UPDATE == 12.0.2 && $update_calls == 2 ]]
        update_plan=all update_calls=0
        select_update_target 11.0.14 11
        [[ $SELECTED_UPDATE == 12.0.0 && $update_calls == 3 ]]
        update_plan=back update_calls=0
        if (select_update_target 11.0.14 11); then exit 1; else [[ $? == 10 ]]; fi
        update_plan=patch update_calls=0
        select_update_target 11.0.12 11
        [[ $SELECTED_UPDATE == 11.0.13 && $update_calls == 1 ]]
        update_plan=future update_calls=0
        select_update_target 12.0.4 12
        [[ $SELECTED_UPDATE == 13.0.0 && $update_calls == 2 ]]
    done
) > "$STATE/grouped-updates.log" 2>&1
printf '%s\n' 'PASS: one migration entry per branch, latest-three selection, all versions, Back, patch updates and next-major limits (EN/ES)'

# New installs offer the unsupported branch last; migrations never offer it.
(
    printf '%s\n' '[{"version":"11.0.11"},{"version":"10.0.28"},{"version":"12.0.0"},{"version":"10.0.27"}]' > "$STATE/cache/releases.json"
    declare -a major_captured=()
    major_selected=''
    choose() {
        local output=$1
        [[ $2 == major_prompt && $3 == 12 ]]
        shift 3
        major_captured=("$@")
        printf -v "$output" '%s' "$major_pick"
    }
    for LANGUAGE in en es; do
        tr_load
        major_pick=12
        select_major major_selected 12 10 false install
        [[ $major_selected == 12 && ${#major_captured[@]} == 6 ]]
        [[ ${major_captured[0]} == 12 && ${major_captured[2]} == 11 && ${major_captured[4]} == 10 ]]
        [[ ${major_captured[1]} == "$(ui_opt primary "GLPI 12 · $(t opt_recommended)" "$(t opt_major_latest)")" ]]
        [[ ${major_captured[3]} == "$(ui_opt '' 'GLPI 11' "$(t opt_major_older)")" ]]
        [[ ${major_captured[5]} == "$(ui_opt warn "$(t legacy_branch_label)" "$(t opt_legacy_branch)")" ]]

        major_pick=10
        select_major major_selected 12 10 false install
        [[ $major_selected == 10 ]]

        major_pick=12
        select_major major_selected 12 11 false migrate
        [[ $major_selected == 12 && ${#major_captured[@]} == 2 && ${major_captured[0]} == 12 ]]
        [[ ${major_captured[1]} == "$(ui_opt warn 'GLPI 12' "$(t opt_update_major 11 12)")" ]]
    done
)

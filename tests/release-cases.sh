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

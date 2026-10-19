#!/usr/bin/env bash
# SELECTED_IMAGE is returned to the calling wizard through shared module state.
# shellcheck disable=SC2034
valid_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
version_gt() {
    valid_version "$1" && valid_version "$2" || return 1
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}
release_fetch() {
    local page=1 part tmp aggregate
    aggregate=$(mktemp "$STATE/cache/.releases.XXXXXX")
    CLEANUP_PATHS+=("$aggregate")
    printf '[]\n' > "$aggregate"
    # Follow all pages; older branches can be beyond GitHub's first 100 entries.
    while :; do
        part=$(http_get "https://api.github.com/repos/glpi-project/glpi/releases?per_page=100&page=$page") || return 1
        jq -e 'type=="array"' <<< "$part" >/dev/null || return 1
        [[ $(jq length <<< "$part") != 0 ]] || break
        tmp=$(mktemp "$STATE/cache/.page.XXXXXX"); CLEANUP_PATHS+=("$tmp")
        jq -s '.[0]+.[1]' "$aggregate" <(printf '%s' "$part") > "$tmp"
        mv -- "$tmp" "$aggregate"
        ((page+=1))
        (( page <= 100 )) || die release_limit
    done
    jq '[.[] | select(.draft==false and .prerelease==false) |
        . + {version:(.tag_name|ltrimstr("v"))} |
        select(.version|test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))] |
        sort_by(.version|split(".")|map(tonumber)) | reverse' "$aggregate" > "$STATE/cache/releases.json.tmp"
    mv -- "$STATE/cache/releases.json.tmp" "$STATE/cache/releases.json"
    if http_get https://raw.githubusercontent.com/glpi-project/glpi/HEAD/SECURITY.md > "$STATE/cache/security.md.tmp"; then
        mv -- "$STATE/cache/security.md.tmp" "$STATE/cache/security.md"
    else say support_unknown; fi
}
release_versions() {
    jq -r --arg major "$1" '.[]|select((.version|split(".")[0])==$major)|.version' "$STATE/cache/releases.json"
}
image_resolve() {
    local repository=$1 version=$2 manifest digest
    valid_version "$version" || return 1
    case $repository in glpi/glpi|mysql|caddy) ;; *) return 1;; esac
    manifest=$(docker buildx imagetools inspect "$repository:$version" --format '{{json .Manifest}}') || return 1
    jq -e --arg arch "$ARCH" 'any(.manifests[]?; .platform.os=="linux" and .platform.architecture==$arch)' <<< "$manifest" >/dev/null || return 1
    digest=$(jq -r .digest <<< "$manifest")
    [[ $digest =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    printf '%s:%s@%s\n' "$repository" "$version" "$digest"
}
official_tag_latest() {
    local repo=$1 series=$2 page url version
    url="https://hub.docker.com/v2/repositories/library/$repo/tags?page_size=100&name=$series."
    page=$(http_get "$url") || return 1
    version=$(jq -r --arg series "$series" '[.results[].name | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) |
        select(startswith($series+"."))] | sort_by(split(".")|map(tonumber)) | last // empty' <<< "$page")
    valid_version "$version" || return 1
    printf '%s\n' "$version"
}
release_notice() {
    local version=$1 major=${1%%.*} body url note_action
    body=$(jq -r --arg v "$version" '.[]|select(.version==$v)|.body // ""' "$STATE/cache/releases.json")
    url="https://github.com/glpi-project/glpi/releases/tag/$version"
    say release_notes "$version" "$url"
    if grep -Eiq '(this is a security release|security issues fixed|security vulnerabilities fixed|security fixes)' <<< "$body"; then
        say security_release
    fi
    if [[ $major == 10 ]]; then
        say glpi10_warning
        confirm unsupported_confirm || die cancelled
    elif [[ ! -s $STATE/cache/security.md ]]; then say support_unknown
    elif ! grep -Eq "\\|[[:space:]]*$major\\.0\\.x[[:space:]]*\\|.*(✔|✅)" "$STATE/cache/security.md"; then
        say support_unknown
    fi
    local newest
    newest=$(release_versions "$major" | head -n 1)
    [[ $newest == "$version" ]] || say older_release "$newest"
    if [[ -t 0 ]]; then
        choose note_action ui_release_prompt continue continue "$(t ui_release_continue)" notes "$(t ui_release_details)" || die cancelled
        if [[ $note_action == notes ]]; then
            # Upstream text is data, never terminal control sequences or code.
            printf '%s\n' "$body" | LC_ALL=C tr -d '\000-\010\013-\037\177' >&2
            ui_pause ui_continue_setup
        fi
    fi
}
select_version() {
    local major=$1 requested=${2:-} version reference choice limit=3 allow_back=${3:-false}
    local -a versions=() refs=() version_options=()
    if [[ -n $requested ]]; then
        if ! valid_version "$requested" || [[ ${requested%%.*} != "$major" ]]; then die invalid version; fi
        jq -e --arg v "$requested" 'any(.[]; .version==$v)' "$STATE/cache/releases.json" >/dev/null || die invalid version
        SELECTED_VERSION=$requested
        SELECTED_IMAGE=$(image_resolve glpi/glpi "$requested") || die image_missing "$requested"
        release_notice "$requested"
        return
    fi
    while IFS= read -r version; do
        if reference=$(image_resolve glpi/glpi "$version" 2>/dev/null); then
            versions+=("$version"); refs+=("$reference")
            (( ${#versions[@]} >= limit )) && break
        fi
    done < <(release_versions "$major")
    (( ${#versions[@]} > 0 )) || die image_missing "$major"
    local i
    for i in "${!versions[@]}"; do version_options+=("${versions[i]}" "GLPI ${versions[i]}"); done
    version_options+=(other "$(t more_versions)")
    [[ $allow_back != true ]] || version_options+=(back "$(t setup_return_edit)")
    if ! choose choice choose_version "${versions[0]}" "${version_options[@]}"; then
        [[ $allow_back != true ]] || return 10
        die cancelled
    fi
    [[ $choice != back ]] || return 10
    if [[ $choice == other ]]; then
        release_versions "$major" >&2
        ask requested exact_version
        select_version "$major" "$requested"
        return
    fi
    for i in "${!versions[@]}"; do
        if [[ $choice == "${versions[i]}" ]]; then SELECTED_VERSION=${versions[i]}; SELECTED_IMAGE=${refs[i]}; break; fi
    done
    release_notice "$SELECTED_VERSION"
}

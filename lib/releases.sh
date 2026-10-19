#!/usr/bin/env bash
# SELECTED_IMAGE is returned to the calling wizard through shared module state.
# shellcheck disable=SC2034
valid_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
version_gt() {
    valid_version "$1" && valid_version "$2" || return 1
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}
# Seconds since the cached release list was written (fails when absent).
release_cache_age() {
    local now modified
    [[ -s $STATE/cache/releases.json ]] || return 1
    modified=$(stat -c %Y -- "$STATE/cache/releases.json" 2>/dev/null) || return 1
    printf -v now '%(%s)T' -1
    printf '%s\n' "$((now > modified ? now-modified : 0))"
}
# The full GitHub listing takes several paginated requests. Reuse it for
# GDM_RELEASE_TTL seconds (default 15 min) and fall back to the saved list when
# GitHub is unreachable. GDM_RELEASE_REFRESH=1 forces a new download.
release_fetch() {
    local page=1 part tmp aggregate age
    if [[ ${GDM_RELEASE_REFRESH:-} != 1 ]] && age=$(release_cache_age) && (( age < ${GDM_RELEASE_TTL:-900} )); then
        say releases_cached "$((age/60))"
        return 0
    fi
    aggregate=$(mktemp "$STATE/cache/.releases.XXXXXX")
    CLEANUP_PATHS+=("$aggregate")
    printf '[]\n' > "$aggregate"
    # Follow all pages; older branches can be beyond GitHub's first 100 entries.
    while :; do
        ui_status "$(t status_release_page "$page")"
        if ! part=$(http_get "https://api.github.com/repos/glpi-project/glpi/releases?per_page=100&page=$page") ||
           ! jq -e 'type=="array"' <<< "$part" >/dev/null 2>&1; then
            release_cache_age >/dev/null || return 1
            say releases_stale
            return 0
        fi
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
# Docker Hub answers anonymous bursts with HTTP 429. Without this, rate-limited
# tags would silently look like releases without an image.
registry_limit_check() {
    if grep -qsiE '429|toomanyrequests|too many requests' -- "$@"; then say registry_rate_limited; fi
}
# Registry lookups dominate wall-clock time, so several tags are resolved at
# once. Writes "version<TAB>reference" lines in the given order and omits
# versions without an image for this architecture. Jobs are awaited by PID so
# a running spinner (also a child of this shell) is never waited for.
images_resolve() {
    local repository=$1 output=$2 work index jobs=${GDM_RESOLVE_JOBS:-6}
    shift 2
    local -a versions=("$@") pids=()
    work=$(mktemp -d "$STATE/cache/.resolve-XXXXXX")
    for index in "${!versions[@]}"; do
        ui_status "$(t status_resolving "$repository:${versions[index]}")"
        (
            trap - ERR EXIT
            image_resolve "$repository" "${versions[index]}" > "$work/$index" 2> "$work/$index.err" || rm -f -- "$work/$index"
        ) &
        pids+=("$!")
        if (( ${#pids[@]} >= jobs )); then wait "${pids[0]}" || true; pids=("${pids[@]:1}"); fi
    done
    for index in "${pids[@]}"; do wait "$index" || true; done
    registry_limit_check "$work"/*.err
    : > "$output"
    for index in "${!versions[@]}"; do
        [[ -s $work/$index ]] || continue
        printf '%s\t%s\n' "${versions[index]}" "$(< "$work/$index")" >> "$output"
    done
    rm -rf -- "$work"
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
# Latest patch of an official series with its pinned digest: "version<TAB>reference".
official_image_lookup() {
    local version reference
    version=$(official_tag_latest "$1" "$2") || return 1
    reference=$(image_resolve "$1" "$version") || return 1
    printf '%s\t%s\n' "$version" "$reference"
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
# Fills the caller's versions/refs arrays (Bash dynamic scope) with the newest
# installable releases, checking candidates in parallel batches.
select_version_candidates() {
    local major=$1 limit=$2 start=0 batch=6 version reference resolved
    local -a candidates=()
    mapfile -t candidates < <(release_versions "$major")
    resolved=$(mktemp "$STATE/cache/.resolved.XXXXXX"); CLEANUP_PATHS+=("$resolved")
    while (( ${#versions[@]} < limit && start < ${#candidates[@]} )); do
        images_resolve glpi/glpi "$resolved" "${candidates[@]:start:batch}"
        while IFS=$'\t' read -r version reference; do
            (( ${#versions[@]} < limit )) || break
            versions+=("$version"); refs+=("$reference")
        done < "$resolved"
        start=$((start+batch))
    done
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
    ui_task task_versions select_version_candidates "$major" "$limit"
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
        # Keep the list visible: ask() opens a new page that redraws this panel.
        while :; do
            ui_panel "$(t version_list_title "$major")" "$(release_versions "$major" | tr '\n' ' ')"
            ask requested exact_version || die cancelled
            jq -e --arg v "$requested" 'any(.[]; .version==$v)' "$STATE/cache/releases.json" >/dev/null && break
            say invalid "$requested"
        done
        select_version "$major" "$requested"
        return
    fi
    for i in "${!versions[@]}"; do
        if [[ $choice == "${versions[i]}" ]]; then SELECTED_VERSION=${versions[i]}; SELECTED_IMAGE=${refs[i]}; break; fi
    done
    release_notice "$SELECTED_VERSION"
}

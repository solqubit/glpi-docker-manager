#!/usr/bin/env bash
# OS_VERSION is also used by diagnostics and distribution fixtures.
# shellcheck disable=SC2034
os_detect() {
    local file=${1:-/etc/os-release} key value
    OS_ID=unknown OS_VERSION=unknown OS_CODENAME='' OS_NAME=Linux
    if [[ -r $file ]]; then
        while IFS='=' read -r key value; do
            value=${value%\"}; value=${value#\"}
            value=${value%\'}; value=${value#\'}
            case $key in
                ID) OS_ID=$value;; VERSION_ID) OS_VERSION=$value;;
                VERSION_CODENAME) OS_CODENAME=$value;; PRETTY_NAME) OS_NAME=$value;;
            esac
        done < "$file"
    fi
    case $(uname -m) in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) ARCH=unsupported;; esac
    PKG=
    local candidate
    for candidate in apt-get dnf yum zypper pacman apk; do
        if command -v "$candidate" >/dev/null; then PKG=$candidate; break; fi
    done
}
running_as_root() { (( EUID == 0 )); }
require_admin() {
    running_as_root && return 0
    say admin_required
    say admin_command
    printf '%q ' sudo bash "$GDM_ROOT/start.sh" --lang "$LANGUAGE" --state-dir "$STATE" "${GDM_COMMAND_ARGS[@]}" >&2
    printf '\n' >&2
    exit 1
}
as_root() {
    if running_as_root; then "$@"; else command -v sudo >/dev/null || die need_sudo; sudo -- "$@"; fi
}
admin_command_retry() {
    while ! as_root "$@"; do
        say admin_retry_notice
        # Let the command's output be read before the question clears the page.
        ui_pause ui_continue_setup
        confirm docker_retry_confirm y || die cancelled
    done
}
bootstrap_dependencies() {
    local missing='' cmd package
    local -a packages=()
    local -A selected=()
    for cmd in curl jq openssl tar gzip sha256sum flock ss python3 df awk; do
        command -v "$cmd" >/dev/null && continue
        missing+=" $cmd"
        case $cmd in
            sha256sum|df) package=coreutils;;
            flock) package=util-linux;;
            ss)
                package=iproute2
                [[ $PKG != dnf && $PKG != yum ]] || package=iproute;;
            python3) package=python3; [[ $PKG != pacman ]] || package=python;;
            awk) package=gawk;;
            *) package=$cmd;;
        esac
        if [[ -z ${selected[$package]:-} ]]; then packages+=("$package"); selected[$package]=1; fi
        if [[ $cmd == curl && -z ${selected[ca-certificates]:-} ]]; then
            packages+=(ca-certificates); selected[ca-certificates]=1
        fi
    done
    [[ -n $missing ]] || return 0
    say dependencies "$missing"
    confirm install_dependencies || die cancelled
    case $PKG in
        apt-get) admin_command_retry apt-get update; admin_command_retry apt-get install -y --no-remove --no-upgrade "${packages[@]}";;
        dnf|yum) admin_command_retry "$PKG" install -y "${packages[@]}";;
        zypper) admin_command_retry zypper --non-interactive install "${packages[@]}";;
        pacman) admin_command_retry pacman -S --needed --noconfirm "${packages[@]}";;
        apk) admin_command_retry apk add "${packages[@]}";;
        *) die manual_dependencies;;
    esac
}
docker_install_plan() {
    case $OS_ID in
        ubuntu|debian) printf 'https://docs.docker.com/engine/install/%s/\n' "$OS_ID";;
        fedora|rhel|centos) printf 'https://docs.docker.com/engine/install/%s/\n' "$OS_ID";;
        rocky) printf '%s\n' 'https://docs.rockylinux.org/gemstones/containers/docker/';;
        *) return 1;;
    esac
}
docker_endpoint() {
    local context endpoint
    if [[ -n ${DOCKER_HOST:-} ]]; then endpoint=$DOCKER_HOST
    else
        context=$(docker context show)
        endpoint=$(docker context inspect "$context" --format '{{.Endpoints.docker.Host}}')
    fi
    [[ $endpoint == unix://* ]] || die remote_docker
    printf '%s\n' "$endpoint"
}
service_manager() {
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        printf 'systemd\n'
    elif command -v rc-service >/dev/null; then
        printf 'openrc\n'
    elif command -v service >/dev/null; then
        printf 'sysv\n'
    else printf 'unknown\n'; fi
}
docker_start_service() {
    local result=0
    case $(service_manager) in
        systemd) as_root systemctl start docker || result=$?;;
        openrc) as_root rc-service docker start || result=$?;;
        sysv) as_root service docker start || result=$?;;
        *) say daemon_manual; return 1;;
    esac
    [[ $result == 0 ]] || { say docker_start_failed; return "$result"; }
}
docker_wait_available() {
    local attempt
    for (( attempt=0; attempt<15; attempt++ )); do
        if docker info >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    return 1
}
docker_require_access() {
    local endpoint socket
    endpoint=$(docker_endpoint)
    socket=${endpoint#unix://}
    while :; do
        if DOCKER_SERVER_VERSION=$(docker info --format '{{.ServerVersion}}' 2>/dev/null); then return 0; fi
        # Custom sockets can belong to rootless/Desktop engines. Never start a
        # different rootful engine in their place.
        if [[ $socket != /var/run/docker.sock && $socket != /run/docker.sock ]]; then
            say docker_context_help "$endpoint"
        else
            say docker_service_stopped
            if docker_start_service; then
                if docker_wait_available; then return 0; fi
                say docker_start_failed
            fi
        fi
        confirm docker_retry_confirm y || die cancelled
    done
}
plugin_package_available() {
    case $PKG in
        apt-get) apt-cache show "$1" >/dev/null 2>&1;;
        dnf|yum) "$PKG" -q info "$1" >/dev/null 2>&1;;
        *) return 1;;
    esac
}
bootstrap_docker_plugins() {
    local compose=false buildx=false candidate selected
    local -a packages=()
    local -a compose_candidates=(docker-compose-v2 docker-compose-plugin)
    local -a buildx_candidates=(docker-buildx docker-buildx-plugin)
    while :; do
        compose=false; buildx=false; packages=()
        docker compose version >/dev/null 2>&1 || compose=true
        docker buildx version >/dev/null 2>&1 || buildx=true
        [[ $compose == true || $buildx == true ]] || return 0
        say docker_plugins_missing
        case $PKG in
            apt-get|dnf|yum) ;;
            *) say docker_plugins_manual; confirm docker_retry_confirm y || die cancelled; continue;;
        esac
        confirm docker_plugins_confirm || die cancelled
        [[ $PKG != apt-get ]] || admin_command_retry apt-get update
        if [[ $PKG != apt-get ]] || { command -v dpkg-query >/dev/null && dpkg-query -W -f='${Status}' docker-ce-cli 2>/dev/null | grep -q '^install ok installed$'; }; then
            compose_candidates=(docker-compose-plugin docker-compose-v2)
            buildx_candidates=(docker-buildx-plugin docker-buildx)
        fi
        if [[ $compose == true ]]; then
            selected=
            for candidate in "${compose_candidates[@]}"; do
                if plugin_package_available "$candidate"; then selected=$candidate; break; fi
            done
            if [[ -z $selected ]]; then say docker_plugins_manual; confirm docker_retry_confirm y || die cancelled; continue; fi
            packages+=("$selected")
        fi
        if [[ $buildx == true ]]; then
            selected=
            for candidate in "${buildx_candidates[@]}"; do
                if plugin_package_available "$candidate"; then selected=$candidate; break; fi
            done
            if [[ -z $selected ]]; then say docker_plugins_manual; confirm docker_retry_confirm y || die cancelled; continue; fi
            packages+=("$selected")
        fi
        say plugin_packages "${packages[*]}"
        case $PKG in
            apt-get) admin_command_retry apt-get install -y --no-remove --no-upgrade "${packages[@]}";;
            dnf|yum) admin_command_retry "$PKG" install -y "${packages[@]}";;
        esac
    done
}
bootstrap_docker() {
    local guide repo tmp keyfile
    if command -v docker >/dev/null; then
        docker_require_access
        bootstrap_docker_plugins
        return
    fi
    guide=$(docker_install_plan) || die manual_docker
    say docker_plan "$OS_NAME" "$guide"
    confirm install_docker || die cancelled
    tmp=$(mktemp); CLEANUP_PATHS+=("$tmp")
    case $OS_ID in
        ubuntu|debian)
            [[ $PKG == apt-get && $OS_CODENAME =~ ^[a-z][a-z0-9-]+$ ]] || die manual_docker
            repo="https://download.docker.com/linux/$OS_ID"
            http_get "$repo/dists/$OS_CODENAME/Release" >/dev/null
            http_get "$repo/gpg" > "$tmp"
            as_root install -d -m 0755 /etc/apt/keyrings
            keyfile="/etc/apt/keyrings/gdm-docker.asc"
            as_root install -m 0644 "$tmp" "$keyfile"
            printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' "$repo" "$OS_CODENAME" "$ARCH" "$keyfile" > "$tmp"
            [[ ! -e /etc/apt/sources.list.d/gdm-docker.sources ]] || die repository_exists
            as_root install -m 0644 "$tmp" /etc/apt/sources.list.d/gdm-docker.sources
            admin_command_retry apt-get update
            admin_command_retry apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        fedora|rhel|centos|rocky)
            [[ $PKG == dnf || $PKG == yum ]] || die manual_docker
            repo=$OS_ID; [[ $repo != rocky ]] || repo=rhel
            http_get "https://download.docker.com/linux/$repo/docker-ce.repo" > "$tmp"
            [[ ! -e /etc/yum.repos.d/gdm-docker.repo ]] || die repository_exists
            as_root install -m 0644 "$tmp" /etc/yum.repos.d/gdm-docker.repo
            admin_command_retry "$PKG" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
    esac
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        as_root systemctl enable --now docker || say docker_start_failed
    fi
    docker_require_access
    bootstrap_docker_plugins
}
require_runtime() {
    [[ $(uname -s) == Linux ]] || die linux_only
    require_admin
    os_detect /etc/os-release
    [[ $ARCH != unsupported ]] || die architecture
    bootstrap_dependencies
    bootstrap_docker
    say detected "$OS_NAME" "$ARCH"
    [[ -z ${DOCKER_SERVER_VERSION:-} ]] || say docker_ready "$DOCKER_SERVER_VERSION"
}
check_resources() {
    local available memory resource_action
    available=$(df -Pm "$STATE" | awk 'NR==2 {print $4}')
    memory=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    say resources "$memory" "$available"
    (( available >= 2048 && memory >= 1024 )) || die low_resources
    storage_preflight 0 1024
    if (( available < 10240 || memory < 4096 )); then
        say resource_reference
        choose resource_action resource_warning continue continue "$(ui_opt warn "$(t ui_continue_install)" "$(t opt_resources_continue)")" \
            back "$(ui_opt back "$(t ui_back_menu)")" || exit 10
        [[ $resource_action != back ]] || exit 10
    fi
}
storage_preflight() {
    local root_path probe available inodes total mount_type device image_need=${1:-0} data_need=${2:-0} found=false required
    local -A needed=() paths=() free=() engine_seen=() seen_paths=()
    root_path=$(docker info --format '{{.DockerRootDir}}')
    [[ $root_path == /* && $root_path != / ]] || die invalid docker_storage_path
    # Group requirements by filesystem: images and application data may share it.
    # Docker 29 can keep image contents in a separate containerd filesystem.
    for probe in "$STATE" "$root_path" /var/lib/containerd; do
        [[ -d $probe ]] || continue
        [[ -z ${seen_paths[$probe]+exists} ]] || continue
        seen_paths[$probe]=true
        [[ $probe != "$root_path" && $probe != /var/lib/containerd ]] || found=true
        read -r device mount_type available < <(df -PTm -- "$probe" | awk 'NR==2 {print $1,$2,$5}')
        [[ $available =~ ^[0-9]+$ ]] || die invalid storage_space
        case $mount_type in tmpfs|ramfs|squashfs|iso9660) die storage_temporary "$probe";; esac
        if [[ -z ${needed[$device]+exists} ]]; then
            needed[$device]=512; paths[$device]=$probe; free[$device]=$available
        fi
        if [[ $probe == "$STATE" ]]; then needed[$device]=$((${needed[$device]}+data_need)); fi
        if [[ ( $probe == "$root_path" || $probe == /var/lib/containerd ) && -z ${engine_seen[$device]+exists} ]]; then
            needed[$device]=$((${needed[$device]}+image_need)); engine_seen[$device]=true
        fi
        read -r total inodes < <(df -Pi -- "$probe" | awk 'NR==2 {print $2,$4}')
        if [[ $total =~ ^[0-9]+$ && $inodes =~ ^[0-9]+$ ]] && ((total > 0 && inodes < 10000)); then
            die storage_inodes "$probe"
        fi
    done
    for device in "${!needed[@]}"; do
        required=${needed[$device]}; available=${free[$device]}; probe=${paths[$device]}
        say docker_storage_space "$probe" "$available" "$required"
        ((available >= required)) || die storage_insufficient "$probe" "$required" "$available"
    done
    [[ $found == true ]] || say docker_storage_unavailable "$root_path"
}
image_storage_budget() {
    local image index platform manifest compressed repository estimate=0
    for image in "$@"; do
        # A pinned image already present on the engine needs no download reserve.
        if docker image inspect "$image" >/dev/null 2>&1; then continue; fi
        compressed=''
        if index=$(docker buildx imagetools inspect "$image" --raw 2>/dev/null); then
            if jq -e '.layers|type=="array"' <<< "$index" >/dev/null 2>&1; then manifest=$index
            else
                platform=$(jq -r --arg arch "$ARCH" '[.manifests[]? | select(.platform.os=="linux" and .platform.architecture==$arch)][0].digest // empty' <<< "$index") || platform=''
                repository=${image%%:*}; manifest=''
                [[ -z $platform ]] || manifest=$(docker buildx imagetools inspect "$repository@$platform" --raw 2>/dev/null) || manifest=''
            fi
            compressed=$(jq -er '[.layers[].size] | add | select(.>0)' <<< "$manifest" 2>/dev/null) || compressed=''
        fi
        if [[ $compressed =~ ^[0-9]+$ ]]; then
            # Compressed blobs plus unpacked layers; shared layers are counted
            # conservatively. This is an estimate, not an exact download size.
            estimate=$((estimate+(compressed*4+1048575)/1048576))
        else
            say storage_image_estimate_unknown "${image%@*}"
            estimate=$((estimate+2048))
        fi
    done
    printf '%s\n' "$estimate"
}
port_free() {
    local port=$1 published
    if ss -H -ltn | awk '{print $4}' | grep -Eq ":${port}$"; then return 1; fi
    # Docker can publish through NAT without a host listening socket.
    published=$(docker ps --format '{{.Ports}}' 2>/dev/null) || return 0
    ! grep -Eq ":${port}->" <<< "$published"
}
server_primary_address() {
    local addresses routes
    addresses=$(ip -j -4 address show up scope global 2>/dev/null) || { printf 'localhost\n'; return; }
    routes=$(ip -j -4 route show default 2>/dev/null) || routes='[]'
    jq -r --argjson routes "${routes:-[]}" '
      ($routes[0].dev // "") as $primary |
      [.[] | select(.ifname | test("^(lo$|docker|br-|veth|virbr)") | not) |
        . as $interface | .addr_info[]? | select(.family=="inet" and .scope=="global") |
        {address:.local, rank:(if $interface.ifname==$primary then 0 else 1 end)}] |
      sort_by(.rank) | .[0].address // "localhost"' <<< "$addresses"
}

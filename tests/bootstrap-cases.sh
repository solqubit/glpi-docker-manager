#!/usr/bin/env bash
# These are controlled runtime failures, never host package/service mutations.
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
# shellcheck source=lib/core.sh
source "$GDM_ROOT/lib/core.sh"
# shellcheck source=lib/system.sh
source "$GDM_ROOT/lib/system.sh"
tr_load
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
scenario=${1:-}
if [[ -z $scenario ]]; then
    for scenario in ready stopped slow-start plugins retry package-retry service-systemd service-openrc service-sysv; do bash "$0" "$scenario"; done
    for scenario in permissions broken rootless remote missing-packages service-unknown; do
        if bash "$0" "$scenario" > "$work/error" 2>&1; then
            printf 'Expected bootstrap failure: %s\n' "$scenario" >&2
            exit 1
        fi
        [[ $scenario != permissions ]] || grep -q 'require sudo/root' "$work/error"
    done
    exit 0
fi
PKG=apt-get
confirm() {
    printf 'confirm %s\n' "$1" >> "$work/calls"
    if [[ $1 == docker_retry_confirm ]]; then
        [[ $scenario == retry || $scenario == package-retry ]] || return 1
        touch "$work/started"
    fi
}
running_as_root() { [[ $scenario != permissions ]]; }
sleep() { :; }
if [[ $scenario != service-* ]]; then
    docker_start_service() {
        printf 'service-start\n' >> "$work/calls"
        [[ $scenario != broken && $scenario != retry ]] || return 1
        touch "$work/started"
    }
fi
dpkg-query() { return 1; }
plugin_package_available() { [[ $scenario != missing-packages ]]; }
as_root() {
    printf '%s\n' "$*" >> "$work/calls"
    if [[ $1 == apt-get && $2 == install ]]; then
        if [[ $scenario == package-retry && ! -f $work/install-attempt ]]; then
            touch "$work/install-attempt"
            return 1
        fi
        touch "$work/plugins"
    fi
    return 0
}
docker() {
    case $1 in
        context)
            if [[ $2 == show ]]; then printf 'default\n'
            elif [[ $scenario == rootless ]]; then printf 'unix:///run/user/1000/docker.sock\n'
            elif [[ $scenario == remote ]]; then printf 'tcp://remote.example:2376\n'
            else printf 'unix:///var/run/docker.sock\n'; fi;;
        info)
            case $scenario in
                permissions) printf 'permission denied while connecting to socket\n' >&2; return 1;;
                stopped|broken|rootless|retry) [[ -f $work/started ]] || return 1;;
                slow-start)
                    [[ -f $work/started ]] || return 1
                    if [[ ! -f $work/first-probe ]]; then touch "$work/first-probe"; return 1; fi;;
            esac;;
        compose|buildx)
            if [[ $scenario == plugins || $scenario == missing-packages || $scenario == package-retry ]]; then [[ -f $work/plugins ]]; fi;;
        *) return 1;;
    esac
}
unset DOCKER_HOST DOCKER_CONTEXT
require_admin
if [[ $scenario == service-* ]]; then
    service_manager() { printf '%s\n' "${scenario#service-}"; }
    docker_start_service
    case $scenario in
        service-systemd) grep -qx 'systemctl start docker' "$work/calls";;
        service-openrc) grep -qx 'rc-service docker start' "$work/calls";;
        service-sysv) grep -qx 'service docker start' "$work/calls";;
    esac
    exit 0
fi
bootstrap_docker
case $scenario in
    ready) [[ ! -f $work/calls ]];;
    stopped|retry) [[ -f $work/started && ! -f $work/elevated ]];;
    slow-start)
        [[ -f $work/first-probe ]]
        if grep -q docker_retry_confirm "$work/calls"; then exit 1; fi;;
    plugins|package-retry)
        [[ -f $work/plugins ]]
        grep -q 'apt-get install -y --no-remove --no-upgrade docker-compose-v2 docker-buildx' "$work/calls";;
    *) printf 'Unexpected continuation: %s\n' "$scenario" >&2; exit 1;;
esac

#!/usr/bin/env bash
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$GDM_ROOT/lib/core.sh"
source "$GDM_ROOT/lib/system.sh"
ip() {
    if [[ $* == *'route show default'* ]]; then printf '[{"dev":"ens18"}]\n'
    else printf '[{"ifname":"docker0","addr_info":[{"family":"inet","scope":"global","local":"172.17.0.1"}]},{"ifname":"ens18","addr_info":[{"family":"inet","scope":"global","local":"192.168.0.33"}]}]\n'; fi
}
[[ $(server_primary_address) == 192.168.0.33 ]]
ip() { printf '[]\n'; }
[[ $(server_primary_address) == localhost ]]
ss() { :; }
docker() { printf '0.0.0.0:8443->443/tcp, [::]:8443->443/tcp\n'; }
if port_free 8443; then exit 1; fi
port_free 443
ss() { printf 'LISTEN 0 128 0.0.0.0:80 0.0.0.0:*\n'; }
if port_free 80; then exit 1; fi
ip() { return 1; }
[[ $(server_primary_address) == localhost ]]

#!/usr/bin/env bash
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
# shellcheck source=lib/core.sh
source "$GDM_ROOT/lib/core.sh"
tr_load
curl() {
    local input
    [[ $1 == --config && $2 == - ]]
    [[ $* != *"$GITHUB_TOKEN"* ]]
    input=$(cat)
    [[ $input == "header = \"Authorization: Bearer $GITHUB_TOKEN\"" ]]
    printf 'fixture-response'
}
for token in legacy_test_token ghs_123_header.payload-with_dash.signature 'opaque._~+/=='; do
    GITHUB_TOKEN=$token
    [[ $(http_get https://api.github.com/repos/glpi-project/glpi/releases) == fixture-response ]]
done
for token in 'quote"injection' 'backslash\injection' 'embedded=padding' 'space token' $'newline\ninjection' $'return\rinjection'; do
    GITHUB_TOKEN=$token
    if (http_get https://api.github.com/repos/glpi-project/glpi/releases) >/dev/null 2>&1; then
        printf '%s\n' 'Unsafe authorization input was accepted' >&2
        exit 1
    fi
done
curl() { [[ $1 != --config ]]; printf 'public-response'; }
[[ $(http_get https://hub.docker.com/v2/repositories/library/mysql/tags) == public-response ]]

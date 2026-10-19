#!/usr/bin/env bash
set -Eeuo pipefail
GDM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export GDM_ROOT
# shellcheck source=lib/core.sh
source "$GDM_ROOT/lib/core.sh"
trap ui_restore EXIT
trap 'exit 130' INT
tr_load
password=''
root_password=''
case ${1:-confirm} in
    confirm) if confirm install_confirm; then printf 'ACCEPTED\n'; else printf 'DECLINED\n'; fi;;
    ask) ask answer selection; [[ $answer == chosen ]]; printf 'ASSIGNED\n';;
    secret) secret_prompt password; [[ $password == test_password_123456789 ]]; printf 'SECRET_ASSIGNED\n';;
    root) secret_prompt root_password; [[ $root_password == test_password_123456789 ]]; printf 'ROOT_ASSIGNED\n';;
esac

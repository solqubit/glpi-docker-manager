#!/usr/bin/env bash
# Variables inside sh -c must expand in the container, not on the host.
# shellcheck disable=SC2016
dc() {
    docker compose --project-name "$(cfg project)" --env-file "$STATE/current/.env" -f "$STATE/current/compose.json" "$@"
}
volume_name() { printf '%s_%s\n' "$(cfg project)" "$1"; }
volumes_ensure() {
    local role name label directory device
    local -a options=()
    for role in glpi_data db_data plugins marketplace caddy_data caddy_config; do
        name=$(volume_name "$role")
        options=()
        if [[ $(cfg storage) == directory ]]; then
            directory=$(data_directory "$role")
            [[ ! -L $STATE/data && ! -L $STATE/data/$(cfg id) && ! -L $directory ]] || die bad_path
            mkdir -p -- "$directory"
            device="${GDM_BIND_STATE:-$STATE}/data/$(cfg id)/$role"
            options=(--driver local --opt type=none --opt o=bind --opt "device=$device")
        fi
        if docker volume inspect "$name" >/dev/null 2>&1; then
            label=$(docker volume inspect -f '{{index .Labels "org.glpidm.installation"}}' "$name")
            [[ $label == "$(cfg id)" ]] || die foreign_resource "$name"
            if [[ $(cfg storage) == directory ]]; then
                [[ $(docker volume inspect -f '{{index .Options "device"}}' "$name") == "$device" ]] || die foreign_resource "$name"
            fi
        else
            docker volume create "${options[@]}" --label "org.glpidm.installation=$(cfg id)" --label "org.glpidm.role=$role" "$name" >/dev/null
        fi
    done
}
pull_images() {
    local data_need=${1:-0} image image_need
    local -a images=("$(cfg glpi_image)" "$(cfg mysql_image)")
    [[ $(cfg tls) == off ]] || images+=("$(cfg caddy_image)")
    image_need=$(image_storage_budget "${images[@]}")
    storage_preflight "$image_need" "$data_need"
    for image in "${images[@]}"; do
        if docker image inspect "$image" >/dev/null 2>&1; then say storage_image_cached "${image%@*}"
        else ui_status "$(t status_pulling "${image%@*}")"; docker pull --quiet "$image"; fi
    done
}
wait_healthy() {
    local service=$1 timeout=${2:-300} elapsed=0 id status
    while (( elapsed < timeout )); do
        id=$(dc ps --all --quiet "$service")
        ui_status "$(t status_waiting "$service" "${status:-...}" "$elapsed")"
        if [[ -n $id ]]; then
            status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")
            [[ $status != healthy ]] || return 0
            [[ $status != exited && $status != dead && $status != unhealthy ]] || break
        fi
        sleep 2; ((elapsed+=2))
    done
    say unhealthy "$service"
    return 1
}
console() { dc exec -T glpi php bin/console "$@" --no-interaction; }
oneoff_console() {
    dc run --rm --no-deps -T -e GLPI_CRONTAB_ENABLED=0 --entrypoint php glpi bin/console "$@" --no-interaction
}
command_select() {
    local action=$1 available=$2 candidate candidates
    case $action in
        requirements) candidates='system:check_requirements glpi:system:check_requirements';;
        update) candidates='database:update db:update glpi:database:update';;
        schema) candidates='database:check_schema_integrity db:check glpi:database:check_schema_integrity';;
        version) candidates='database:is_up_to_date glpi:database:is_up_to_date';;
        *) return 1;;
    esac
    for candidate in $candidates; do
        if awk '{print $1}' <<< "$available" | grep -Fxq "$candidate"; then printf '%s\n' "$candidate"; return; fi
    done
    say invalid "unsupported GLPI CLI action: $action"
    return 1
}
oneoff_action() {
    local action=$1 command available
    shift
    available=$(oneoff_console list --raw) || return 1
    if ! command=$(command_select "$action" "$available" 2>/dev/null); then
        if [[ $action == version && $(cfg major) == 10 ]]; then legacy_database_version; return; fi
        say invalid "unsupported GLPI CLI action: $action"
        return 1
    fi
    ui_status "$(t status_console "$command")"
    oneoff_console "$command" "$@"
}
legacy_database_version() {
    local installed
    installed=$(dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" exec mysql -u"$GDM_DB_USER" "$MYSQL_DATABASE" -Ns' <<'SQL'
SELECT value FROM glpi_configs WHERE context='core' AND name='version';
SQL
    ) || return 1
    [[ $installed == "$(cfg glpi_version)" ]]
}
database_check() {
    dc exec -T db sh -c 'MYSQL_PWD="$GDM_DB_PASSWORD" mysql --protocol=TCP -h 127.0.0.1 -u"$GDM_DB_USER" "$MYSQL_DATABASE" -Nse "SELECT 1"' >/dev/null
}
schema_check() {
    local available command
    available=$(console list --raw) || return 1
    if command=$(command_select version "$available" 2>/dev/null); then
        console "$command" --quiet || return 1
    elif [[ $(cfg major) == 10 ]]; then legacy_database_version || return 1
    else return 1; fi
    command=$(command_select schema "$available") || return 1
    console "$command" --quiet
}
http_check() {
    local code
    if [[ $(cfg tls) == off ]]; then
        code=$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' "http://${GDM_PROBE_HOST:-127.0.0.1}:$(cfg http_port)/") || return 1
    else
        local -a trust=()
        [[ $(cfg tls) != self-signed ]] || trust=(--cacert "$STATE/current/tls/fullchain.pem")
        code=$(curl --silent --show-error --max-time 15 "${trust[@]}" --connect-to "$(cfg hostname):$(cfg https_port):${GDM_PROBE_HOST:-127.0.0.1}:$(cfg https_port)" \
            --output /dev/null --write-out '%{http_code}' "https://$(cfg hostname):$(cfg https_port)/") || return 1
    fi
    [[ $code =~ ^(200|301|302|303)$ ]]
}
verify_services() {
    wait_healthy db && database_check && wait_healthy glpi || return 1
    ui_status "$(t status_schema)"
    schema_check || return 1
    local attempt
    for (( attempt=0; attempt<30; attempt++ )); do
        ui_status "$(t status_http "$((attempt+1))")"
        if http_check; then return 0; fi
        sleep 2
    done
    return 1
}
install_database() {
    # Let the official entrypoint initialize DB credentials without exposing them in
    # host arguments. Normal services permanently disable automatic installation.
    dc run --rm --no-deps -T -e GLPI_SKIP_AUTOINSTALL=false -e GLPI_SKIP_AUTOUPDATE=true \
        -e GLPI_CRONTAB_ENABLED=0 glpi php bin/console --version
}
initialize_plugin_volume() {
    # Named volumes hide image content at these paths. Empty custom plugin dirs
    # must be writable by the same user as the official GLPI image.
    dc run --rm --no-deps -T --user root --entrypoint sh glpi -c \
      'chown www-data:www-data /var/www/glpi/plugins; if [ "$GLPI_MARKETPLACE_DIR" = /var/www/glpi/marketplace ]; then chown www-data:www-data /var/www/glpi/marketplace; fi'
}
assert_running() {
    [[ $(dc ps --status running --quiet glpi) && $(dc ps --status running --quiet db) ]] || die services_required
}

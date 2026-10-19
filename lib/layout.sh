#!/usr/bin/env bash
# The application root contains operational code, configuration and persistent data.
# shellcheck disable=SC2034
layout_install_code() {
    local path checksum destination temporary root_resolved manager_resolved
    root_resolved=$(readlink -f -- "$GDM_ROOT")
    manager_resolved=$(readlink -f -- "$STATE/manager") || manager_resolved=''
    [[ $root_resolved != "$(readlink -f -- "$STATE")" ]] || die layout_checkout_in_root "$STATE"
    if [[ $root_resolved == "$manager_resolved" ]]; then layout_write_entrypoint; return; fi
    [[ ! -e $STATE/manager || -L $STATE/manager ]] || die layout_code_conflict "$STATE/manager"
    local -a files=(start.sh VERSION LICENSE README.md README.es.md CONTRIBUTING.md .env.example)
    for path in "$GDM_ROOT"/lib/*.sh "$GDM_ROOT"/locales/*.tsv "$GDM_ROOT"/templates/*.sh "$GDM_ROOT"/tools/*.py "$GDM_ROOT"/docs/*.md; do
        files+=("${path#"$GDM_ROOT"/}")
    done
    checksum=$(for path in "${files[@]}"; do printf '%s\n' "$path"; sha256sum < "$GDM_ROOT/$path"; done | sha256sum | cut -c1-16)
    destination="$STATE/manager-releases/$checksum"
    if [[ ! -d $destination ]]; then
        mkdir -p -- "$STATE/manager-releases"
        temporary=$(mktemp -d "$STATE/manager-releases/.new-XXXXXX")
        for path in "${files[@]}"; do
            mkdir -p -- "$temporary/$(dirname -- "$path")"
            cp -- "$GDM_ROOT/$path" "$temporary/$path"
        done
        chmod 755 "$temporary/start.sh"
        mv -- "$temporary" "$destination"
    fi
    ln -s "manager-releases/$checksum" "$STATE/.manager.new"
    mv -Tf -- "$STATE/.manager.new" "$STATE/manager"
    layout_write_entrypoint
}
layout_write_entrypoint() {
    [[ ! -e $STATE/start.sh || -f $STATE/.gdm-entrypoint ]] || die layout_code_conflict "$STATE/start.sh"
    cat > "$STATE/.start.new" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec bash "$root/manager/start.sh" --state-dir "$root" "$@"
ENTRYPOINT
    chmod 755 "$STATE/.start.new"
    mv -f -- "$STATE/.start.new" "$STATE/start.sh"
    : > "$STATE/.gdm-entrypoint"
}
data_directory() {
    local role=$1
    case $role in glpi_data|db_data|plugins|marketplace|caddy_data|caddy_config) ;; *) die invalid volume_role;; esac
    printf '%s/data/%s/%s\n' "$STATE" "$(cfg id)" "$role"
}

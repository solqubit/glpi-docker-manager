#!/usr/bin/env bash
# Every dc/volume call needs configuration values; reading them used to start
# one jq process each. Validated top-level scalars are cached once per active
# revision. A different revision behind $CONFIG (-ef) falls back to jq, and the
# writers below (config_activate, config_set_status, language) refresh it.
declare -A CFG_CACHE=()
CFG_CACHE_SOURCE=''
cfg_cache() {
    local key value
    CFG_CACHE=() CFG_CACHE_SOURCE=''
    [[ -r ${CONFIG:-} ]] || return 0
    while IFS=$'\t' read -r key value; do CFG_CACHE[$key]=$value; done < <(
        jq -r 'to_entries[] | select(.value|type!="object" and type!="array") |
               select(.value|tostring|test("[\t\n\r]")|not) | "\(.key)\t\(.value|tostring)"' "$CONFIG")
    CFG_CACHE_SOURCE=$(readlink -f -- "$CONFIG")
}
cfg() {
    if [[ -n $CFG_CACHE_SOURCE && -n ${CFG_CACHE[$1]+set} && ${CONFIG:-} -ef $CFG_CACHE_SOURCE ]]; then
        printf '%s\n' "${CFG_CACHE[$1]}"
        # Same exit status as jq -e: false and null are failures.
        [[ ${CFG_CACHE[$1]} != false && ${CFG_CACHE[$1]} != null ]]
        return
    fi
    jq -er ".$1" "$CONFIG"
}
config_validate() {
    jq -e '
      .format==1 and (.id|test("^[a-f0-9]{16}$")) and
      (.project|test("^gdm_[a-f0-9]{16}$")) and
      (.glpi_version|test("^[1-9][0-9]*\\.[0-9]+\\.[0-9]+$")) and
      (.major>=10 and .major<=999) and
      .major==(.glpi_version|split(".")[0]|tonumber) and
      (.mysql_version|test("^8\\.4\\.[0-9]+$")) and
      (.glpi_image|test("^glpi/glpi:[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$")) and
      (.mysql_image|test("^mysql:8\\.4\\.[0-9]+@sha256:[a-f0-9]{64}$")) and
      (.caddy_image|test("^caddy:[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$")) and
      (.db_name|test("^[a-zA-Z][a-zA-Z0-9_]{0,31}$")) and
      (.db_user|test("^[a-zA-Z][a-zA-Z0-9_]{0,31}$")) and
      (.db_user!="root") and
      ([.db_password,.root_password]|all(type=="string" and length>0 and (explode|all(.>=32 and .!=127)))) and
      (.root_password|explode|all(.!=34 and .!=39 and .!=92)) and
      (.http_port|type=="number" and .>=1 and .<=65535 and floor==.) and
      (.https_port|type=="number" and .>=1 and .<=65535 and floor==.) and
      (.http_port!=.https_port) and
      (.expose_db|type=="boolean") and
      (if .expose_db then .http_port!=3306 and .https_port!=3306 else true end) and
      (.timezone|test("^[A-Za-z0-9_+/-]+$")) and
      (.language=="en" or .language=="es") and
      ((has("mode")|not) or .mode=="test" or .mode=="production") and
      (.tls=="off" or .tls=="self-signed" or .tls=="acme" or .tls=="custom") and
      (.hostname|test("^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$")) and
      (.cert_dir|test("^/[A-Za-z0-9_./-]+$")) and
      (.storage=="named" or .storage=="directory") and
      (.status=="configured" or .status=="ready")
    ' "$1" >/dev/null || die invalid configuration
    [[ $(jq -r .glpi_image "$1") == "glpi/glpi:$(jq -r .glpi_version "$1")@"* ]] || die invalid image
    [[ $(jq -r .mysql_image "$1") == "mysql:$(jq -r .mysql_version "$1")@"* ]] || die invalid image
    local zone
    zone=$(jq -r .timezone "$1")
    [[ $zone != *..* && -f /usr/share/zoneinfo/$zone ]] || die invalid timezone
}
config_load() {
    [[ -L $STATE/current && -r $STATE/current/config.json ]] || die not_installed
    CONFIG="$STATE/current/config.json"
    config_validate "$CONFIG"
    cfg_cache
    LANGUAGE=${LANGUAGE_OVERRIDE:-$(cfg language)}; tr_load
}
dotenv_line() {
    local value=$2
    # Compose expands double-quoted dotenv values. Escape dollars before using
    # JSON string encoding for quotes/backslashes (including a trailing slash).
    value=${value//\$/\$\$}
    printf '%s=' "$1"
    printf '%s' "$value" | jq -Rs .
}
# InnoDB buffer pool from the host's RAM, recalculated whenever a revision is
# rendered (install, updates, settings, restore): 25 % of MemTotal because GLPI,
# Apache and Caddy share the host, kept between 256 MiB and 8 GiB. From 1 GiB
# MySQL splits the pool into instances, so whole GiB avoid an upward rounding.
# GDM_MEMINFO points to another meminfo file (tests).
mysql_buffer_pool_mb() {
    local kb mb
    kb=$(awk '/^MemTotal:/ {print $2; exit}' "${GDM_MEMINFO:-/proc/meminfo}" 2>/dev/null) || kb=''
    # Unknown RAM: MySQL's own default.
    [[ $kb =~ ^[0-9]+$ ]] || { printf '128\n'; return 0; }
    mb=$(( kb / 1024 / 4 ))
    if (( mb >= 1024 )); then mb=$(( mb / 1024 * 1024 )); else mb=$(( mb / 128 * 128 )); fi
    (( mb >= 256 )) || mb=256
    (( mb <= 8192 )) || mb=8192
    printf '%s\n' "$mb"
}
config_render() {
    local file=$1 dir=$2 major tls secure source_prefix log_mb=10 log_files=3 binlog_days=30 buffer_mb
    config_validate "$file"
    # Container and MySQL binary-log limits from the root's maintenance.json
    # (set in Log rotation); only the values that screen offers are accepted.
    if [[ -r $STATE/maintenance.json ]]; then
        read -r log_mb log_files binlog_days < <(jq -r '[(.logs.container_mb // 10), (.logs.container_files // 3),
            (.logs.binlog_days // 30)] | map(tostring) | join(" ")' "$STATE/maintenance.json" 2>/dev/null) || true
    fi
    [[ " 10 20 50 100 " == *" $log_mb "* ]] || log_mb=10
    [[ " 3 5 " == *" $log_files "* ]] || log_files=3
    [[ " 1 3 7 30 " == *" $binlog_days "* ]] || binlog_days=30
    buffer_mb=$(mysql_buffer_pool_mb)
    mkdir -p -- "$dir"
    cp -- "$file" "$dir/config.json"
    major=$(jq -r .major "$file"); tls=$(jq -r .tls "$file")
    source_prefix=${GDM_BIND_STATE:-$STATE}/revisions/$(basename "$dir")
    {
        dotenv_line GLPI_DB_HOST db
        dotenv_line GLPI_DB_PORT 3306
        dotenv_line GLPI_DB_NAME "$(jq -r .db_name "$file")"
        dotenv_line GLPI_DB_USER "$(jq -r .db_user "$file")"
        dotenv_line GLPI_DB_PASSWORD "$(jq -r .db_password "$file")"
        dotenv_line MYSQL_ROOT_PASSWORD "$(jq -r .root_password "$file")"
    } > "$dir/.env"
    secure=0; [[ $tls == off ]] || secure=1
    cat > "$dir/php-uploads.ini" <<EOF
upload_max_filesize = 50M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
date.timezone = $(jq -r .timezone "$file")
session.cookie_httponly = 1
session.cookie_samesite = Lax
session.cookie_secure = $secure
EOF
    # Resolve only the proxy on this installation's private Docker network.
    cat > "$dir/proxy.php" <<'EOF'
<?php
if (!defined('GLPI_TRUSTED_REVERSE_PROXIES')) {
    define('GLPI_TRUSTED_REVERSE_PROXIES', gethostbynamel('proxy') ?: []);
}
if (!defined('GLPI_REVERSE_PROXY_HEADERS')) {
    define('GLPI_REVERSE_PROXY_HEADERS', ['X-Forwarded-For', 'X-Forwarded-Proto', 'X-Forwarded-Host', 'X-Forwarded-Port']);
}
if (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
EOF
    cp -- "$GDM_ROOT/templates/mysql-user.sh" "$dir/mysql-user.sh"
    cp -- "$GDM_ROOT/templates/wait-for-db.sh" "$dir/wait-for-db.sh"
    jq -n --slurpfile s "$file" --arg root "$source_prefix" --argjson major "$major" \
        --arg log_size "${log_mb}m" --arg log_files "$log_files" --argjson binlog_seconds "$((binlog_days*86400))" \
        --arg buffer "${buffer_mb}M" '
      $s[0] as $c |
      def mount($src;$dst): {type:"bind",source:$src,target:$dst,read_only:true,bind:{create_host_path:false,selinux:"Z"}};
      {name:$c.project,
       services:{
        glpi:{image:$c.glpi_image,restart:"unless-stopped",
          environment:{TZ:$c.timezone,GLPI_DB_HOST:"db",GLPI_DB_PORT:"3306",GLPI_DB_NAME:$c.db_name,
            GLPI_DB_USER:$c.db_user,GLPI_DB_PASSWORD:"${GLPI_DB_PASSWORD}",GLPI_SKIP_AUTOINSTALL:"true",
            GLPI_SKIP_AUTOUPDATE:"true",GLPI_CRONTAB_ENABLED:"1"},
          volumes:(["glpi_data:/var/glpi","plugins:/var/www/glpi/plugins",
            mount($root+"/php-uploads.ini";"/usr/local/etc/php/conf.d/99-uploads.ini"),
            mount($root+"/wait-for-db.sh";"/opt/glpi/entrypoint/wait-for-db.sh")] +
            (if $major==10 then ["marketplace:/var/www/glpi/marketplace"] else [] end)),
          depends_on:{db:{condition:"service_healthy"}},
          healthcheck:{test:["CMD","php","-r","exit(@file_get_contents(\"http://127.0.0.1/\", false, stream_context_create([\"http\"=>[\"header\"=>\"X-Forwarded-Proto: https\\r\\n\"]])) === false ? 1 : 0);"],interval:"10s",timeout:"5s",retries:30,start_period:"30s"},
          networks:["backend"]},
        db:{image:$c.mysql_image,restart:"unless-stopped",
          environment:{TZ:$c.timezone,MYSQL_DATABASE:$c.db_name,GDM_DB_USER:$c.db_user,
            GDM_DB_PASSWORD:"${GLPI_DB_PASSWORD}",MYSQL_ROOT_PASSWORD:"${MYSQL_ROOT_PASSWORD}",MYSQL_ROOT_HOST:"localhost"},
          volumes:["db_data:/var/lib/mysql",mount($root+"/mysql-user.sh";"/docker-entrypoint-initdb.d/10-gdm-user.sh")],networks:["backend"],
          healthcheck:{test:["CMD-SHELL","MYSQL_PWD=\"$$GDM_DB_PASSWORD\" mysql --protocol=TCP -h 127.0.0.1 -u\"$$GDM_DB_USER\" \"$$MYSQL_DATABASE\" -Nse \u0027SELECT 1\u0027 >/dev/null"],interval:"5s",timeout:"5s",retries:60,start_period:"30s"}}
       },
       volumes:(reduce ["glpi_data","db_data","plugins","marketplace","caddy_data","caddy_config"][] as $v ({};
          .[$v]={name:($c.project+"_"+$v),external:true})),
       networks:{backend:{},proxy:{}}}
      | if $c.expose_db then .services.db.ports=["3306:3306"] else . end
      | if $c.tls=="off" then .services.glpi.ports=[($c.http_port|tostring)+":80"]
        else
          .services.glpi.networks += ["proxy"] |
          .services.glpi.volumes += [mount($root+"/proxy.php";"/etc/gdm/proxy.php")] |
          .services.proxy={image:$c.caddy_image,restart:"unless-stopped",depends_on:["glpi"],
            ports:[($c.http_port|tostring)+":80",($c.https_port|tostring)+":443"],
            networks:["proxy"],
            volumes:([mount($root+"/Caddyfile";"/etc/caddy/Caddyfile"),"caddy_data:/data","caddy_config:/config"] +
              (if $c.tls=="acme" then [] else [mount($root+"/tls";"/etc/gdm/tls")] end) +
              (if $c.tls=="self-signed" then [mount($root+"/public";"/etc/gdm/public")] else [] end))}
        end
      # Container logs rotate (default 3 x 10 MiB per service); MySQL binary logs
      # expire after the chosen days (default 30, the MySQL default). The buffer
      # pool follows the host RAM (mysql_buffer_pool_mb).
      | .services |= with_entries(.value.logging={driver:"json-file",options:{"max-size":$log_size,"max-file":$log_files}})
      | .services.db.command=["--binlog-expire-logs-seconds=\($binlog_seconds)","--innodb-buffer-pool-size=\($buffer)"]
    ' > "$dir/compose.json"
    if [[ $tls != off ]]; then printf '\nauto_prepend_file = /etc/gdm/proxy.php\n' >> "$dir/php-uploads.ini"; fi
    chmod 600 "$dir/config.json" "$dir/compose.json" "$dir/.env"
    # Non-secret files must be readable by www-data/mysql inside bind mounts.
    chmod 644 "$dir/php-uploads.ini" "$dir/proxy.php" "$dir/mysql-user.sh"
    chmod 755 "$dir/wait-for-db.sh"
}
config_stage() {
    local file=$1
    REVISION="$STATE/revisions/$(date -u +%Y%m%dT%H%M%S)-$(openssl rand -hex 4)"
    config_render "$file" "$REVISION"
    tls_prepare "$REVISION/config.json" "$REVISION"
    docker compose --env-file "$REVISION/.env" -f "$REVISION/compose.json" config --quiet
}
config_activate() {
    local revision=$1
    ln -s "revisions/$(basename "$revision")" "$STATE/.current.new"
    mv -Tf -- "$STATE/.current.new" "$STATE/current"
    CONFIG="$STATE/current/config.json"
    cfg_cache
}
config_set_status() {
    local tmp
    tmp=$(mktemp "$STATE/.config.XXXXXX"); CLEANUP_PATHS+=("$tmp")
    jq --arg status "$1" '.status=$status' "$CONFIG" > "$tmp"
    mv -- "$tmp" "$(readlink -f "$CONFIG")"
    cfg_cache
}

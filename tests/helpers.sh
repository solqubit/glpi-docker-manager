#!/usr/bin/env bash
test_config() {
    local file=$1 id=${2:-0123456789abcdef} digest
    digest=$(printf '0%.0s' {1..64})
    jq -n --arg id "$id" --arg digest "$digest" --arg cert_dir "$CERT_ROOT" '{
      format:1,id:$id,project:("gdm_"+$id),major:11,glpi_version:"11.0.11",
      glpi_image:("glpi/glpi:11.0.11@sha256:"+$digest),mysql_version:"8.4.11",
      mysql_image:("mysql:8.4.11@sha256:"+$digest),caddy_image:("caddy:2.10.2@sha256:"+$digest),
      mode:"test",http_port:18080,https_port:18443,timezone:"UTC",db_name:"glpi",db_user:"glpi",
      db_password:"test_password_123456789",root_password:"root_password_123456789",
      language:"en",cert_dir:$cert_dir,expose_db:false,hostname:"localhost",tls:"off",storage:"named",status:"configured"
    }' > "$file"
}

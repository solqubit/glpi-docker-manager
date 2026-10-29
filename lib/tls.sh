#!/usr/bin/env bash
# Self-signed HTTPS uses a local certificate authority: the 20-year CA
# certificate (gdm-ca.pem) is installed once in GLPI Agents ("CA Certificate
# File") and browsers; the server certificate it signs lasts 825 days (accepted
# by Apple platforms) and is renewed automatically without touching any client.
TLS_CA_DAYS=7305
TLS_SERVER_DAYS=825
tls_is_ip() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
tls_validate_pair() {
    local dir=$1 hostname=$2 certificate_key private_key
    [[ -f $dir/fullchain.pem && -f $dir/privkey.pem ]] || die cert_instructions "$dir/fullchain.pem" "$dir/privkey.pem"
    openssl x509 -in "$dir/fullchain.pem" -noout -checkend 86400 >/dev/null || die cert_bad_expiry
    if tls_is_ip "$hostname"; then
        openssl x509 -in "$dir/fullchain.pem" -noout -checkip "$hostname" | grep -q 'does match' || die cert_bad_host "$hostname"
    else
        openssl x509 -in "$dir/fullchain.pem" -noout -checkhost "$hostname" | grep -q 'does match' || die cert_bad_host "$hostname"
    fi
    certificate_key=$(openssl x509 -in "$dir/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
    private_key=$(openssl pkey -in "$dir/privkey.pem" -passin pass: -pubout -outform DER | sha256sum)
    [[ $certificate_key == "$private_key" ]] || die cert_bad_key
}
# Creates the local CA once (or when it is about to expire / on request).
tls_ca_ensure() {
    local folder=$1 fresh
    if [[ ${GDM_TLS_NEW_CA:-} != 1 && -f $folder/gdm-ca.pem && -f $folder/gdm-ca.key ]] &&
        openssl x509 -in "$folder/gdm-ca.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
        return 0
    fi
    mkdir -p -- "$folder"; chmod 700 "$folder"
    fresh=$(mktemp -d "$folder/.new-XXXXXX")
    # A random suffix keeps a regenerated CA distinguishable in client stores.
    printf '[req]\ndistinguished_name = dn\nx509_extensions = ca\nprompt = no\n[dn]\nO = GLPI Docker Manager\nCN = GLPI Docker Manager Local CA %s\n[ca]\nbasicConstraints = critical,CA:TRUE,pathlen:0\nkeyUsage = critical,keyCertSign,cRLSign\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always\n' \
        "$(openssl rand -hex 4)" > "$fresh/ca.cnf"
    openssl req -x509 -config "$fresh/ca.cnf" -newkey rsa:4096 -sha256 -days "$TLS_CA_DAYS" -nodes \
        -keyout "$fresh/gdm-ca.key" -out "$fresh/gdm-ca.pem" >/dev/null 2>&1
    chmod 600 "$fresh/gdm-ca.key"; chmod 644 "$fresh/gdm-ca.pem"
    mv -- "$fresh/gdm-ca.key" "$folder/gdm-ca.key"
    mv -- "$fresh/gdm-ca.pem" "$folder/gdm-ca.pem"
    rm -f -- "$fresh/ca.cnf"; rmdir -- "$fresh"
    say ca_created "$folder/gdm-ca.pem"
}
# Server certificate for HOST (IP or DNS name), signed by the local CA.
tls_server_issue() {
    local source=$1 ca=$2 host=$3 san fresh
    san="DNS:$host"
    ! tls_is_ip "$host" || san="IP:$host"
    fresh=$(mktemp -d "$source/.new-XXXXXX")
    openssl req -new -newkey rsa:3072 -sha256 -nodes -subj "/CN=$host" \
        -keyout "$fresh/privkey.pem" -out "$fresh/request.csr" >/dev/null 2>&1
    printf 'basicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature,keyEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = %s\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid,issuer\n' \
        "$san" > "$fresh/server.cnf"
    openssl x509 -req -in "$fresh/request.csr" -CA "$ca/gdm-ca.pem" -CAkey "$ca/gdm-ca.key" \
        -set_serial "0x$(openssl rand -hex 16)" -days "$TLS_SERVER_DAYS" -sha256 \
        -extfile "$fresh/server.cnf" -out "$fresh/server.pem" >/dev/null 2>&1
    # Leaf first, then the CA, as clients expect in a full chain.
    cat "$fresh/server.pem" "$ca/gdm-ca.pem" > "$fresh/fullchain.pem"
    tls_validate_pair "$fresh" "$host"
    mv -- "$fresh/fullchain.pem" "$source/fullchain.pem"
    mv -- "$fresh/privkey.pem" "$source/privkey.pem"
    rm -f -- "$fresh/request.csr" "$fresh/server.cnf" "$fresh/server.pem"; rmdir -- "$fresh"
    say self_signed "$source/fullchain.pem"
}
# The server certificate needs a new issue when missing, expiring within 30
# days, for another address, forced, or not signed by the current local CA.
tls_server_current() {
    local source=$1 ca=$2 host=$3
    [[ ${GDM_TLS_FORCE_RENEW:-} != 1 && -f $source/fullchain.pem && -f $source/privkey.pem ]] || return 1
    openssl x509 -in "$source/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
    if tls_is_ip "$host"; then
        openssl x509 -in "$source/fullchain.pem" -noout -checkip "$host" 2>/dev/null | grep -q 'does match' || return 1
    else
        openssl x509 -in "$source/fullchain.pem" -noout -checkhost "$host" 2>/dev/null | grep -q 'does match' || return 1
    fi
    openssl x509 -in "$source/fullchain.pem" 2>/dev/null | openssl verify -CAfile "$ca/gdm-ca.pem" >/dev/null 2>&1
}
# URL where clients download the CA certificate (plain HTTP, port aware).
tls_ca_url() {
    local host=$1 port=$2
    if [[ $port == 80 ]]; then printf 'http://%s/gdm-ca.pem\n' "$host"
    else printf 'http://%s:%s/gdm-ca.pem\n' "$host" "$port"; fi
}
tls_prepare() {
    local file=$1 revision=$2 mode host cert_dir source ca redirect http_port https_port agent_routes=''
    mode=$(jq -r .tls "$file"); host=$(jq -r .hostname "$file")
    cert_dir=$(jq -r .cert_dir "$file")
    http_port=$(jq -r .http_port "$file"); https_port=$(jq -r .https_port "$file")
    [[ $mode != off ]] || return 0
    if agent_enabled "$file"; then
        agent_routes=$'    handle /agent/* {\n        root * /etc/gdm/public\n        file_server\n    }\n'
    fi
    mkdir -p "$revision/tls"
    if [[ $mode == acme ]]; then
        [[ $host == *.* && ! $host =~ ^[0-9.]+$ && $host != *.local && $host != *.localhost ]] || die invalid public_domain
        [[ $http_port == 80 && $https_port == 443 ]] || die acme_ports
        say acme_requirements "$host"
        if [[ -n $agent_routes ]]; then
            printf '{\n    auto_https disable_redirects\n}\nhttp://%s {\n%s    handle {\n        redir https://%s{uri} 308\n    }\n}\nhttps://%s {\n    tls {\n        ca https://acme-v02.api.letsencrypt.org/directory\n    }\n%s    handle {\n        reverse_proxy glpi:80\n    }\n}\n' "$host" "$agent_routes" "$host" "$host" "$agent_routes" > "$revision/Caddyfile"
        else
            printf '%s {\n    tls {\n        ca https://acme-v02.api.letsencrypt.org/directory\n    }\n    reverse_proxy glpi:80\n}\n' "$host" > "$revision/Caddyfile"
        fi
        return
    fi
    source="$cert_dir/$mode"
    mkdir -p -- "$source" || die permissions "$source"
    chmod 700 "$source"
    if [[ $mode == self-signed ]]; then
        ca="$source/ca"
        tls_ca_ensure "$ca"
        tls_server_current "$source" "$ca" "$host" || tls_server_issue "$source" "$ca" "$host"
        # Public CA certificate: copied with the revision and served over HTTP.
        mkdir -p "$revision/public"
        cp -- "$ca/gdm-ca.pem" "$revision/tls/gdm-ca.pem"
        cp -- "$ca/gdm-ca.pem" "$revision/public/gdm-ca.pem"
        chmod 755 "$revision/public"; chmod 644 "$revision/public/gdm-ca.pem"
    fi
    tls_validate_pair "$source" "$host"
    chmod 600 "$source/privkey.pem"
    cp -- "$source/fullchain.pem" "$source/privkey.pem" "$revision/tls/"
    chmod 600 "$revision/tls/"*
    redirect="https://$host"
    [[ $https_port == 443 ]] || redirect+=":$https_port"
    if [[ $mode == self-signed ]]; then
        # /gdm-ca.pem is the only file served from /etc/gdm/public; everything
        # else is redirected (HTTP) or proxied to GLPI (HTTPS).
        printf '{\n    default_sni %s\n    auto_https disable_redirects\n}\nhttp://%s {\n%s    handle /gdm-ca.pem {\n        root * /etc/gdm/public\n        file_server\n    }\n    handle {\n        redir %s{uri} 308\n    }\n}\nhttps://%s {\n    tls /etc/gdm/tls/fullchain.pem /etc/gdm/tls/privkey.pem\n%s    handle /gdm-ca.pem {\n        root * /etc/gdm/public\n        file_server\n    }\n    handle {\n        reverse_proxy glpi:80\n    }\n}\n' \
            "$host" "$host" "$agent_routes" "$redirect" "$host" "$agent_routes" > "$revision/Caddyfile"
    else
        printf '{\n    default_sni %s\n    auto_https disable_redirects\n}\nhttp://%s {\n%s    handle {\n        redir %s{uri} 308\n    }\n}\nhttps://%s {\n    tls /etc/gdm/tls/fullchain.pem /etc/gdm/tls/privkey.pem\n%s    handle {\n        reverse_proxy glpi:80\n    }\n}\n' \
            "$host" "$host" "$agent_routes" "$redirect" "$host" "$agent_routes" > "$revision/Caddyfile"
    fi
}
# The mode in use is marked, as in the other settings screens.
tls_mode_label() {
    local text
    text=$(t "ui_tls_$1")
    [[ $1 != "$2" ]] || text+=" $(t opt_current)"
    printf '%s' "$text"
}
tls_wizard() {
    local input=$1 output=$2 mode host current
    current=$(jq -r .tls "$input")
    choose mode tls_prompt "$current" \
        off "$(ui_opt '' "$(tls_mode_label off "$current")" "$(t opt_tls_off)")" \
        self-signed "$(ui_opt ok "$(tls_mode_label self-signed "$current")" "$(t opt_tls_self_signed)")" \
        acme "$(ui_opt primary "$(tls_mode_label acme "$current")" "$(t opt_tls_acme)")" \
        custom "$(ui_opt '' "$(tls_mode_label custom "$current")" "$(t opt_tls_custom)")" || die cancelled
    case $mode in off|self-signed|acme|custom) ;; *) die invalid tls;; esac
    # Imported files must exist before anything is asked or restarted.
    if [[ $mode == custom && ! ( -f $CERT_ROOT/custom/fullchain.pem && -f $CERT_ROOT/custom/privkey.pem ) ]]; then
        die cert_instructions "$CERT_ROOT/custom/fullchain.pem" "$CERT_ROOT/custom/privkey.pem"
    fi
    if [[ $mode == acme ]]; then
        ui_panel "$(t ui_letsencrypt_title)" "$(t ui_letsencrypt_body)" "$(t ui_letsencrypt_ports)"
        # A public name is required: an IP, localhost or .local would only fail later.
        while :; do
            ask_value host hostname_prompt '' hostname || die cancelled
            [[ $host == *.* && ! $host =~ ^[0-9.]+$ && $host != *.local && $host != *.localhost ]] && break
            say setup_public_domain
        done
    else ask_value host hostname_prompt "$(jq -r .hostname "$input")" hostname || die cancelled; fi
    [[ $mode != acme ]] || say acme_requirements "$host"
    jq --arg mode "$mode" --arg host "$host" --arg cert_dir "$CERT_ROOT" \
       '.tls=$mode | .hostname=$host | .cert_dir=$cert_dir | if $mode=="acme" then .http_port=80 | .https_port=443 else . end' "$input" > "$output"
}

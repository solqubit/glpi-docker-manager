#!/usr/bin/env bash
tls_validate_pair() {
    local dir=$1 hostname=$2 certificate_key private_key
    [[ -f $dir/fullchain.pem && -f $dir/privkey.pem ]] || die cert_instructions "$dir/fullchain.pem" "$dir/privkey.pem"
    openssl x509 -in "$dir/fullchain.pem" -noout -checkend 86400 >/dev/null || die invalid certificate
    if [[ $hostname =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        openssl x509 -in "$dir/fullchain.pem" -noout -checkip "$hostname" | grep -q 'does match' || die invalid certificate_hostname
    else
        openssl x509 -in "$dir/fullchain.pem" -noout -checkhost "$hostname" | grep -q 'does match' || die invalid certificate_hostname
    fi
    certificate_key=$(openssl x509 -in "$dir/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
    private_key=$(openssl pkey -in "$dir/privkey.pem" -passin pass: -pubout -outform DER | sha256sum)
    [[ $certificate_key == "$private_key" ]] || die invalid certificate_key
}
tls_prepare() {
    local file=$1 revision=$2 mode host cert_dir source san regenerate=false fresh redirect
    mode=$(jq -r .tls "$file"); host=$(jq -r .hostname "$file")
    cert_dir=$(jq -r .cert_dir "$file")
    [[ $mode != off ]] || return 0
    mkdir -p "$revision/tls"
    if [[ $mode == acme ]]; then
        [[ $host == *.* && ! $host =~ ^[0-9.]+$ && $host != *.local && $host != *.localhost ]] || die invalid public_domain
        [[ $(jq -r .http_port "$file") == 80 && $(jq -r .https_port "$file") == 443 ]] || die acme_ports
        say acme_requirements "$host"
        printf '%s {\n    tls {\n        ca https://acme-v02.api.letsencrypt.org/directory\n    }\n    reverse_proxy glpi:80\n}\n' "$host" > "$revision/Caddyfile"
        return
    fi
    source="$cert_dir/$mode"
    mkdir -p -- "$source" || die permissions "$source"
    chmod 700 "$source"
    if [[ $mode == self-signed ]]; then
        # Renewed 30 days before expiry (daily maintenance) or on request.
        if [[ ${GDM_TLS_FORCE_RENEW:-} == 1 ]]; then regenerate=true
        elif [[ ! -f $source/fullchain.pem || ! -f $source/privkey.pem ]]; then regenerate=true
        elif ! openssl x509 -in "$source/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1; then regenerate=true
        elif [[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            openssl x509 -in "$source/fullchain.pem" -noout -checkip "$host" 2>/dev/null | grep -q 'does match' || regenerate=true
        else openssl x509 -in "$source/fullchain.pem" -noout -checkhost "$host" 2>/dev/null | grep -q 'does match' || regenerate=true; fi
    fi
    if [[ $regenerate == true ]]; then
        san="DNS:$host"
        [[ ! $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || san="IP:$host"
        fresh=$(mktemp -d "$source/.new-XXXXXX")
        openssl req -x509 -newkey rsa:3072 -sha256 -days 365 -nodes \
            -keyout "$fresh/privkey.pem" -out "$fresh/fullchain.pem" \
            -subj "/CN=$host" -addext "subjectAltName=$san" >/dev/null 2>&1
        tls_validate_pair "$fresh" "$host"
        mv -- "$fresh/fullchain.pem" "$source/fullchain.pem"
        mv -- "$fresh/privkey.pem" "$source/privkey.pem"
        rmdir -- "$fresh"
        say self_signed "$source/fullchain.pem"
    fi
    tls_validate_pair "$source" "$host"
    chmod 600 "$source/privkey.pem"
    cp -- "$source/fullchain.pem" "$source/privkey.pem" "$revision/tls/"
    chmod 600 "$revision/tls/"*
    redirect="https://$host"
    [[ $(jq -r .https_port "$file") == 443 ]] || redirect+=":$(jq -r .https_port "$file")"
    printf '{\n    default_sni %s\n    auto_https disable_redirects\n}\nhttp://%s {\n    redir %s{uri} 308\n}\nhttps://%s {\n    tls /etc/gdm/tls/fullchain.pem /etc/gdm/tls/privkey.pem\n    reverse_proxy glpi:80\n}\n' \
        "$host" "$host" "$redirect" "$host" > "$revision/Caddyfile"
}
tls_wizard() {
    local input=$1 output=$2 mode host
    choose mode tls_prompt "$(jq -r .tls "$input")" \
        off "$(ui_opt '' "$(t ui_tls_off)" "$(t opt_tls_off)")" \
        self-signed "$(ui_opt ok "$(t ui_tls_self-signed)" "$(t opt_tls_self_signed)")" \
        acme "$(ui_opt primary "$(t ui_tls_acme)" "$(t opt_tls_acme)")" \
        custom "$(ui_opt '' "$(t ui_tls_custom)" "$(t opt_tls_custom)")" || die cancelled
    case $mode in off|self-signed|acme|custom) ;; *) die invalid tls;; esac
    if [[ $mode == acme ]]; then
        ui_panel "$(t ui_letsencrypt_title)" "$(t ui_letsencrypt_body)" "$(t ui_letsencrypt_ports)"
        ask_value host hostname_prompt '' hostname
    else ask_value host hostname_prompt "$(jq -r .hostname "$input")" hostname; fi
    [[ $mode != custom ]] || say cert_instructions "$CERT_ROOT/custom/fullchain.pem" "$CERT_ROOT/custom/privkey.pem"
    [[ $mode != acme ]] || say acme_requirements "$host"
    jq --arg mode "$mode" --arg host "$host" --arg cert_dir "$CERT_ROOT" \
       '.tls=$mode | .hostname=$host | .cert_dir=$cert_dir | if $mode=="acme" then .http_port=80 | .https_port=443 else . end' "$input" > "$output"
}

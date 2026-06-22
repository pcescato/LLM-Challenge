#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CADDY_TEMPLATE="${CADDY_TEMPLATE:-/etc/vpsmgr/templates/Caddyfile.site.j2}"

caddy_install() {
    ensure_root
    if command -v caddy &>/dev/null; then
        info "Caddy already installed"
        return 0
    fi
    apt-get update -qq
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy
    mkdir -p "$CADDY_SITES_DIR"
    if ! grep -q "import $CADDY_SITES_DIR/*" /etc/caddy/Caddyfile 2>/dev/null; then
        echo "import $CADDY_SITES_DIR/*.caddy" >> /etc/caddy/Caddyfile
    fi
    systemctl enable caddy
    systemctl restart caddy
    info "Caddy installed and configured"
}

caddy_add_site() {
    local domain="$1" webroot="$2" php_enable="${3:-false}" php_fpm_addr="${4:-}"
    local target_file="$CADDY_SITES_DIR/${domain}.caddy"
    sed -e "s/{{ domain }}/$domain/g" \
        -e "s|{{ webroot }}|$webroot|g" \
        -e "s/{{ php_enable }}/$php_enable/g" \
        -e "s/{{ php_fpm_addr }}/$php_fpm_addr/g" \
        "$CADDY_TEMPLATE" > "$target_file"
    chmod 644 "$target_file"
    systemctl reload caddy
    info "Caddy site block added for $domain"
}

caddy_remove_site() {
    local domain="$1"
    local target_file="$CADDY_SITES_DIR/${domain}.caddy"
    rm -f "$target_file"
    systemctl reload caddy
    info "Caddy site block removed for $domain"
}

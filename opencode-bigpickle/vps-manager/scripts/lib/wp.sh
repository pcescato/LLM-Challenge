#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WP_TEMPLATE="${WP_TEMPLATE:-/etc/vpsmgr/templates/wp-config.tmpl}"

wp_install_cli() {
    if command -v wp &>/dev/null; then
        info "WP-CLI already installed"
        return
    fi
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    info "WP-CLI installed"
}

wp_download() {
    local webroot="$1" version="${2:-latest}"
    sudo -u "$(stat -c '%U' "$webroot" 2>/dev/null || echo 'root')" \
        wp core download --path="$webroot" --version="$version" --allow-root 2>/dev/null || \
        wp core download --path="$webroot" --version="$version" --allow-root
    info "WordPress downloaded to ${webroot}"
}

wp_configure() {
    local webroot="$1" db_name="$2" db_user="$3" db_pass="$4" domain="$5"
    local salts
    salts="$(wp config shuffle-salts --allow-root 2>/dev/null || openssl rand -base64 40)"

    sed -e "s/{{ db_name }}/$db_name/g" \
        -e "s/{{ db_user }}/$db_user/g" \
        -e "s/{{ db_pass }}/$db_pass/g" \
        -e "s/{{ db_host }}/localhost/g" \
        -e "s/{{ table_prefix }}/wp_/g" \
        -e "s/{{ wp_debug }}/false/g" \
        -e "s|{{ salts }}|$salts|g" \
        "$WP_TEMPLATE" > "${webroot}/wp-config.php"

    chmod 600 "${webroot}/wp-config.php"
    chown "$(site_user_for "$domain")" "${webroot}/wp-config.php"
    info "wp-config.php written for ${domain}"
}

wp_install_site() {
    local webroot="$1" domain="$2"
    # WP admin credentials are TTY-only; this function is never called from API
    if [[ ! -t 0 ]]; then
        die "WordPress admin setup requires an interactive TTY"
    fi
    echo "=== WordPress Admin Setup for ${domain} ==="
    read -r -p "Admin username: " wp_admin_user
    read -r -s -p "Admin password: " wp_admin_pass
    echo
    read -r -p "Admin email: " wp_admin_email

    wp core install \
        --path="$webroot" \
        --url="https://${domain}" \
        --title="${domain}" \
        --admin_user="$wp_admin_user" \
        --admin_password="$wp_admin_pass" \
        --admin_email="$wp_admin_email" \
        --allow-root

    info "WordPress site installed for ${domain}"
    echo ""
    echo "<<<CREDENTIALS>>>"
    echo "WordPress Admin URL: https://${domain}/wp-admin"
    echo "Username: ${wp_admin_user}"
    echo "Password: ${wp_admin_pass}"
    echo "<<<CREDENTIALS>>>"
}

wp_install_full() {
    local webroot="$1" db_name="$2" db_user="$3" db_pass="$4" domain="$5"
    wp_download "$webroot"
    wp_configure "$webroot" "$db_name" "$db_user" "$db_pass" "$domain"
    wp_install_site "$webroot" "$domain"
}

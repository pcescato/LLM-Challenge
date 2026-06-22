#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PHP_TEMPLATE="${PHP_TEMPLATE:-/etc/vpsmgr/templates/php-pool.conf.j2}"

php_resolve_version() {
    local prefer="${1:-}"
    if [[ -n "$prefer" ]]; then
        echo "$prefer"
        return
    fi
    local latest=""
    latest="$(apt-cache search '^php[0-9]+\.[0-9]+$' 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -z "$latest" ]]; then
        latest="8.3"
    fi
    echo "$latest"
}

php_fallback_version() {
    local current="$1"
    local major="${current%%.*}"
    local minor="${current#*.}"
    local prev_minor=$((minor - 1))
    echo "${major}.${prev_minor}"
}

php_install() {
    ensure_root
    local version="$1"
    if dpkg -l "php${version}-fpm" &>/dev/null 2>&1; then
        info "PHP ${version}-fpm already installed"
        return 0
    fi
    apt-get update -qq
    apt-get install -y -qq "php${version}-fpm" "php${version}-mysql" "php${version}-cli" \
        "php${version}-curl" "php${version}-mbstring" "php${version}-xml" \
        "php${version}-imagick" "php${version}-zip" "php${version}-intl" 2>/dev/null || {
        local fb
        fb="$(php_fallback_version "$version")"
        warn "PHP ${version} not available, trying fallback ${fb}"
        version="$fb"
        apt-get install -y -qq "php${version}-fpm" "php${version}-mysql" "php${version}-cli" \
            "php${version}-curl" "php${version}-mbstring" "php${version}-xml" \
            "php${version}-imagick" "php${version}-zip" "php${version}-intl"
    }
    info "PHP ${version}-fpm installed"
    echo "$version"
}

php_add_pool() {
    local domain="$1" version="$2" sftp_user="$3"
    local pool_file="/etc/php/${version}/fpm/pool.d/${domain}.conf"
    sed -e "s/{{ domain }}/$domain/g" \
        -e "s/{{ user }}/$sftp_user/g" \
        -e "s/{{ version }}/$version/g" \
        "$PHP_TEMPLATE" > "$pool_file"
    chmod 644 "$pool_file"
    systemctl reload "php${version}-fpm"
    info "PHP-FPM pool created for $domain (v${version})"
}

php_remove_pool() {
    local domain="$1" version="$2"
    local pool_file="/etc/php/${version}/fpm/pool.d/${domain}.conf"
    rm -f "$pool_file"
    systemctl reload "php${version}-fpm" 2>/dev/null || true
    info "PHP-FPM pool removed for $domain"
}

php_socket_path() {
    local version="$1"
    echo "/run/php/php${version}-fpm.sock"
}

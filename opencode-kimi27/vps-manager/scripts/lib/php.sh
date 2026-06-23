#!/usr/bin/env bash
# scripts/lib/php.sh — PHP-FPM helpers.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PHP_POOL_TEMPLATE="${VPSMGR_ROOT}/templates/php-pool.conf.j2"

php_pool_dir() {
    local version="$1"
    printf "${PHP_POOL_DIR_TEMPLATE}" "${version}"
}

php_socket_for() {
    local domain="$1"
    local version="$2"
    echo "/run/php/php${version}-fpm-${domain}.sock"
}

php_pool_file() {
    local domain="$1"
    local version="$2"
    echo "$(php_pool_dir "${version}")/${domain}.conf"
}

php_service_name() {
    local version="$1"
    echo "php${version}-fpm"
}

php_get_installed_versions() {
    # Discovers installed PHP-FPM versions from /etc/php directories.
    if [[ -d /etc/php ]]; then
        find /etc/php -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V
    fi
}

php_resolve_version() {
    local requested="$1"
    require_command jq

    if [[ -z ${BOOTSTRAP_STATE} ]] || [[ ! -f ${BOOTSTRAP_STATE} ]]; then
        die_dependency "bootstrap state missing; run bootstrap first"
    fi

    case "${requested}" in
        current)
            jq -er '.php.current // empty' "${BOOTSTRAP_STATE}"
            ;;
        fallback)
            jq -er '.php.fallback // empty' "${BOOTSTRAP_STATE}"
            ;;
        *)
            # Treat as an explicit version string; validate format only.
            if [[ ! ${requested} =~ ^[0-9]+\.[0-9]+$ ]]; then
                die_input "invalid php version: ${requested}"
            fi
            echo "${requested}"
            ;;
    esac
}

php_render_pool() {
    local domain="$1"
    local version="$2"
    local user="$3"
    local webroot="$4"
    local pool_file socket
    pool_file=$(php_pool_file "${domain}" "${version}")
    socket=$(php_socket_for "${domain}" "${version}")

    export DOMAIN="${domain}"
    export POOL_NAME="${domain}"
    export USER="${user}"
    export GROUP="${user}"
    export WEBROOT="${webroot}"
    export PHP_SOCKET="${socket}"

    render_template "${PHP_POOL_TEMPLATE}" "${pool_file}"
    chmod 0644 "${pool_file}"
    vpsmgr_log INFO "rendered PHP ${version} pool for ${domain}"
}

php_remove_pool() {
    local domain="$1"
    local version="$2"
    local pool_file
    pool_file=$(php_pool_file "${domain}" "${version}")
    if [[ -f ${pool_file} ]]; then
        rm -f "${pool_file}"
        vpsmgr_log INFO "removed PHP ${version} pool for ${domain}"
    fi
}

php_ensure_service_running() {
    local version="$1"
    local svc
    svc=$(php_service_name "${version}")
    require_command systemctl
    if ! systemctl is-active --quiet "${svc}"; then
        systemctl start "${svc}" || die_internal "failed to start ${svc}"
    fi
}

php_reload() {
    local version="$1"
    local svc
    svc=$(php_service_name "${version}")
    require_command systemctl
    systemctl reload "${svc}" || die_internal "failed to reload ${svc}"
    vpsmgr_log INFO "reloaded ${svc}"
}

php_restart() {
    local version="$1"
    local svc
    svc=$(php_service_name "${version}")
    require_command systemctl
    systemctl restart "${svc}" || die_internal "failed to restart ${svc}"
}

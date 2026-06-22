#!/usr/bin/env bash
# php.sh — PHP-FPM management functions
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Detect latest available PHP version from APT
php_detect_latest() {
    apt-get update -qq 2>/dev/null
    local latest
    latest=$(apt-cache search '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null | grep -oP 'php\K[0-9]+\.[0-9]+' | sort -Vr | head -1)
    echo "${latest}"
}

# Detect previous minor version of currently installed PHP
# D9: If current = 8.5, fallback = 8.4. Never previous major.
php_detect_previous() {
    local current="$1"
    local major minor
    major=$(echo "${current}" | cut -d. -f1)
    minor=$(echo "${current}" | cut -d. -f2)
    local prev_minor=$((minor - 1))
    if [[ "${prev_minor}" -lt 0 ]]; then
        exit_internal "Cannot determine PHP fallback version for ${current}"
    fi
    echo "${major}.${prev_minor}"
}

# Install PHP-FPM for a specific version
php_install() {
    local version="${1:-}"
    if [[ -z "${version}" ]]; then
        version=$(php_detect_latest)
    fi

    log_info "Installing PHP ${version}-FPM..."

    if dpkg -l "php${version}-fpm" &>/dev/null; then
        log_info "PHP ${version}-FPM already installed"
        return 0
    fi

    apt-get update -qq
    apt-get install -y -qq \
        "php${version}-fpm" \
        "php${version}-cli" \
        "php${version}-common" \
        "php${version}-mysql" \
        "php${version}-pgsql" \
        "php${version}-sqlite3" \
        "php${version}-xml" \
        "php${version}-mbstring" \
        "php${version}-curl" \
        "php${version}-zip" \
        "php${version}-gd" \
        "php${version}-intl" \
        "php${version}-opcache" \
        "php${version}-imagick" \
        "php${version}-redis" \
        2>/dev/null

    log_info "PHP ${version}-FPM installed"

    # Ensure default PHP-FPM socket path for Caddy
    local socket_path="/run/php/php${version}-fpm.sock"
    mkdir -p "$(dirname "${socket_path}")"
    chown "${PHP_FPM_USER}:${PHP_FPM_GROUP}" "$(dirname "${socket_path}")" 2>/dev/null || true

    echo "${version}"
}

# Create a PHP-FPM pool configuration for a site
php_pool_create() {
    local domain="$1"
    local sitename="$2"
    local php_version="$3"

    local pool_file="${PHP_POOL_DIR}/${php_version}/fpm/pool.d/${domain}.conf"

    if [[ -f "${pool_file}" ]]; then
        log_warn "PHP pool already exists: ${pool_file}"
        echo "${pool_file}"
        return 0
    fi

    cat > "${pool_file}" <<EOF
; Pool: ${domain} — managed by vpsmgr
[${sitename}]
user = ${sitename}
group = ${sitename}
listen = /run/php/php${php_version}-fpm-${sitename}.sock
listen.owner = ${PHP_FPM_USER}
listen.group = ${PHP_FPM_USER}
listen.mode = 0660

pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 30s
pm.max_requests = 500

php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[open_basedir] = ${SITE_BASE_HOME}/${sitename}/public:/tmp:/usr/share/php

; Security
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source
php_admin_value[allow_url_fopen] = On
php_admin_value[allow_url_include] = Off
php_admin_value[expose_php] = Off

; Session path per site
php_admin_value[session.save_path] = ${SITE_BASE_HOME}/${sitename}/tmp

chdir = /
EOF

    log_info "PHP pool created: ${pool_file}"
    echo "${pool_file}"
}

# Remove a PHP-FPM pool configuration
php_pool_remove() {
    local domain="$1"
    local php_version="$2"

    local pool_file="${PHP_POOL_DIR}/${php_version}/fpm/pool.d/${domain}.conf"
    if [[ -f "${pool_file}" ]]; then
        rm -f "${pool_file}"
        log_info "Removed PHP pool: ${pool_file}"
    fi
}

# Reload PHP-FPM for a specific version
php_fpm_reload() {
    local php_version="$1"
    local service_name="${PHP_FPM_SERVICE//\{ver\}/${php_version}}"

    if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
        systemctl reload "${service_name}"
        log_info "PHP ${php_version}-FPM reloaded"
    else
        systemctl restart "${service_name}"
        log_info "PHP ${php_version}-FPM restarted"
    fi
}

# Check PHP-FPM status for a version
php_fpm_status() {
    local php_version="$1"
    local service_name="${PHP_FPM_SERVICE//\{ver\}/${php_version}}"

    if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

# Install PHP-FPM for both latest and previous minor
php_install_with_fallback() {
    local latest previous
    latest=$(php_detect_latest)
    php_install "${latest}"

    previous=$(php_detect_previous "${latest}")
    php_install "${previous}"

    # Return versions as space-separated string
    echo "${latest} ${previous}"
}
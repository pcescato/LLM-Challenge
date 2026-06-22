#!/usr/bin/env bash
# lib/php.sh — PHP-FPM version resolution, pool creation, and management.
# Relies on lib/common.sh (already sourced by caller).

# Resolve the latest installed PHP-FPM version (major.minor).
# Looks at installed packages first, then available PHP-FPM packages in apt.
php_resolve_version() {
    local best=""
    # 1. Scan installed php*-fpm packages.
    local pkg
    while IFS= read -r pkg; do
        # Package name like "php8.4-fpm"
        if [[ "${pkg}" =~ ^php([0-9]+\.[0-9]+)-fpm$ ]]; then
            local ver="${BASH_REMATCH[1]}"
            if _php_version_ok "${ver}"; then
                if [[ -z "${best}" ]] || _php_version_gt "${ver}" "${best}"; then
                    best="${ver}"
                fi
            fi
        fi
    done < <(dpkg-query -W -f '${Package}\n' 2>/dev/null | grep -E '^php[0-9]+\.[0-9]+-fpm$' || true)

    if [[ -n "${best}" ]]; then
        echo "${best}"
        return 0
    fi

    # 2. Scan apt cache for available php*-fpm packages.
    if command -v apt-cache >/dev/null 2>&1; then
        local avail
        avail="$(apt-cache search --names-only '^php[0-9.]+-fpm$' 2>/dev/null \
                 | awk '{print $1}' || true)"
        for pkg in ${avail}; do
            if [[ "${pkg}" =~ ^php([0-9]+\.[0-9]+)-fpm$ ]]; then
                local ver="${BASH_REMATCH[1]}"
                if _php_version_ok "${ver}"; then
                    if [[ -z "${best}" ]] || _php_version_gt "${ver}" "${best}"; then
                        best="${ver}"
                    fi
                fi
            fi
        done
    fi

    if [[ -n "${best}" ]]; then
        echo "${best}"
        return 0
    fi
    return 1
}

# Previous minor version only (D9). 8.5 → 8.4. Never previous major.
php_fallback_version() {
    local current="$1"
    if [[ ! "${current}" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        return 1
    fi
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local fb_minor=$((minor - 1))
    if [[ ${fb_minor} -lt ${VPSMGR_PHP_MIN_MINOR} ]]; then
        # Don't go below minimum for this major.
        if [[ ${major} -gt ${VPSMGR_PHP_MIN_MAJOR} ]]; then
            # Could go to previous major's max, but D9 forbids previous major.
            return 1
        fi
        return 1
    fi
    echo "${major}.${fb_minor}"
}

# Validate a version meets the minimum (EOL 7.x unsupported).
_php_version_ok() {
    local ver="$1"
    if [[ ! "${ver}" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        return 1
    fi
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    if [[ ${major} -lt ${VPSMGR_PHP_MIN_MAJOR} ]]; then
        return 1
    fi
    if [[ ${major} -eq ${VPSMGR_PHP_MIN_MAJOR} ]] && [[ ${minor} -lt ${VPSMGR_PHP_MIN_MINOR} ]]; then
        return 1
    fi
    return 0
}

# Return 0 if $1 > $2 (semantic major.minor).
_php_version_gt() {
    local a="$1" b="$2"
    local a_major a_minor b_major b_minor
    IFS='.' read -r a_major a_minor <<< "${a}"
    IFS='.' read -r b_major b_minor <<< "${b}"
    if [[ ${a_major} -gt ${b_major} ]]; then return 0; fi
    if [[ ${a_major} -lt ${b_major} ]]; then return 1; fi
    [[ ${a_minor} -gt ${b_minor} ]]
}

# Install PHP-FPM for a given version (idempotent).
php_install() {
    local ver="$1"
    if [[ ! "${ver}" =~ ^[0-9]+\.[0-9]+$ ]]; then
        die "${E_USAGE}" "invalid PHP version: ${ver}"
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "php${ver}-fpm" \
        "php${ver}-cli" "php${ver}-curl" "php${ver}-mbstring" \
        "php${ver}-mysql" "php${ver}-pgsql" "php${ver}-xml" \
        "php${ver}-gd" "php${ver}-zip" "php${ver}-intl" \
        "php${ver}-bcmath" "php${ver}-imagick" >/dev/null
    log_info "php${ver}-fpm installed"
}

# Ensure PHP-FPM service is enabled and running.
php_ensure_running() {
    local ver="$1"
    local svc="php${ver}-fpm"
    systemctl enable "${svc}" >/dev/null 2>&1 || true
    systemctl restart "${svc}" 2>/dev/null || systemctl start "${svc}" 2>/dev/null || true
    log_info "${svc} running"
}

# FPM socket path for a given domain + version.
php_socket_path() {
    local domain="$1"
    local ver="$2"
    # Socket in standard FPM location, named per domain.
    echo "/run/php/php${ver}-fpm.${domain}.sock"
}

# Pool config path for a given version + domain.
php_pool_path() {
    local ver="$1"
    local domain="$2"
    echo "/etc/php/${ver}/fpm/pool.d/${domain}.conf"
}

# php_create_pool <domain> <user> <webroot> <php_version>
php_create_pool() {
    local domain="$1"
    local user="$2"
    local webroot="$3"
    local ver="$4"
    local socket
    socket="$(php_socket_path "${domain}" "${ver}")"
    local tmpl
    tmpl="$(template_path "php-pool.conf.j2")" \
        || die "${E_INTERNAL}" "php-pool.conf.j2 template not found"
    local pool_dir="/etc/php/${ver}/fpm/pool.d"
    mkdir -p "${pool_dir}"
    local rendered
    rendered="$(render_template "${tmpl}" \
        "domain=${domain}" \
        "user=${user}" \
        "webroot=${webroot}" \
        "php_version=${ver}" \
        "socket=${socket}")"
    local pool_file
    pool_file="$(php_pool_path "${ver}" "${domain}")"
    printf '%s\n' "${rendered}" > "${pool_file}"
    chmod 644 "${pool_file}"
    log_info "php pool created: ${pool_file}"
    # Reload FPM to pick up new pool.
    systemctl reload "php${ver}-fpm" 2>/dev/null \
        || systemctl restart "php${ver}-fpm" 2>/dev/null || true
}

php_remove_pool() {
    local ver="$1"
    local domain="$2"
    local pool_file
    pool_file="$(php_pool_path "${ver}" "${domain}")"
    if [[ -f "${pool_file}" ]]; then
        rm -f "${pool_file}"
        log_info "php pool removed: ${pool_file}"
        systemctl reload "php${ver}-fpm" 2>/dev/null \
            || systemctl restart "php${ver}-fpm" 2>/dev/null || true
    fi
}

# Returns the php-fpm service name for a version.
php_service_name() {
    local ver="$1"
    echo "php${ver}-fpm"
}

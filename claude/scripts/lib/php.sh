#!/bin/bash
# PHP-FPM integration library
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Detect latest stable PHP version from repository
detect_php_version() {
    # Query available PHP versions from Debian repo
    # Prefer latest stable minor (e.g., 8.5 > 8.4)
    apt-cache search --names-only "^php[0-9]\.[0-9]$" 2>/dev/null | \
        awk '{print $1}' | \
        sed 's/^php//' | \
        sort -rV | \
        head -1
}

# Get PHP fallback version (previous minor only)
get_php_fallback() {
    local current="$1"
    local major="${current%%.*}"
    local minor="${current##*.}"

    # Decrement minor version
    ((minor--))

    if [[ $minor -lt 0 ]]; then
        log_error "Cannot compute fallback for PHP $current (would go below 0)"
        return $E_INTERNAL
    fi

    echo "${major}.${minor}"
}

# Validate PHP version is supported (not EOL)
is_php_supported() {
    local version="$1"
    local major="${version%%.*}"

    # EOL check: PHP 7.x and earlier are not supported
    if [[ $major -lt 8 ]]; then
        return 1
    fi
    return 0
}

# Install PHP version with FPM and common extensions
install_php() {
    local version="$1"

    if ! is_php_supported "$version"; then
        log_error "PHP version is EOL or unsupported: $version"
        return $E_INTERNAL
    fi

    if is_package_installed "php${version}-fpm"; then
        log_debug "PHP $version already installed"
        return 0
    fi

    log_info "Installing PHP $version with FPM..."

    apt-get update -qq
    apt-get install -y -qq \
        "php${version}-fpm" \
        "php${version}-cli" \
        "php${version}-mysql" \
        "php${version}-pgsql" \
        "php${version}-curl" \
        "php${version}-gd" \
        "php${version}-intl" \
        "php${version}-json" \
        "php${version}-mbstring" \
        "php${version}-xml" \
        "php${version}-zip" \
        >/dev/null 2>&1 || {
        log_error "Failed to install PHP $version"
        return $E_INTERNAL
    }

    # Start and enable PHP-FPM service
    local svc="php${version}-fpm"
    systemctl enable "$svc" 2>/dev/null || true
    systemctl start "$svc" || {
        log_error "Failed to start $svc"
        return $E_INTERNAL
    }

    log_info "PHP $version installed successfully"
}

# Create PHP-FPM pool configuration for a site
# Usage: create_php_pool <domain> <php_version> <sftp_user>
create_php_pool() {
    local domain="$1"
    local php_version="$2"
    local sftp_user="$3"

    domain=$(normalize_domain "$domain") || return 1

    if ! is_php_supported "$php_version"; then
        log_error "PHP version not supported: $php_version"
        return $E_INTERNAL
    fi

    local pool_dir="${PHP_POOL_DIR}/${php_version}/fpm/pool.d"
    local pool_file="${pool_dir}/${domain}.conf"

    mkdir -p "$pool_dir"

    log_info "Creating PHP-FPM pool for $domain (PHP $php_version)"

    cat > "$pool_file" << EOF
[$domain]
user = $sftp_user
group = www-data
listen = /run/php/php${php_version}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 20
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 10
pm.max_requests = 500

; Security and performance
security.limit_extensions = .php
slowlog = /var/log/php-fpm/${domain}-slow.log
request_slowlog_timeout = 30s
request_terminate_timeout = 300s

; Resource limits
php_value[memory_limit] = 256M
php_value[max_execution_time] = 300
php_value[upload_max_filesize] = 256M
php_value[post_max_size] = 256M

; Opcache
php_value[opcache.enable] = 1
php_value[opcache.memory_consumption] = 128
php_value[opcache.interned_strings_buffer] = 8
php_value[opcache.max_accelerated_files] = 4000
php_value[opcache.validate_timestamps] = 1
php_value[opcache.revalidate_freq] = 60
EOF

    chmod 644 "$pool_file"

    # Create slowlog directory if needed
    mkdir -p /var/log/php-fpm
    chmod 755 /var/log/php-fpm

    log_debug "PHP-FPM pool created: $pool_file"
}

# Reload PHP-FPM service
reload_php_fpm() {
    local version="$1"

    if ! systemctl is-active --quiet "php${version}-fpm"; then
        log_warn "PHP-FPM $version is not running, starting..."
        systemctl start "php${version}-fpm" || {
            log_error "Failed to start PHP-FPM $version"
            return $E_INTERNAL
        }
    else
        log_info "Reloading PHP-FPM $version..."
        systemctl reload "php${version}-fpm" || {
            log_error "Failed to reload PHP-FPM $version"
            return $E_INTERNAL
        }
    fi
}

# Delete PHP-FPM pool configuration
delete_php_pool() {
    local domain="$1"
    local php_version="$2"

    domain=$(normalize_domain "$domain") || return 1

    local pool_dir="${PHP_POOL_DIR}/${php_version}/fpm/pool.d"
    local pool_file="${pool_dir}/${domain}.conf"

    if [[ -f "$pool_file" ]]; then
        rm -f "$pool_file"
        log_info "Removed PHP-FPM pool for $domain"
        reload_php_fpm "$php_version" || return $?
    fi
}

# Check PHP syntax in a file
check_php_syntax() {
    local file="$1"
    local php_version="$2"

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return $E_NOTFOUND
    fi

    "php${php_version}" -l "$file" >/dev/null 2>&1 || {
        log_error "PHP syntax error in: $file"
        return $E_INTERNAL
    }
}

# Get installed PHP version
get_installed_php_version() {
    # Find first installed PHP version
    dpkg -l | grep -E "^ii.*php[0-9]\.[0-9]-fpm" | \
        sed -E 's/.*php([0-9]\.[0-9]).*/\1/' | \
        head -1
}

# Get PHP version for domain from state
get_domain_php_version() {
    local domain="$1"
    domain=$(normalize_domain "$domain") || return 1

    read_state "$domain" "php_version" || {
        log_error "Could not determine PHP version for $domain"
        return $E_NOTFOUND
    }
}

export -f detect_php_version get_php_fallback is_php_supported install_php
export -f create_php_pool reload_php_fpm delete_php_pool check_php_syntax
export -f get_installed_php_version get_domain_php_version

#!/bin/bash
# Create a new site (static, proxy, or WordPress)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/caddy.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/php.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/sftp.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/wp.sh"

require_root

# Parse arguments
declare -A args
args[type]="static"  # default
args[domain]=""
args[proxy_target]=""
args[php_version]=""

for arg in "$@"; do
    if [[ "$arg" =~ ^([a-z_]+)=(.+)$ ]]; then
        args["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    else
        log_error "Invalid argument format: $arg (use key=value)"
        exit $E_USAGE
    fi
done

domain="${args[domain]}"
site_type="${args[type]}"
proxy_target="${args[proxy_target]}"
php_version="${args[php_version]}"

# Validate required arguments
if [[ -z "$domain" ]]; then
    log_error "domain is required"
    exit $E_USAGE
fi

domain=$(normalize_domain "$domain") || exit $E_USAGE

# Validate site type
case "$site_type" in
    static|proxy|php|wordpress)
        : # valid
        ;;
    *)
        log_error "Invalid site type: $site_type (use: static, proxy, php, wordpress)"
        exit $E_USAGE
        ;;
esac

# WordPress type is CLI-only (no API)
if [[ "$site_type" == "wordpress" ]]; then
    log_error "Site type 'wordpress' is CLI-only and requires database setup via db-create.sh"
    exit $E_USAGE
fi

# Check if site already exists
if site_exists "$domain"; then
    log_error "Site already exists: $domain"
    exit $E_EXISTS
fi

log_info "Creating site: $domain (type: $site_type)"

# Determine PHP version if needed
if [[ "$site_type" == "php" ]]; then
    if [[ -z "$php_version" ]]; then
        php_version=$(grep "^PHP_DEFAULT_VERSION=" /etc/vpsmgr/vpsmgr.conf | cut -d= -f2 | tr -d '"')
        [[ -z "$php_version" ]] && {
            log_error "Could not determine default PHP version"
            exit $E_MISSING_DEP
        }
    fi

    # Ensure PHP version is supported
    is_php_supported "$php_version" || {
        log_error "Unsupported PHP version: $php_version"
        exit $E_USAGE
    }
fi

# Create SFTP user
sftp_user=$(make_sftp_username "$domain") || exit $?
sftp_password=""

# Determine webroot
webroot="/home/${sftp_user}/public"

log_info "Creating SFTP user: $sftp_user"
ensure_system_user "$sftp_user" "/usr/sbin/nologin" || exit $?

# Set SFTP password (generated in memory, printed once, never stored)
sftp_password=$(gen_password 16)
echo "${sftp_user}:${sftp_password}" | chpasswd 2>/dev/null || {
    log_error "Failed to set SFTP password"
    exit $E_INTERNAL
}

# Create webroot directory structure
log_info "Creating webroot: $webroot"
ensure_dir "$webroot" 755 "${sftp_user}:www-data"

# Create subdirectories for different site types
case "$site_type" in
    static|php)
        # Static sites serve directly from webroot
        ;;
    wordpress)
        # WordPress serves from wordpress/ subdirectory (setup separately via CLI)
        mkdir -p "${webroot}/wordpress"
        chown "${sftp_user}:www-data" "${webroot}/wordpress"
        chmod 755 "${webroot}/wordpress"
        ;;
    proxy)
        # Proxy doesn't need webroot files
        ;;
esac

# Create Caddy configuration
log_info "Configuring web server: $domain"
create_caddy_config "$domain" "$webroot" "$site_type" || {
    log_error "Failed to create web server configuration"
    # Clean up user
    userdel -rf "$sftp_user" 2>/dev/null || true
    exit $E_INTERNAL
}

# Create PHP-FPM pool if site type is PHP
if [[ "$site_type" == "php" ]]; then
    log_info "Configuring PHP-FPM for $domain"
    create_php_pool "$domain" "$php_version" "$sftp_user" || {
        log_error "Failed to create PHP-FPM pool"
        # Clean up
        delete_caddy_config "$domain" || true
        userdel -rf "$sftp_user" 2>/dev/null || true
        exit $E_INTERNAL
    }
    reload_php_fpm "$php_version" || {
        log_error "Failed to reload PHP-FPM"
        exit $E_INTERNAL
    }
fi

# Reload Caddy to activate new site
log_info "Activating site..."
reload_caddy || {
    log_error "Failed to reload web server"
    # Clean up
    delete_caddy_config "$domain" || true
    [[ "$site_type" == "php" ]] && delete_php_pool "$domain" "$php_version" || true
    userdel -rf "$sftp_user" 2>/dev/null || true
    exit $E_INTERNAL
}

# Create state file
log_info "Writing site state..."
local state_json=$(jq -n \
    --arg domain "$domain" \
    --arg type "$site_type" \
    --arg sftp_user "$sftp_user" \
    --arg webroot "$webroot" \
    --arg php_version "${php_version:-null}" \
    --arg php_pool "${php_version:+/etc/php/$php_version/fpm/pool.d/$domain.conf}" \
    --arg caddy_block "/etc/caddy/sites/${domain}.caddy" \
    --arg created_at "$(iso_timestamp)" \
    '{
        domain: $domain,
        type: $type,
        sftp_user: $sftp_user,
        webroot: $webroot,
        php_version: $php_version,
        php_pool: $php_pool,
        caddy_block: $caddy_block,
        databases: [],
        proxy_target: null,
        created_at: $created_at
    }')

write_state "$domain" "$state_json" || {
    log_error "Failed to write site state"
    exit $E_INTERNAL
}

# Output results
log_info "Site created successfully: $domain"
echo ""
echo "Site Details:"
echo "  Domain: $domain"
echo "  Type: $site_type"
echo "  Webroot: $webroot"
echo "  SFTP User: $sftp_user"
[[ "$site_type" == "php" ]] && echo "  PHP Version: $php_version"
echo ""
echo "SFTP Access:"
echo "  Host: $(hostname -f)"
echo "  Port: 22"
echo "  Username: $sftp_user"
echo "  Password: $sftp_password"
echo ""

exit $E_OK

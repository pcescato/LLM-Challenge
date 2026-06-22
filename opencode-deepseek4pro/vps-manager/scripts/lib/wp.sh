#!/usr/bin/env bash
# wp.sh — WordPress management functions
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WP_CLI_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
WP_CLI_PATH="/usr/local/bin/wp"

# Install WP-CLI
wp_cli_install() {
    if command -v wp &>/dev/null; then
        log_info "WP-CLI already installed: $(wp --version 2>/dev/null | head -1)"
        return 0
    fi

    log_info "Installing WP-CLI..."
    curl -sSL "${WP_CLI_URL}" -o "${WP_CLI_PATH}"
    chmod +x "${WP_CLI_PATH}"

    log_info "WP-CLI installed: $(wp --version 2>/dev/null | head -1)"
}

# Download and install WordPress core
wp_core_install() {
    local webroot="$1"
    local admin_user="${2:-}"
    local admin_pass="${3:-}"
    local admin_email="${4:-}"
    local site_title="${5:-WordPress Site}"

    local siteuser
    siteuser=$(stat -c '%U' "${webroot}")

    log_info "Installing WordPress core at ${webroot}..."

    sudo -u "${siteuser}" wp core download --path="${webroot}" --quiet 2>/dev/null

    log_info "WordPress core downloaded"

    if [[ -z "${admin_user}" ]]; then
        log_info "WordPress files installed — run wp core install interactively to complete setup"
        return 0
    fi

    # Generate salts in memory
    local salts
    salts=$(curl -sS https://api.wordpress.org/secret-key/1.1/salt/)

    local wp_config="${webroot}/wp-config.php"
    sudo -u "${siteuser}" wp config create \
        --dbname="${DB_NAME:-}" \
        --dbuser="${DB_USER:-}" \
        --dbpass="${DB_PASSWORD:-}" \
        --dbhost="${DB_HOST:-localhost}" \
        --path="${webroot}" \
        --extra-php <<< "<?php ${salts}" \
        --quiet 2>/dev/null

    chmod 600 "${wp_config}"
    chown "${siteuser}:${siteuser}" "${wp_config}"

    sudo -u "${siteuser}" wp core install \
        --url="${DOMAIN:-}" \
        --title="${site_title}" \
        --admin_user="${admin_user}" \
        --admin_password="${admin_pass}" \
        --admin_email="${admin_email}" \
        --path="${webroot}" \
        --skip-email \
        --quiet 2>/dev/null

    log_info "WordPress installed at ${webroot}"

    # Clean up sensitive variables
    unset DB_NAME DB_USER DB_PASSWORD DB_HOST DOMAIN admin_user admin_pass admin_email salts
}

# Create wp-config.php from template
wp_config_create() {
    local webroot="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="${5:-localhost}"
    local domain="$6"

    local siteuser
    siteuser=$(stat -c '%U' "${webroot}")

    local config_file="${webroot}/wp-config.php"

    if [[ -f "${config_file}" ]]; then
        log_warn "wp-config.php already exists at ${config_file}"
        return 0
    fi

    local salts
    salts=$(curl -sS https://api.wordpress.org/secret-key/1.1/salt/)

    local table_prefix="wp_"

    cat > "${config_file}" <<WPCONFIG
<?php
/**
 * WordPress configuration — managed by vpsmgr
 * Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
 */

define( 'DB_NAME',     '${db_name}' );
define( 'DB_USER',     '${db_user}' );
define( 'DB_PASSWORD', '${db_pass}' );
define( 'DB_HOST',     '${db_host}' );
define( 'DB_CHARSET',  'utf8mb4' );
define( 'DB_COLLATE',  '' );

${salts}

\$table_prefix = '${table_prefix}';

define( 'WP_DEBUG', false );
define( 'WP_SITEURL', 'https://${domain}' );
define( 'WP_HOME', 'https://${domain}' );
define( 'FORCE_SSL_ADMIN', true );

/* Memory limits */
define( 'WP_MEMORY_LIMIT', '256M' );
define( 'WP_MAX_MEMORY_LIMIT', '512M' );

/* Disable file editing in admin */
define( 'DISALLOW_FILE_EDIT', true );
define( 'DISALLOW_FILE_MODS', true );

/* Auto-updates */
define( 'WP_AUTO_UPDATE_CORE', 'minor' );
define( 'AUTOMATIC_UPDATER_DISABLED', false );

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
WPCONFIG

    chmod 600 "${config_file}"
    chown "${siteuser}:${siteuser}" "${config_file}"

    log_info "wp-config.php created at ${config_file}"
}

# Clean up a WordPress installation
wp_cleanup() {
    local webroot="$1"

    if [[ -d "${webroot}" ]]; then
        log_info "Removing WordPress files from ${webroot}..."
        rm -rf "${webroot:?}"/* 2>/dev/null || true
        rm -rf "${webroot:?}"/.[!.]* 2>/dev/null || true
        log_info "WordPress files removed"
    fi
}
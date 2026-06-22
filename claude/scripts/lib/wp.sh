#!/bin/bash
# WordPress installation and management library
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Ensure WordPress CLI (WP-CLI) is installed
install_wp_cli() {
    if require_cmd wp 2>/dev/null; then
        log_debug "WP-CLI already installed"
        return 0
    fi

    log_info "Installing WP-CLI..."

    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp 2>/dev/null || {
        log_error "Failed to download WP-CLI"
        return $E_INTERNAL
    }

    chmod +x /usr/local/bin/wp

    # Test installation
    wp --version >/dev/null 2>&1 || {
        log_error "WP-CLI installation failed"
        return $E_INTERNAL
    }

    log_info "WP-CLI installed successfully"
}

# Install WordPress to a directory
# Usage: install_wordpress <webroot> <domain> <sftp_user> <db_engine> <db_name> <db_user> <db_password>
install_wordpress() {
    local webroot="$1"
    local domain="$2"
    local sftp_user="$3"
    local db_engine="$4"
    local db_name="$5"
    local db_user="$6"
    local db_password="$7"

    domain=$(normalize_domain "$domain") || return 1

    if [[ -d "${webroot}/wordpress" && -f "${webroot}/wordpress/wp-config.php" ]]; then
        log_info "WordPress already installed in $webroot"
        return 0
    fi

    log_info "Installing WordPress to $webroot"

    # Create wordpress subdirectory if it doesn't exist
    mkdir -p "${webroot}/wordpress"

    # Database host depends on engine
    local db_host="localhost"
    [[ "$db_engine" == "postgresql" ]] && db_host="localhost"

    # Download and configure WordPress
    cd "${webroot}/wordpress" || return 1

    # Download WordPress core
    wp core download --allow-root 2>&1 | grep -v "^Warning:" || {
        log_error "Failed to download WordPress"
        return $E_INTERNAL
    }

    # Create wp-config.php
    wp config create \
        --dbname="$db_name" \
        --dbuser="$db_user" \
        --dbpass="$db_password" \
        --dbhost="$db_host" \
        --dbprefix="wp_" \
        --allow-root 2>&1 | grep -v "^Warning:" || {
        log_error "Failed to create wp-config.php"
        return $E_INTERNAL
    }

    # Install WordPress database
    wp core install \
        --url="https://${domain}" \
        --title="$(capitalize_domain "$domain")" \
        --admin_user="admin" \
        --admin_password="$(gen_password 24)" \
        --admin_email="admin@${domain}" \
        --allow-root 2>&1 | grep -v "^Warning:" || {
        log_error "Failed to install WordPress"
        return $E_INTERNAL
    }

    # Set proper permissions
    chown -R "${sftp_user}:www-data" "${webroot}/wordpress"
    chmod -R u+rw,g+r,o-rwx "${webroot}/wordpress"
    find "${webroot}/wordpress" -type d -exec chmod u+x,g+x {} \;

    # Protect wp-config.php
    chmod 600 "${webroot}/wordpress/wp-config.php"

    log_info "WordPress installed: ${webroot}/wordpress"

    # Note: admin credentials printed by wp core install, not stored by toolkit
}

# Get WordPress version from an installation
get_wordpress_version() {
    local webroot="$1"

    if [[ ! -f "${webroot}/wordpress/wp-config.php" ]]; then
        log_error "WordPress not found in $webroot"
        return $E_NOTFOUND
    fi

    cd "${webroot}/wordpress" || return 1
    wp core version --allow-root 2>/dev/null || echo "unknown"
}

# Get WordPress admin URL
get_wordpress_admin_url() {
    local webroot="$1"
    local domain="$2"

    domain=$(normalize_domain "$domain") || return 1

    if [[ ! -f "${webroot}/wordpress/wp-config.php" ]]; then
        log_error "WordPress not found in $webroot"
        return $E_NOTFOUND
    }

    echo "https://${domain}/wordpress/wp-admin/"
}

# Update WordPress core
update_wordpress() {
    local webroot="$1"

    if [[ ! -f "${webroot}/wordpress/wp-config.php" ]]; then
        log_error "WordPress not found in $webroot"
        return $E_NOTFOUND
    }

    log_info "Updating WordPress core..."

    cd "${webroot}/wordpress" || return 1

    wp core update --allow-root 2>&1 | grep -v "^Warning:" || {
        log_warn "WordPress update returned errors"
    }

    wp core update-db --allow-root 2>&1 | grep -v "^Warning:" || {
        log_warn "WordPress database update returned errors"
    }

    log_info "WordPress updated"
}

# Verify WordPress installation
verify_wordpress() {
    local webroot="$1"

    if [[ ! -d "${webroot}/wordpress" || ! -f "${webroot}/wordpress/wp-config.php" ]]; then
        return 1
    fi

    cd "${webroot}/wordpress" || return 1

    # Check if WordPress can connect to database
    wp db check --allow-root >/dev/null 2>&1 || {
        log_error "WordPress database connection failed"
        return 1
    }

    return 0
}

# Delete WordPress installation (keep database intact)
delete_wordpress() {
    local webroot="$1"
    local keep_db="${2:-true}"

    if [[ ! -d "${webroot}/wordpress" ]]; then
        log_info "WordPress not found in $webroot"
        return 0
    }

    log_info "Removing WordPress installation from $webroot"

    # Get database info for deletion if requested
    if [[ "$keep_db" == "false" ]]; then
        local db_name
        db_name=$(grep "define.*DB_NAME" "${webroot}/wordpress/wp-config.php" 2>/dev/null | \
            grep -oP "(?<='DB_NAME', ')[^']*" || true)

        if [[ -n "$db_name" ]]; then
            log_info "Database $db_name will be preserved"
        fi
    fi

    # Remove WordPress files
    rm -rf "${webroot}/wordpress"

    log_info "WordPress removed"
}

# Capitalize domain for WordPress title
capitalize_domain() {
    local domain="$1"
    domain="${domain%.}"  # remove trailing dot if any
    # Convert example.com to Example Com
    echo "$domain" | sed 's/\./ /g' | sed 's/\b\(.\)/\u\1/g'
}

# Enable WordPress maintenance mode
enable_maintenance_mode() {
    local webroot="$1"

    if [[ ! -d "${webroot}/wordpress" ]]; then
        log_error "WordPress not found in $webroot"
        return $E_NOTFOUND
    fi

    log_info "Enabling WordPress maintenance mode..."

    touch "${webroot}/wordpress/.maintenance" || {
        log_error "Failed to enable maintenance mode"
        return $E_INTERNAL
    }
}

# Disable WordPress maintenance mode
disable_maintenance_mode() {
    local webroot="$1"

    if [[ ! -d "${webroot}/wordpress" ]]; then
        log_error "WordPress not found in $webroot"
        return $E_NOTFOUND
    fi

    log_info "Disabling WordPress maintenance mode..."

    rm -f "${webroot}/wordpress/.maintenance" || true
}

# Get WordPress plugin status
get_plugin_status() {
    local webroot="$1"

    if [[ ! -d "${webroot}/wordpress" ]]; then
        log_error "WordPress not found in $webroot"
        return $E_NOTFOUND
    fi

    cd "${webroot}/wordpress" || return 1
    wp plugin list --status=inactive --allow-root 2>/dev/null || true
}

export -f install_wp_cli install_wordpress get_wordpress_version get_wordpress_admin_url
export -f update_wordpress verify_wordpress delete_wordpress capitalize_domain
export -f enable_maintenance_mode disable_maintenance_mode get_plugin_status

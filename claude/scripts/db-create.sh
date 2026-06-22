#!/bin/bash
# Create database and optionally WordPress site
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/php.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/sftp.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/wp.sh"

require_root

# Parse arguments
declare -A args
args[domain]=""
args[engine]="mariadb"
args[install_wordpress]="false"

for arg in "$@"; do
    if [[ "$arg" =~ ^([a-z_]+)=(.+)$ ]]; then
        args["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    else
        log_error "Invalid argument format: $arg (use key=value)"
        exit $E_USAGE
    fi
done

domain="${args[domain]}"
engine="${args[engine]}"
install_wordpress="${args[install_wordpress]}"

if [[ -z "$domain" ]]; then
    log_error "domain is required"
    exit $E_USAGE
fi

domain=$(normalize_domain "$domain") || exit $E_USAGE

# Validate site exists
if ! site_exists "$domain"; then
    log_error "Site not found: $domain"
    exit $E_NOTFOUND
fi

# Validate database engine
case "$engine" in
    mariadb|postgresql)
        : # valid
        ;;
    *)
        log_error "Unsupported database engine: $engine (use: mariadb, postgresql)"
        exit $E_USAGE
        ;;
esac

log_info "Creating database for site: $domain (engine: $engine)"

# Read site configuration
sftp_user=$(read_state "$domain" "sftp_user") || {
    log_error "Could not read SFTP user"
    exit $E_NOTFOUND
}

webroot=$(read_state "$domain" "webroot") || {
    log_error "Could not read webroot"
    exit $E_NOTFOUND
}

site_type=$(read_state "$domain" "type") || site_type="static"

# Determine database name
local db_name="${sftp_user//_/}_${engine:0:3}"
db_name="${db_name:0:32}"  # Truncate to DB limit

# Generate database password (printed once, not stored)
local db_password
db_password=$(gen_password 24)

local db_user
db_user="${sftp_user:0:16}_user"  # Truncate username for DB user

# Create database
log_info "Creating $engine database: $db_name"
create_database "$engine" "$db_name" "$db_user" "$db_password" || {
    log_error "Failed to create database"
    exit $E_INTERNAL
}

# If installing WordPress, do that now
if [[ "$install_wordpress" == "true" ]]; then
    log_info "Installing WordPress to $webroot"

    # Determine PHP version (required for WordPress)
    php_version=$(read_state "$domain" "php_version") || {
        log_error "Could not determine PHP version for WordPress installation"
        exit $E_NOTFOUND
    }

    # Update site type to wordpress in state
    local current_state
    current_state=$(jq . "$(get_state_file "$domain")") || {
        log_error "Could not read site state"
        exit $E_INTERNAL
    }

    # Install WordPress
    install_wordpress "$webroot" "$domain" "$sftp_user" "$engine" "$db_name" "$db_user" "$db_password" || {
        log_error "Failed to install WordPress"
        exit $E_INTERNAL
    }

    # Update state to include this database
    current_state=$(echo "$current_state" | jq \
        --arg type "wordpress" \
        --arg engine "$engine" \
        --arg db_name "$db_name" \
        --arg db_user "$db_user" \
        '.type = $type | .databases += [{"engine": $engine, "name": $db_name, "user": $db_user}]')

    write_state "$domain" "$(echo "$current_state" | jq .)" || {
        log_error "Failed to update site state"
        exit $E_INTERNAL
    }

    log_info "WordPress installed successfully"
    echo ""
    echo "WordPress Admin URL: https://${domain}/wordpress/wp-admin/"
    echo "Important: Change the admin password immediately after first login"
else
    # Just add database to site state
    local state_file
    state_file=$(get_state_file "$domain") || exit $?

    jq \
        --arg engine "$engine" \
        --arg db_name "$db_name" \
        --arg db_user "$db_user" \
        '.databases += [{"engine": $engine, "name": $db_name, "user": $db_user}]' \
        "$state_file" > "${state_file}.tmp"

    mv "${state_file}.tmp" "$state_file"
    chmod 600 "$state_file"
fi

log_info "Database created successfully"

exit $E_OK

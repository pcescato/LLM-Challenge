#!/bin/bash
# Delete a site and associated resources
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/caddy.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/php.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/sftp.sh"

require_root

# Parse arguments
declare -A args
args[domain]=""
args[skip_backup]="false"
args[confirm]=""

for arg in "$@"; do
    if [[ "$arg" =~ ^([a-z_]+)=(.+)$ ]]; then
        args["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    else
        log_error "Invalid argument format: $arg (use key=value)"
        exit $E_USAGE
    fi
done

domain="${args[domain]}"
skip_backup="${args[skip_backup]}"
confirm="${args[confirm]}"

if [[ -z "$domain" ]]; then
    log_error "domain is required"
    exit $E_USAGE
fi

domain=$(normalize_domain "$domain") || exit $E_USAGE

# Check if site exists
if ! site_exists "$domain"; then
    log_error "Site not found: $domain"
    exit $E_NOTFOUND
fi

log_warn "Preparing to delete site: $domain"

# Require explicit confirmation if not skipping backup
if [[ "$skip_backup" == "true" ]]; then
    if [[ "$confirm" != "DELETE $domain" ]]; then
        log_error "Explicit confirmation required to skip backup"
        echo "Type DELETE $domain to confirm:"
        exit $E_USAGE
    fi
fi

# Read site configuration from state
webroot=$(read_state "$domain" "webroot") || {
    log_error "Could not read site configuration"
    exit $E_NOTFOUND
}

sftp_user=$(read_state "$domain" "sftp_user") || {
    log_error "Could not read SFTP user"
    exit $E_NOTFOUND
}

site_type=$(read_state "$domain" "type") || site_type="static"
php_version=$(read_state "$domain" "php_version") || php_version=""

log_info "Site details: type=$site_type, user=$sftp_user, webroot=$webroot"

# Create backup unless explicitly skipped (design decision: backups before deletion)
if [[ "$skip_backup" != "true" ]]; then
    log_info "Creating backup before deletion..."
    local backup_file="/var/backups/vpsmgr/${domain}-$(date +%s).tar.xz"
    mkdir -p /var/backups/vpsmgr

    # Backup webroot
    if [[ -d "$webroot" ]]; then
        tar -C "$(dirname "$webroot")" -cJf "$backup_file" \
            "$(basename "$webroot")" 2>/dev/null || {
            log_warn "Backup creation failed, but continuing with deletion"
        }

        if [[ -f "$backup_file" ]]; then
            chmod 600 "$backup_file"
            log_info "Backup created: $backup_file"
        fi
    fi
fi

# Delete web server configuration
log_info "Removing web server configuration..."
delete_caddy_config "$domain" || {
    log_warn "Failed to delete Caddy configuration"
}

# Delete PHP-FPM pool if applicable
if [[ "$site_type" == "php" && -n "$php_version" ]]; then
    log_info "Removing PHP-FPM configuration..."
    delete_php_pool "$domain" "$php_version" || {
        log_warn "Failed to delete PHP-FPM pool"
    }
fi

# Delete SFTP user and home directory
log_info "Removing SFTP user: $sftp_user"
delete_sftp_user "$sftp_user" || {
    log_warn "Failed to delete SFTP user"
}

# Delete databases if any
log_info "Cleaning up databases..."
local state_file
state_file=$(get_state_file "$domain") || exit $?

if [[ -f "$state_file" ]]; then
    # Extract and delete any associated databases
    jq -r '.databases[]? | "\(.engine)|\(.name)|\(.user)"' "$state_file" 2>/dev/null | \
    while IFS='|' read -r engine db_name db_user; do
        [[ -z "$engine" ]] && continue
        log_info "Deleting database: $db_name"
        delete_database "$engine" "$db_name" "$db_user" || {
            log_warn "Failed to delete database: $db_name"
        }
    done
fi

# Delete state file
log_info "Removing site state..."
rm -f "$state_file" || {
    log_error "Failed to delete state file"
    exit $E_INTERNAL
}

log_info "Site deleted successfully: $domain"

exit $E_OK

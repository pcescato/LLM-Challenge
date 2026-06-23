#!/bin/bash
# Create backups of sites and databases
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/db.sh"

require_root

# Parse arguments
declare -A args
args[domain]=""
args[all]="false"
args[post_hook]=""

for arg in "$@"; do
    if [[ "$arg" =~ ^([a-z_]+)=(.+)$ ]]; then
        args["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    else
        log_error "Invalid argument format: $arg (use key=value)"
        exit $E_USAGE
    fi
done

domain="${args[domain]}"
all="${args[all]}"
post_hook="${args[post_hook]}"

# Validate arguments
if [[ "$all" != "true" && -z "$domain" ]]; then
    log_error "Either domain or all=true is required"
    exit $E_USAGE
fi

if [[ "$all" == "true" && -n "$domain" ]]; then
    log_error "Cannot specify both domain and all=true"
    exit $E_USAGE
fi

# Ensure backup directory exists
mkdir -p /var/backups/vpsmgr
chmod 700 /var/backups/vpsmgr

log_info "Starting backup operation..."

backup_site() {
    local site_domain="$1"
    local state_file
    state_file=$(get_state_file "$site_domain") || return 1

    if [[ ! -f "$state_file" ]]; then
        log_warn "Site state not found: $site_domain"
        return 0
    fi

    log_info "Backing up site: $site_domain"

    local webroot
    webroot=$(jq -r '.webroot' "$state_file") || return 1
    local timestamp
    timestamp=$(date +%s)
    local backup_file="/var/backups/vpsmgr/${site_domain}-files-${timestamp}.tar.xz"

    # Create compressed tarball (design decision D3: local only)
    if [[ -d "$webroot" ]]; then
        tar -C "$(dirname "$webroot")" -cJf "$backup_file" \
            "$(basename "$webroot")" 2>/dev/null || {
            log_error "Failed to create backup for: $site_domain"
            return $E_INTERNAL
        }
        chmod 600 "$backup_file"
        log_info "Site backup created: $backup_file"
    fi

    # Backup databases
    jq -r '.databases[]? | "\(.engine)|\(.name)"' "$state_file" 2>/dev/null | \
    while IFS='|' read -r engine db_name; do
        [[ -z "$engine" ]] && continue

        log_info "Backing up database: $db_name"
        local db_backup_file="/var/backups/vpsmgr/${site_domain}-${db_name}-${timestamp}.sql.xz"

        # Create temp SQL dump
        local temp_sql="/tmp/${db_name}-${timestamp}.sql"
        export_database "$engine" "$db_name" "$temp_sql" || {
            log_warn "Failed to export database: $db_name"
            rm -f "$temp_sql"
            return 0  # Continue despite failure
        }

        # Compress
        xz -9 -T0 "$temp_sql" -o "$db_backup_file" 2>/dev/null || {
            log_error "Failed to compress database backup: $db_name"
            rm -f "$temp_sql"
            return $E_INTERNAL
        }

        chmod 600 "$db_backup_file"
        log_info "Database backup created: $db_backup_file"
    done

    return 0
}

# Backup single site or all sites
if [[ "$all" == "true" ]]; then
    log_info "Backing up all sites..."

    # Get list of all sites from state directory
    local sites_dir="/var/lib/vpsmgr/sites"
    if [[ ! -d "$sites_dir" ]]; then
        log_error "Sites directory not found: $sites_dir"
        exit $E_NOTFOUND
    fi

    local backup_count=0
    for state_file in "$sites_dir"/*.json; do
        [[ -f "$state_file" ]] || continue
        local site_domain
        site_domain=$(basename "$state_file" .json)
        backup_site "$site_domain" || {
            log_warn "Backup failed for site: $site_domain"
        }
        ((backup_count++))
    done

    log_info "Backed up $backup_count sites"
else
    domain=$(normalize_domain "$domain") || exit $E_USAGE
    backup_site "$domain" || exit $?
fi

# Prune old backups (keep only 30 days by default)
log_info "Pruning old backups (retaining ${BACKUP_RETENTION_DAYS:-30} days)..."
find /var/backups/vpsmgr -type f -mtime "+${BACKUP_RETENTION_DAYS:-30}" -delete 2>/dev/null || true

# Run post-hook if provided (design decision D3: post-hook escape hatch)
if [[ -n "$post_hook" ]]; then
    log_info "Running post-hook..."
    eval "$post_hook" || {
        log_warn "Post-hook exited with non-zero status"
    }
fi

log_info "Backup operation completed"

exit $E_OK

#!/bin/bash
# Deploy application files to a site
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/php.sh"

require_root

# Parse arguments
declare -A args
args[domain]=""
args[source]=""

for arg in "$@"; do
    if [[ "$arg" =~ ^([a-z_]+)=(.+)$ ]]; then
        args["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    else
        log_error "Invalid argument format: $arg (use key=value)"
        exit $E_USAGE
    fi
done

domain="${args[domain]}"
source="${args[source]}"

if [[ -z "$domain" ]]; then
    log_error "domain is required"
    exit $E_USAGE
fi

if [[ -z "$source" ]]; then
    log_error "source is required (server-local path)"
    exit $E_USAGE
fi

domain=$(normalize_domain "$domain") || exit $E_USAGE

# Check if site exists
if ! site_exists "$domain"; then
    log_error "Site not found: $domain"
    exit $E_NOTFOUND
fi

# Validate source path (must be on same server, for security)
if [[ ! -e "$source" ]]; then
    log_error "Source path does not exist: $source"
    exit $E_NOTFOUND
fi

log_info "Deploying to site: $domain"

# Read site configuration
webroot=$(read_state "$domain" "webroot") || {
    log_error "Could not read webroot"
    exit $E_NOTFOUND
}

sftp_user=$(read_state "$domain" "sftp_user") || {
    log_error "Could not read SFTP user"
    exit $E_NOTFOUND
}

site_type=$(read_state "$domain" "type") || site_type="static"

log_info "Site type: $site_type, webroot: $webroot"

# Backup current deployment (optional but recommended)
log_info "Creating pre-deployment backup..."
local backup_dir="${webroot}/.backup-$(date +%s)"
mkdir -p "$backup_dir"

# Back up current content (if any)
if [[ -d "${webroot}" && "$(ls -A "$webroot" 2>/dev/null)" ]]; then
    log_debug "Backing up current content to $backup_dir"
    cp -r "${webroot}"/* "$backup_dir/" 2>/dev/null || true
fi

log_info "Deploying files from: $source"

# Copy files, preserving permissions and ownership
if [[ -d "$source" ]]; then
    # Source is directory, copy contents
    cp -r "${source%/}"/* "$webroot/" 2>/dev/null || {
        log_error "Failed to copy deployment files"
        # Restore backup
        rm -rf "${webroot:?}"/*
        cp -r "$backup_dir"/* "$webroot/" 2>/dev/null || true
        rm -rf "$backup_dir"
        exit $E_INTERNAL
    }
elif [[ -f "$source" ]]; then
    # Source is file, extract if archive, otherwise copy
    if [[ "$source" =~ \.(tar|tar\.gz|tar\.xz|tar\.bz2|zip)$ ]]; then
        log_info "Extracting archive: $source"
        case "$source" in
            *.tar)
                tar -xf "$source" -C "$webroot" 2>/dev/null || {
                    log_error "Failed to extract tar archive"
                    exit $E_INTERNAL
                }
                ;;
            *.tar.gz|*.tgz)
                tar -xzf "$source" -C "$webroot" 2>/dev/null || {
                    log_error "Failed to extract tar.gz archive"
                    exit $E_INTERNAL
                }
                ;;
            *.tar.xz)
                tar -xJf "$source" -C "$webroot" 2>/dev/null || {
                    log_error "Failed to extract tar.xz archive"
                    exit $E_INTERNAL
                }
                ;;
            *.tar.bz2)
                tar -xjf "$source" -C "$webroot" 2>/dev/null || {
                    log_error "Failed to extract tar.bz2 archive"
                    exit $E_INTERNAL
                }
                ;;
            *.zip)
                unzip -q -o "$source" -d "$webroot" 2>/dev/null || {
                    log_error "Failed to extract zip archive"
                    exit $E_INTERNAL
                }
                ;;
        esac
    else
        # Copy single file
        cp "$source" "$webroot/" || {
            log_error "Failed to copy file: $source"
            exit $E_INTERNAL
        }
    fi
else
    log_error "Source is neither file nor directory: $source"
    exit $E_NOTFOUND
fi

# Set proper permissions for site user
log_info "Setting permissions for site user: $sftp_user"
chown -R "${sftp_user}:www-data" "$webroot"
chmod -R u+rw,g+r,o-rwx "$webroot"
find "$webroot" -type d -exec chmod u+x,g+x {} \;

# If site type is PHP/WordPress, check syntax
if [[ "$site_type" == "php" || "$site_type" == "wordpress" ]]; then
    php_version=$(read_state "$domain" "php_version") || {
        log_warn "Could not determine PHP version for syntax check"
    }

    if [[ -n "$php_version" ]]; then
        log_info "Checking PHP syntax..."
        local syntax_errors=0

        find "$webroot" -name "*.php" -type f | while read -r php_file; do
            "php${php_version}" -l "$php_file" >/dev/null 2>&1 || {
                log_warn "PHP syntax error: $php_file"
                ((syntax_errors++))
            }
        done

        [[ $syntax_errors -gt 0 ]] && log_warn "Found $syntax_errors PHP syntax errors"
    fi

    # Reload PHP-FPM to clear opcache
    if [[ -n "$php_version" ]]; then
        log_info "Reloading PHP-FPM to clear cache..."
        systemctl reload "php${php_version}-fpm" || {
            log_warn "Failed to reload PHP-FPM"
        }
    fi
fi

# Clean up old backups (keep only 3 most recent)
log_debug "Cleaning up old backups..."
ls -dt "${webroot}"/.backup-* 2>/dev/null | tail -n +4 | xargs -r rm -rf || true

log_info "Deployment completed successfully"
log_info "Deployment location: $webroot"

exit $E_OK

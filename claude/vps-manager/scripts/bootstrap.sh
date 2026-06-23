#!/bin/bash
# VPS Manager Bootstrap — Initialize system and install dependencies
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/caddy.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/php.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/sftp.sh"

require_root

# Parse arguments
declare -A args
parse_args args "$@" || exit $E_USAGE

# Check if already bootstrapped (idempotent)
if [[ -f /etc/vpsmgr/vpsmgr.conf && \
      -d /var/lib/vpsmgr/sites && \
      "$(require_cmd caddy 2>/dev/null; echo 0)" == "0" ]]; then
    log_info "System already bootstrapped (idempotent, continuing...)"
else
    log_info "Bootstrapping VPS Manager system..."
fi

# Create directory structure
log_info "Creating VPS Manager directories..."
ensure_dir /etc/vpsmgr 755 root:root
ensure_dir /var/lib/vpsmgr/sites 755 root:root
ensure_dir /var/log/vpsmgr 755 root:root
ensure_dir /var/backups/vpsmgr 700 root:root
ensure_dir /etc/caddy/sites 755 root:root

# Copy configuration to system
if [[ ! -f /etc/vpsmgr/vpsmgr.conf ]]; then
    log_info "Installing VPS Manager configuration..."
    cp "$(dirname "${BASH_SOURCE[0]}")/../config/vpsmgr.conf" /etc/vpsmgr/vpsmgr.conf
    chmod 644 /etc/vpsmgr/vpsmgr.conf
fi

# Detect and resolve dynamic versions
log_info "Resolving software versions..."

local php_version
php_version=$(detect_php_version) || {
    log_error "Could not detect PHP version"
    exit $E_MISSING_DEP
}
log_info "PHP latest: $php_version"

local php_fallback
php_fallback=$(get_php_fallback "$php_version") || {
    log_error "Could not compute PHP fallback"
    exit $E_INTERNAL
}
log_info "PHP fallback: $php_fallback"

# Update configuration with resolved versions
sed -i "s/^PHP_DEFAULT_VERSION=\"\"/PHP_DEFAULT_VERSION=\"${php_version}\"/" /etc/vpsmgr/vpsmgr.conf
sed -i "s/^PHP_FALLBACK_VERSION=\"\"/PHP_FALLBACK_VERSION=\"${php_fallback}\"/" /etc/vpsmgr/vpsmgr.conf

# Install base dependencies
log_info "Installing base dependencies..."
apt-get update -qq
apt-get upgrade -y -qq >/dev/null 2>&1 || log_warn "apt-get upgrade had issues"

ensure_package "curl"
ensure_package "wget"
ensure_package "git"
ensure_package "jq"
ensure_package "net-tools"
ensure_package "netcat-openbsd"
ensure_package "lsb-release"
ensure_package "gnupg"
ensure_package "apt-transport-https"
ensure_package "software-properties-common"

# Install Caddy
log_info "Installing Caddy web server..."
install_caddy || exit $?
ensure_caddy_import

# Install PHP
log_info "Installing PHP $php_version with FPM..."
install_php "$php_version" || exit $?

# Install MariaDB
log_info "Installing MariaDB..."
install_mariadb || {
    log_warn "MariaDB installation had issues, continuing..."
}

# Install PostgreSQL
log_info "Installing PostgreSQL..."
install_postgres || {
    log_warn "PostgreSQL installation had issues, continuing..."
}

# Install WP-CLI
log_info "Installing WP-CLI..."
install_wp_cli || {
    log_warn "WP-CLI installation had issues, continuing..."
}

# Configure OpenSSH for SFTP
log_info "Configuring OpenSSH for chrooted SFTP..."
configure_sshd_for_sftp || {
    log_warn "OpenSSH configuration had issues, but SFTP may still work"
}

# Create www-data group if not exists
if ! getent group www-data > /dev/null 2>&1; then
    log_info "Creating www-data group..."
    groupadd -f www-data
fi

# Ensure system services are enabled
log_info "Enabling system services..."
systemctl enable caddy 2>/dev/null || true
systemctl enable ssh 2>/dev/null || true
systemctl enable php${php_version}-fpm 2>/dev/null || true
systemctl enable mariadb 2>/dev/null || true
systemctl enable postgresql 2>/dev/null || true

# Set up logging
log_info "Setting up logging..."
mkdir -p /var/log/caddy
mkdir -p /var/log/php-fpm
chmod 755 /var/log/caddy
chmod 755 /var/log/php-fpm

# Create initial state directory (empty)
log_info "Initializing state directory..."
[[ ! -f /var/lib/vpsmgr/sites/.gitkeep ]] && \
    touch /var/lib/vpsmgr/sites/.gitkeep

# Verify installation
log_info "Verifying bootstrap..."
local errors=0

require_cmd caddy || ((errors++))
require_cmd php || ((errors++))
require_cmd mysql 2>/dev/null || ((errors++))
require_cmd psql 2>/dev/null || ((errors++))
require_cmd wp 2>/dev/null || ((errors++))

if [[ $errors -gt 0 ]]; then
    log_warn "Bootstrap completed with $errors verification warnings"
    exit 0
fi

log_info "VPS Manager bootstrap completed successfully"
log_info "  - Configuration: /etc/vpsmgr/vpsmgr.conf"
log_info "  - State: /var/lib/vpsmgr/sites/"
log_info "  - Logs: /var/log/vpsmgr/"
log_info "  - Backups: /var/backups/vpsmgr/"

exit $E_OK

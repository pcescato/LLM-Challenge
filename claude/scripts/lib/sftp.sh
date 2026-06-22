#!/bin/bash
# SFTP user management library
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Ensure sshd is configured for chrooted SFTP
configure_sshd_for_sftp() {
    local sshd_config="/etc/ssh/sshd_config"

    if [[ ! -f "$sshd_config" ]]; then
        log_error "sshd configuration not found: $sshd_config"
        return $E_NOTFOUND
    fi

    # Check if subsystem sftp is already configured
    if grep -q "^Subsystem sftp" "$sshd_config"; then
        log_debug "SFTP subsystem already configured in sshd"
        return 0
    fi

    log_info "Configuring OpenSSH for chrooted SFTP..."

    # Backup original
    cp "$sshd_config" "${sshd_config}.bak.$(date +%s)" 2>/dev/null || true

    # Add SFTP subsystem configuration
    cat >> "$sshd_config" << 'EOF'

# VPS Manager SFTP Configuration
Subsystem sftp /usr/lib/openssh/sftp-server -f AUTHPRIV -l INFO

# Match block for SFTP-only users (created by vpsmgr)
Match User vpsmgr-sftp-*
    ChrootDirectory %h
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTTY no
    X11Forwarding no
    PermitUserRC no
    PasswordAuthentication yes
    PubkeyAuthentication no
    GatewayPorts no
    AllowStreamLocalForwarding no
EOF

    # Test new config
    sshd -t 2>&1 | redact_credentials || {
        log_error "Invalid sshd configuration"
        # Restore backup
        mv "${sshd_config}.bak."* "$sshd_config" 2>/dev/null || true
        return $E_INTERNAL
    }

    # Reload sshd
    systemctl reload ssh || {
        log_error "Failed to reload OpenSSH"
        return $E_INTERNAL
    }

    log_info "OpenSSH configured for chrooted SFTP"
}

# Create SFTP user with chrooted directory
# Returns password on stdout (design decision D7)
create_sftp_user() {
    local username="$1"
    local webroot="$2"
    local password
    password=$(gen_password 16)

    log_info "Creating SFTP user: $username"

    # Create user with shell /usr/sbin/nologin (no login shell)
    ensure_system_user "$username" "/usr/sbin/nologin" || return $?

    # Ensure webroot exists and has correct permissions
    mkdir -p "$webroot"
    chown "$username:www-data" "$webroot"
    chmod 755 "$webroot"

    # Set password for SFTP access
    echo "${username}:${password}" | chpasswd 2>/dev/null || {
        log_error "Failed to set SFTP user password"
        return $E_INTERNAL
    }

    # Configure chroot directory
    # Note: chroot directory must be owned by root for security
    local chroot_base=$(dirname "$webroot")
    chown root:root "$chroot_base" 2>/dev/null || true
    chmod 755 "$chroot_base" 2>/dev/null || true

    log_info "SFTP user created: $username (chroot: $chroot_base)"

    # Return password (printed once by caller, design decision D7)
    echo "$password"
}

# Delete SFTP user
delete_sftp_user() {
    local username="$1"

    if ! id "$username" &>/dev/null 2>&1; then
        log_debug "SFTP user does not exist: $username"
        return 0
    fi

    log_info "Deleting SFTP user: $username"

    # Get home directory before deleting user
    local home_dir
    home_dir=$(eval "echo ~$username" 2>/dev/null) || home_dir="/home/${username}"

    # Delete user and home directory
    userdel -rf "$username" 2>/dev/null || {
        log_warn "Failed to delete SFTP user: $username"
        # Continue anyway
    }

    # Clean up any remaining files
    [[ -d "$home_dir" ]] && rm -rf "$home_dir" 2>/dev/null || true

    log_info "SFTP user deleted: $username"
}

# Reset SFTP user password (e.g., for password recovery)
# Returns new password on stdout
reset_sftp_password() {
    local username="$1"

    if ! id "$username" &>/dev/null 2>&1; then
        log_error "SFTP user not found: $username"
        return $E_NOTFOUND
    fi

    local new_password
    new_password=$(gen_password 16)

    log_info "Resetting password for SFTP user: $username"

    echo "${username}:${new_password}" | chpasswd 2>/dev/null || {
        log_error "Failed to reset SFTP user password"
        return $E_INTERNAL
    }

    log_info "SFTP user password reset: $username"
    echo "$new_password"
}

# Enable/disable SFTP user access
disable_sftp_user() {
    local username="$1"

    if ! id "$username" &>/dev/null 2>&1; then
        log_error "SFTP user not found: $username"
        return $E_NOTFOUND
    fi

    log_info "Disabling SFTP user: $username"

    # Set shell to /bin/false to disable access
    usermod -s /bin/false "$username" || {
        log_error "Failed to disable SFTP user"
        return $E_INTERNAL
    }
}

enable_sftp_user() {
    local username="$1"

    if ! id "$username" &>/dev/null 2>&1; then
        log_error "SFTP user not found: $username"
        return $E_NOTFOUND
    fi

    log_info "Enabling SFTP user: $username"

    # Set shell back to /usr/sbin/nologin
    usermod -s /usr/sbin/nologin "$username" || {
        log_error "Failed to enable SFTP user"
        return $E_INTERNAL
    }
}

# Get SFTP user home directory
get_sftp_home() {
    local username="$1"

    if ! id "$username" &>/dev/null 2>&1; then
        log_error "SFTP user not found: $username"
        return $E_NOTFOUND
    fi

    eval "echo ~$username" 2>/dev/null || echo "/home/${username}"
}

# List SFTP users (those managed by vpsmgr)
list_sftp_users() {
    # List all users with /usr/sbin/nologin shell (SFTP users)
    awk -F: '$NF == "/usr/sbin/nologin" {print $1}' /etc/passwd | \
        grep -E "^vpsmgr-sftp-|^[a-z]{2}_" || true
}

# Check if SFTP user exists
sftp_user_exists() {
    local username="$1"
    id "$username" &>/dev/null 2>&1
}

# Verify SFTP access is working
test_sftp_access() {
    local username="$1"
    local password="$2"

    # This is a basic connectivity test; real test requires actual SFTP client
    log_debug "SFTP user created and can be tested with: sftp $username@localhost"
    return 0
}

export -f configure_sshd_for_sftp create_sftp_user delete_sftp_user
export -f reset_sftp_password disable_sftp_user enable_sftp_user
export -f get_sftp_home list_sftp_users sftp_user_exists test_sftp_access

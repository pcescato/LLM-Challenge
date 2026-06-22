#!/usr/bin/env bash
# sftp.sh — SFTP user management functions
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Check if sftp subsystem is configured in sshd
sftp_sshd_configured() {
    grep -q '^Subsystem\s\+sftp\s\+internal-sftp' /etc/ssh/sshd_config 2>/dev/null
}

sftp_setup_sshd() {
    if sftp_sshd_configured; then
        log_info "SFTP subsystem already configured in sshd"
        return 0
    fi

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s) 2>/dev/null || true

    # Enable internal-sftp subsystem
    sed -i 's|^#\?Subsystem\s\+sftp\s\+.*|Subsystem sftp internal-sftp|' /etc/ssh/sshd_config
    if ! grep -q '^Subsystem\s\+sftp' /etc/ssh/sshd_config; then
        echo 'Subsystem sftp internal-sftp' >> /etc/ssh/sshd_config
    fi

    # Add Match Group block for sftp-only users if not present
    if ! grep -q 'Match Group sftp-only' /etc/ssh/sshd_config; then
        cat >> /etc/ssh/sshd_config <<'SSHDCONF'

# SFTP-only isolated users — managed by vpsmgr
Match Group sftp-only
    ChrootDirectory %h
    ForceCommand internal-sftp
    PasswordAuthentication yes
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
SSHDCONF
        log_info "Added SFTP Match Group to sshd_config"
    fi

    systemctl reload sshd 2>/dev/null || systemctl restart sshd
    log_info "SSHD configured for SFTP"
}

# Create an SFTP user with chroot isolation
# Password is generated in memory, printed once, then forgotten
sftp_user_create() {
    local sitename="$1"

    if id "${sitename}" &>/dev/null; then
        log_warn "SFTP user '${sitename}' already exists"
        return 0
    fi

    # Generate password in memory
    local sftp_pass
    sftp_pass=$(generate_password 24)

    # Create user with home directory
    # Root must own the chroot directory, user owns the content subdir
    local home_dir="${SITE_BASE_HOME}/${sitename}"

    useradd -m -d "${home_dir}" -s "${SITE_SHELL}" -G sftp-only "${sitename}" 2>/dev/null

    # Disable SSH login for this user (SFTP only via Match Group)
    passwd --delete "${sitename}" 2>/dev/null || true

    # Set password
    echo "${sitename}:${sftp_pass}" | chpasswd

    # Ensure proper chroot permissions: root:root owns the home, 755
    chown root:root "${home_dir}"
    chmod 755 "${home_dir}"

    # Create the content directory that the user can write to
    mkdir -p "${home_dir}/public"
    chown "${sitename}:${sitename}" "${home_dir}/public"
    chmod 750 "${home_dir}/public"

    # Create tmp directory for sessions
    mkdir -p "${home_dir}/tmp"
    chown "${sitename}:${sitename}" "${home_dir}/tmp"
    chmod 700 "${home_dir}/tmp"

    log_info "SFTP user created: ${sitename}"

    # Print password once
    emit_credentials "SFTP_USER=${sitename} SFTP_HOST=$(hostname -f) SFTP_PASSWORD=${sftp_pass}" ""

    # Wipe password from shell memory
    unset sftp_pass
}

# Remove SFTP user and home directory
sftp_user_remove() {
    local sitename="$1"

    if id "${sitename}" &>/dev/null; then
        # Kill any running processes for this user
        pkill -u "${sitename}" 2>/dev/null || true

        userdel -r "${sitename}" 2>/dev/null || true
        log_info "SFTP user removed: ${sitename}"
    else
        log_info "SFTP user '${sitename}' does not exist — skipping"
    fi
}

# Disable password auth globally for management SSH users
sftp_disable_global_password_auth() {
    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s) 2>/dev/null || true

    # Disable password auth globally; sftp-only Match Group overrides this
    sed -i 's/^#\?PasswordAuthentication\s\+.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication\s\+.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?UsePAM\s\+.*/UsePAM yes/' /etc/ssh/sshd_config

    log_info "Global password authentication disabled for SSH management users"
}
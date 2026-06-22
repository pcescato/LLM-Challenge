#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

sftp_create_user() {
    local domain="$1" webroot="$2"
    local username sftp_pass
    username="$(site_user_for "$domain")"

    if id "$username" &>/dev/null 2>&1; then
        info "SFTP user ${username} already exists"
        echo ""
        return
    fi

    useradd -m -d "/home/$username" -s /usr/sbin/nologin "$username"
    mkdir -p "$webroot"
    chown "$username:$username" "/home/$username"
    chown "$username:$username" "$webroot"
    chmod 755 "/home/$username"
    chmod 755 "$webroot"

    sftp_pass="$(openssl rand -base64 18)"
    echo "$username:$sftp_pass" | chpasswd

    # Chroot the user to their home
    mkdir -p /etc/ssh/sshd_config.d/
    cat > /etc/ssh/sshd_config.d/vpsmgr-${username}.conf <<SSHD
Match User ${username}
    ChrootDirectory /home/${username}
    ForceCommand internal-sftp
    PasswordAuthentication yes
    PermitTTY no
    AllowTcpForwarding no
    X11Forwarding no
SSHD

    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    info "SFTP user ${username} created for ${domain}"

    # Print password once — will be captured by the caller, never stored
    echo "$sftp_pass"
}

sftp_remove_user() {
    local domain="$1"
    local username
    username="$(site_user_for "$domain")"

    if id "$username" &>/dev/null 2>&1; then
        userdel -r "$username" 2>/dev/null || userdel "$username" 2>/dev/null || true
        rm -f "/etc/ssh/sshd_config.d/vpsmgr-${username}.conf"
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        info "SFTP user ${username} removed"
    fi
}

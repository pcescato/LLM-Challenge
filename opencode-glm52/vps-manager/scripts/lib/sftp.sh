#!/usr/bin/env bash
# lib/sftp.sh — chrooted SFTP user lifecycle for site deployment.
# Password generated in-memory, printed once to caller, never stored (D1/D7).
# Relies on lib/common.sh (already sourced by caller).

# sftp_user_home <sftp_user>
sftp_user_home() {
    local user="$1"
    echo "${VPSMGR_HOME_BASE}/${user}"
}

# sftp_create_user <domain> <sftp_user>
# Returns generated password on stdout (caller prints with markers).
sftp_create_user() {
    local domain="$1"
    local user="$2"
    local home
    home="$(sftp_user_home "${user}")"

    # Create the system user if it doesn't exist (idempotent).
    if ! id "${user}" >/dev/null 2>&1; then
        useradd \
            --home-dir "${home}" \
            --shell "${VPSMGR_SFTP_SHELL}" \
            --user-group \
            --create-home \
            "${user}"
        log_info "sftp user created: ${user}"
    else
        log_info "sftp user already exists: ${user}"
    fi

    # Webroot under home. The chroot parent must be root-owned (sshd requirement).
    mkdir -p "${home}/public"
    chown root:root "${home}"
    chmod 755 "${home}"
    chown "${user}:${user}" "${home}/public"
    chmod 755 "${home}/public"

    # Generate password in-memory, set it, then return to caller.
    local pass
    pass="$(gen_password 24)"
    echo "${user}:${pass}" | chpasswd 2>/dev/null

    # Lock the user out of shell login entirely (only SFTP).
    usermod -s "${VPSMGR_SFTP_SHELL}" "${user}" 2>/dev/null || true

    # Return password to caller (NOT logged).
    echo "${pass}"
}

# Ensure the global sshd_config has a Match block for chrooted SFTP users.
# We tag site users with a common group to match on.
sftp_configure_sshd() {
    local group="sftponly"
    if ! getent group "${group}" >/dev/null 2>&1; then
        groupadd "${group}" 2>/dev/null || true
    fi

    local sshd_conf="/etc/ssh/sshd_config"
    local marker="# vps-manager-sftp-chroot"
    if grep -q "${marker}" "${sshd_conf}" 2>/dev/null; then
        return 0
    fi
    {
        echo ""
        echo "${marker} — do not remove"
        echo "Match Group ${group}"
        echo "    ChrootDirectory %h"
        echo "    ForceCommand internal-sftp"
        echo "    PermitTunnel no"
        echo "    AllowAgentForwarding no"
        echo "    AllowTcpForwarding no"
        echo "    X11Forwarding no"
        echo "    PasswordAuthentication yes"
        echo "# end ${marker}"
    } >> "${sshd_conf}"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    log_info "sshd configured for chrooted SFTP (group=${group})"
}

# Add an existing user to the sftponly group.
sftp_add_to_group() {
    local user="$1"
    local group="sftponly"
    usermod -aG "${group}" "${user}" 2>/dev/null || true
}

sftp_remove_user() {
    local user="$1"
    if id "${user}" >/dev/null 2>&1; then
        userdel -r "${user}" 2>/dev/null || userdel "${user}" 2>/dev/null || true
        log_info "sftp user removed: ${user}"
    fi
}

# Disable password auth globally for management users (D7).
# Site SFTP users still use passwords via the Match block above.
sftp_disable_global_password_auth() {
    local sshd_conf="/etc/ssh/sshd_config"
    # Use sshd -T to check effective config; only patch file if needed.
    if sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes'; then
        # Append an override near the top-level (before any Match block).
        if ! grep -qi "^PasswordAuthentication no" "${sshd_conf}" 2>/dev/null; then
            sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/I' "${sshd_conf}" 2>/dev/null || true
            grep -qi '^PasswordAuthentication no' "${sshd_conf}" 2>/dev/null \
                || sed -i '1i PasswordAuthentication no' "${sshd_conf}"
        fi
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        log_info "global SSH password auth disabled"
    fi
}

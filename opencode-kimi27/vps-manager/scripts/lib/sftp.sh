#!/usr/bin/env bash
# scripts/lib/sftp.sh — per-site chrooted SFTP user helpers.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SFTP_CONFIG_FILE="/etc/ssh/sshd_config.d/vpsmgr-sftp.conf"

sftp_chroot_dir() {
    local user="$1"
    echo "${SITES_ROOT}/${user}"
}

sftp_webroot() {
    local user="$1"
    echo "$(sftp_chroot_dir "${user}")/${WEBROOT_SUBDIR}"
}

sftp_user_exists() {
    id "$1" >/dev/null 2>&1
}

sftp_render_match_block() {
    local user="$1"
    local chroot="$2"
    cat <<EOF
Match User ${user}
    ChrootDirectory ${chroot}
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF
}

sftp_ensure_sshd_config() {
    local exclude_user="${1:-}"
    require_command sshd
    mkdir -p "$(dirname "${SFTP_CONFIG_FILE}")"
    : > "${SFTP_CONFIG_FILE}"

    local sp user chroot
    for sp in "${STATE_DIR}"/*.json; do
        [[ -f ${sp} ]] || continue
        user=$(jq -r '.sftp_user // empty' "${sp}")
        [[ -n ${user} ]] || continue
        [[ ${user} == "${exclude_user}" ]] && continue
        chroot=$(sftp_chroot_dir "${user}")
        sftp_render_match_block "${user}" "${chroot}" >> "${SFTP_CONFIG_FILE}"
    done

    chmod 0644 "${SFTP_CONFIG_FILE}"
    systemctl reload sshd || die_internal "failed to reload sshd"
}

sftp_user_create() {
    local domain="$1"
    local user_var="$2"
    local pass_var="$3"

    local user chroot webroot pass
    user=$(domain_to_sftp_user "${domain}")
    chroot=$(sftp_chroot_dir "${user}")
    webroot=$(sftp_webroot "${user}")

    mkdir -p "${webroot}"
    chmod 0755 "${chroot}"
    chown root:root "${chroot}"
    chmod 0750 "${webroot}"
    chown "${user}:${user}" "${webroot}" 2>/dev/null || true

    if ! sftp_user_exists "${user}"; then
        useradd -d "${chroot}" -s "${SFTP_SHELL}" -M "${user}" || die_internal "failed to create system user ${user}"
    fi

    chown "${user}:${user}" "${webroot}"
    chmod 0755 "${webroot}"

    pass=$(generate_password 32)
    printf '%s:%s\n' "${user}" "${pass}" | chpasswd || die_internal "failed to set password for ${user}"

    # Rebuild the consolidated sshd Match config for all sites.
    sftp_ensure_sshd_config

    printf -v "${user_var}" '%s' "${user}"
    printf -v "${pass_var}" '%s' "${pass}"
    vpsmgr_log INFO "created SFTP user ${user} for ${domain}"
}

sftp_user_delete() {
    local domain="$1"
    local user
    user=$(domain_to_sftp_user "${domain}")

    if sftp_user_exists "${user}"; then
        userdel -f -r "${user}" 2>/dev/null || true
        vpsmgr_log INFO "deleted SFTP user ${user}"
    fi

    local chroot
    chroot=$(sftp_chroot_dir "${user}")
    if [[ -d ${chroot} ]]; then
        rm -rf "${chroot}"
    fi

    sftp_ensure_sshd_config "${user}"
}

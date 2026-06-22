#!/usr/bin/env bash
# bootstrap.sh — Initial server setup. Idempotent. Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Source lib modules
source "${SCRIPT_DIR}/lib/caddy.sh"
source "${SCRIPT_DIR}/lib/php.sh"
source "${SCRIPT_DIR}/lib/db.sh"
source "${SCRIPT_DIR}/lib/sftp.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0")

Bootstraps the server for vpsmgr. Idempotent — safe to re-run.

Sets up:
  - System packages and repositories
  - Caddy (stable channel)
  - PHP-FPM (latest + previous minor)
  - MariaDB
  - PostgreSQL (latest)
  - WP-CLI
  - SFTP configuration
  - vpsmgr directory structure
  - API token
  - systemd services
  - backup retention cron
USAGE
    exit 0
}

main() {
    require_root

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            *) echo "Unknown option: $1" >&2; usage ;;
        esac
        shift
    done

    log_info "=== VPS Manager Bootstrap ==="
    log_info "Host: $(hostname -f)"

    # --- System setup ---
    log_info "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq 2>/dev/null || true

    local deps=(
        curl wget gnupg lsb-release ca-certificates
        apt-transport-https software-properties-common
        openssl pwgen python3 jq
        certbot
    )
    apt-get install -y -qq "${deps[@]}" 2>/dev/null

    # --- Create directories ---
    log_info "Creating vpsmgr directories..."
    mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${LOG_DIR}" "${CADDY_SITES_DIR}"
    chmod 750 "${LOG_DIR}"
    chmod 700 "${BACKUP_DIR}"
    chmod 750 "${STATE_DIR}"

    # Copy config if not already installed
    if [[ ! -f "/etc/vpsmgr/vpsmgr.conf" ]]; then
        mkdir -p /etc/vpsmgr
        cp "${SCRIPT_DIR}/../config/vpsmgr.conf" /etc/vpsmgr/vpsmgr.conf
        log_info "Config installed to /etc/vpsmgr/vpsmgr.conf"
    fi

    # --- Install Caddy ---
    caddy_install
    caddy_setup_base

    # --- Install PHP ---
    php_versions=$(php_install_with_fallback)

    # --- Install databases ---
    mariadb_install
    local pg_version
    pg_version=$(postgresql_install)

    # --- Install WP-CLI ---
    source "${SCRIPT_DIR}/lib/wp.sh"
    wp_cli_install

    # --- Configure SFTP ---
    sftp_setup_sshd
    sftp_disable_global_password_auth

    # If sftp-only group doesn't exist, create it
    if ! getent group sftp-only &>/dev/null; then
        groupadd sftp-only
    fi

    # --- Generate API token ---
    if [[ ! -f "${API_TOKEN_FILE}" ]]; then
        local api_token
        api_token=$(generate_password 48)
        echo "${api_token}" > "${API_TOKEN_FILE}"
        chmod 600 "${API_TOKEN_FILE}"
        log_info "API token generated at ${API_TOKEN_FILE}"
        emit_credentials "API_TOKEN=${api_token}" ""
        unset api_token
    else
        log_info "API token already exists"
    fi

    # --- Install systemd units ---
    local src_systemd="${SCRIPT_DIR}/../systemd"
    if [[ -d "${src_systemd}" ]]; then
        cp "${src_systemd}/vpsmgr-api.service" /etc/systemd/system/vpsmgr-api.service 2>/dev/null || true
        cp "${src_systemd}/vpsmgr-backup-prune.timer" /etc/systemd/system/vpsmgr-backup-prune.timer 2>/dev/null || true
        systemctl daemon-reload
        systemctl enable vpsmgr-api 2>/dev/null || true
        systemctl enable vpsmgr-backup-prune.timer 2>/dev/null || true
    fi

    # --- Setup backup retention cron ---
    local prune_job="${BACKUP_PRUNE_CRON} find ${BACKUP_DIR} -type f -name '*.tar.gz' -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null"
    local tmp_cron
    tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v 'vpsmgr.*prune' > "${tmp_cron}" || true
    echo "# vpsmgr backup pruning" >> "${tmp_cron}"
    echo "${prune_job}" >> "${tmp_cron}"
    crontab - < "${tmp_cron}"
    rm -f "${tmp_cron}"

    # --- Summary ---
    log_info "=== Bootstrap Complete ==="
    log_info "Caddy:     $(caddy version 2>/dev/null | head -1 || echo 'installed')"
    log_info "PHP:       ${php_versions}"
    log_info "MariaDB:   $(mariadb --version 2>/dev/null || echo 'installed')"
    log_info "PostgreSQL: v${pg_version}"
    log_info "WP-CLI:    $(wp --version 2>/dev/null | head -1 || echo 'installed')"
    log_info "State dir: ${STATE_DIR}"
    log_info "Backup dir: ${BACKUP_DIR}"
    log_info "Log dir:    ${LOG_DIR}"

    exit 0
}

main "$@"
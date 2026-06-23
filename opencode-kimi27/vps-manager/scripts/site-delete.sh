#!/usr/bin/env bash
# scripts/site-delete.sh — delete a site and all associated resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/caddy.sh
source "${SCRIPT_DIR}/lib/caddy.sh"
# shellcheck source=lib/php.sh
source "${SCRIPT_DIR}/lib/php.sh"
# shellcheck source=lib/db.sh
source "${SCRIPT_DIR}/lib/db.sh"
# shellcheck source=lib/sftp.sh
source "${SCRIPT_DIR}/lib/sftp.sh"

DOMAIN=""
SKIP_BACKUP=false
CONFIRM=""

usage() {
    cat >&2 <<EOF
Usage: $0 <domain> [--skip-backup] [--confirm "DELETE <domain>"]
EOF
    exit 1
}

parse_args() {
    [[ $# -ge 1 ]] || usage
    DOMAIN="$1"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            --confirm)
                CONFIRM="$2"
                shift 2
                ;;
            *)
                die_input "unknown option: $1"
                ;;
        esac
    done
}

confirm_skip_backup() {
    local expected="DELETE ${DOMAIN}"
    if [[ -n ${CONFIRM} ]]; then
        if [[ ${CONFIRM} != "${expected}" ]]; then
            die_input "confirmation mismatch; expected: ${expected}"
        fi
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die_input "cannot prompt for skip-backup confirmation without a TTY; use --confirm"
    fi
    local answer
    read -rp "Type ${expected} to confirm skipping backup: " answer
    if [[ ${answer} != "${expected}" ]]; then
        die_input "confirmation mismatch; aborting"
    fi
}

prune_old_backups() {
    local site_dir="${BACKUP_DIR}/${DOMAIN}"
    if [[ -d ${site_dir} ]]; then
        find "${site_dir}" -type f -mtime "+${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
        vpsmgr_log INFO "pruned backups older than ${BACKUP_RETENTION_DAYS} days for ${DOMAIN}"
    fi
}

main() {
    require_root
    require_command jq
    parse_args "$@"
    validate_domain "${DOMAIN}"

    if ! state_exists "${DOMAIN}"; then
        die_notfound "site not found: ${DOMAIN}"
    fi

    if [[ ${SKIP_BACKUP} == true ]]; then
        confirm_skip_backup
    else
        vpsmgr_log INFO "backing up ${DOMAIN} before deletion"
        "${SCRIPT_DIR}/backup.sh" --domain "${DOMAIN}"
    fi

    local type sftp_user php_version proxy_target caddy_file pool_file
    type=$(state_get "${DOMAIN}" '.type')
    sftp_user=$(state_get "${DOMAIN}" '.sftp_user')
    php_version=$(state_get "${DOMAIN}" '.php_version')
    caddy_file=$(state_get "${DOMAIN}" '.caddy_block')
    pool_file=$(state_get "${DOMAIN}" '.php_pool')

    # Drop databases before removing user/webroot.
    local dbs
    dbs=$(state_get "${DOMAIN}" '.databases')
    local count
    count=$(jq 'length' <<< "${dbs}")
    if [[ ${count} -gt 0 ]]; then
        local i
        for i in $(seq 0 $((count - 1))); do
            local engine db_name db_user
            engine=$(jq -r ".[${i}].engine" <<< "${dbs}")
            db_name=$(jq -r ".[${i}].name" <<< "${dbs}")
            db_user=$(jq -r ".[${i}].user" <<< "${dbs}")
            db_drop "${engine}" "${db_name}" "${db_user}"
        done
    fi

    # Remove Caddy config and reload.
    caddy_remove_site "${DOMAIN}"
    if caddy_global_configured; then
        caddy_reload
    fi

    # Remove PHP pool and reload.
    if [[ -n ${php_version} && ${php_version} != "null" ]]; then
        php_remove_pool "${DOMAIN}" "${php_version}"
        php_reload "${php_version}"
    fi

    # Remove SFTP user and chroot/webroot.
    sftp_user_delete "${DOMAIN}"

    # Remove state.
    rm -f "$(state_path "${DOMAIN}")"

    prune_old_backups

    vpsmgr_log INFO "site ${DOMAIN} deleted"
    echo "Site ${DOMAIN} deleted."
}

main "$@"

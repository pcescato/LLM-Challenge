#!/usr/bin/env bash
# site-delete.sh — Delete a site with automatic backup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/caddy.sh"
source "${SCRIPT_DIR}/lib/php.sh"
source "${SCRIPT_DIR}/lib/sftp.sh"
source "${SCRIPT_DIR}/lib/db.sh"
source "${SCRIPT_DIR}/lib/wp.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--skip-backup] --domain <domain>

Deletes a site: removes Caddy block, PHP pool, SFTP user, webroot, databases,
and state file. Creates a backup before deletion unless --skip-backup is used.

Options:
  --domain DOMAIN      Domain to delete (required)
  --skip-backup        Skip automatic backup (requires explicit confirmation)
  --help               Show this help
USAGE
    exit 1
}

backup_site() {
    local domain="$1"
    log_info "Creating backup before deletion for ${domain}..."
    "${SCRIPT_DIR}/backup.sh" --domain "${domain}"
}

main() {
    require_root

    local domain=""
    local skip_backup="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)      domain="$2"; shift 2 ;;
            --skip-backup) skip_backup="true"; shift ;;
            -h|--help)     usage ;;
            *)             echo "Unknown option: $1"; usage ;;
        esac
    done

    if [[ -z "${domain}" ]]; then
        exit_input_error "--domain is required"
    fi

    validate_domain "${domain}"

    if [[ ! -f "$(state_file "${domain}")" ]]; then
        exit_not_found "Site '${domain}' not found"
    fi

    # Read state
    local state
    state=$(read_state "${domain}")

    local site_type sftp_user webroot php_version php_pool caddy_block proxy_target
    site_type=$(echo "${state}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["type"])' 2>/dev/null || echo "")
    sftp_user=$(echo "${state}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sftp_user",""))' 2>/dev/null || echo "")
    webroot=$(echo "${state}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["webroot"])' 2>/dev/null || echo "")
    php_version=$(echo "${state}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("php_version") or "")' 2>/dev/null || echo "")
    caddy_block=$(echo "${state}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("caddy_block",""))' 2>/dev/null || echo "")

    # --- Skip-backup confirmation ---
    if [[ "${skip_backup}" == "true" ]]; then
        echo -n "Type DELETE ${domain} to confirm deletion without backup: "
        read -r confirmation
        if [[ "${confirmation}" != "DELETE ${domain}" ]]; then
            exit_input_error "Confirmation failed. Aborting deletion."
        fi
    else
        backup_site "${domain}"
    fi

    # --- Remove Caddy block ---
    caddy_remove_block "${domain}"
    set +e
    caddy_reload 2>/dev/null
    set -e

    # --- Remove PHP pool ---
    if [[ -n "${php_version}" && -n "${sftp_user}" ]]; then
        php_pool_remove "${domain}" "${php_version}"
        php_fpm_reload "${php_version}" 2>/dev/null || true
    fi

    # --- Remove databases ---
    local databases
    databases=$(echo "${state}" | python3 -c '
import sys, json
dbs = json.load(sys.stdin).get("databases", [])
for db in dbs:
    print(json.dumps(db))
' 2>/dev/null || true)

    while IFS= read -r db_json; do
        [[ -z "${db_json}" ]] && continue
        local engine name db_user
        engine=$(echo "${db_json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["engine"])' 2>/dev/null)
        name=$(echo "${db_json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["name"])' 2>/dev/null)
        db_user="${sftp_user}"

        case "${engine}" in
            mariadb)
                mariadb_delete_database "${name}" "${db_user}"
                ;;
            postgresql)
                postgresql_delete_database "${name}" "${db_user}"
                ;;
        esac
    done <<< "${databases}"

    # --- Remove SFTP user ---
    sftp_user_remove "${sftp_user}"

    # --- Remove webroot ---
    if [[ -d "${webroot}" ]]; then
        rm -rf "${webroot:?}"
        log_info "Webroot removed: ${webroot}"
    fi

    # Remove home directory if empty
    local home_dir="/home/${sftp_user}"
    if [[ -d "${home_dir}" && "$(ls -A "${home_dir}" 2>/dev/null)" == "" ]]; then
        rm -rf "${home_dir:?}"
    fi

    # --- Remove state file ---
    delete_state "${domain}"

    log_info "Site deleted: ${domain}"
    echo "Site '${domain}' has been deleted."

    exit 0
}

main "$@"
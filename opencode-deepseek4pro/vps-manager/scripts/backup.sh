#!/usr/bin/env bash
# backup.sh — Create and manage site backups
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/db.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0") --domain <domain> | --all [--post-hook <cmd>] [--list]

Creates a backup of a site (or all sites). Backup includes:
  - Site files (webroot tarball)
  - Database dumps for each database associated with the site

Options:
  --domain DOMAIN    Domain to back up
  --all              Back up all sites
  --post-hook CMD    Command to run after backup (e.g. rclone sync)
  --list             List existing backups
  --help             Show this help
USAGE
    exit 1
}

backup_single_site() {
    local domain="$1"
    local post_hook="${2:-}"

    local sf
    sf=$(state_file "${domain}")

    if [[ ! -f "${sf}" ]]; then
        log_warn "Site '${domain}' not found — skipping"
        return 1
    fi

    local state sftp_user webroot site_type
    state=$(cat "${sf}")
    sftp_user=$(echo "${state}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sftp_user",""))')
    webroot=$(echo "${state}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["webroot"])')
    site_type=$(echo "${state}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["type"])')

    local timestamp
    timestamp=$(date -u +'%Y%m%d-%H%M%S')
    local backup_name="${domain}-${timestamp}"
    local backup_dir="${BACKUP_DIR}/${backup_name}"
    mkdir -p "${backup_dir}"

    log_info "Backing up site: ${domain}"

    # Skip if webroot doesn't exist
    if [[ ! -d "${webroot}" ]]; then
        log_warn "Webroot '${webroot}' does not exist — skipping files backup"
    else
        tar -czf "${backup_dir}/files.tar.gz" -C "$(dirname "${webroot}")" "$(basename "${webroot}")" 2>/dev/null || true
        log_info "Files backed up: ${backup_dir}/files.tar.gz"
    fi

    # Backup databases
    local databases
    databases=$(echo "${state}" | python3 -c '
import sys, json
dbs = json.load(sys.stdin).get("databases", [])
for db in dbs:
    print(json.dumps(db))
' 2>/dev/null || true)

    while IFS= read -r db_json; do
        [[ -z "${db_json}" ]] && continue
        local engine name
        engine=$(echo "${db_json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["engine"])')
        name=$(echo "${db_json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["name"])')

        case "${engine}" in
            mariadb)
                if command -v mariadb-dump &>/dev/null; then
                    mariadb-dump --single-transaction --quick "${name}" > "${backup_dir}/db-${engine}-${name}.sql" 2>/dev/null
                    gzip -f "${backup_dir}/db-${engine}-${name}.sql" 2>/dev/null || true
                    log_info "MariaDB dump: ${backup_dir}/db-${engine}-${name}.sql.gz"
                fi
                ;;
            postgresql)
                sudo -u postgres pg_dump --clean --if-exists "${name}" > "${backup_dir}/db-${engine}-${name}.sql" 2>/dev/null
                gzip -f "${backup_dir}/db-${engine}-${name}.sql" 2>/dev/null || true
                log_info "PostgreSQL dump: ${backup_dir}/db-${engine}-${name}.sql.gz"
                ;;
        esac
    done <<< "${databases}"

    # Create archive of the backup directory
    local archive_file="${BACKUP_DIR}/${backup_name}.tar.gz"
    tar -czf "${archive_file}" -C "${BACKUP_DIR}" "${backup_name}" 2>/dev/null
    chmod 600 "${archive_file}"
    rm -rf "${backup_dir}"

    # Write manifest
    python3 -c "
import json
manifest = {
    'domain': '${domain}',
    'timestamp': '${timestamp}',
    'archive': '${archive_file}',
    'size_bytes': $(stat -c%s "${archive_file}" 2>/dev/null || echo 0)
}
print(json.dumps(manifest))
" > "${archive_file}.manifest.json"
    chmod 600 "${archive_file}.manifest.json"

    log_info "Backup complete: ${archive_file} ($(du -h "${archive_file}" | cut -f1))"

    # Run post-hook if provided
    if [[ -n "${post_hook}" ]]; then
        log_info "Running post-hook: ${post_hook}"
        eval "${post_hook}" || log_warn "Post-hook exited with non-zero status"
    fi

    echo "${archive_file}"
    return 0
}

backup_all() {
    local post_hook="${1:-}"

    local sites
    sites=$(list_states)

    if [[ -z "${sites}" ]]; then
        log_info "No sites to back up"
        return 0
    fi

    local count=0
    for domain in ${sites}; do
        if backup_single_site "${domain}" "${post_hook}"; then
            count=$((count + 1))
        fi
    done

    log_info "Backed up ${count} site(s)"
}

list_backups() {
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        echo "No backups found"
        return 0
    fi

    echo "Backups:"
    find "${BACKUP_DIR}" -name '*.manifest.json' -type f | sort -r | while read -r manifest; do
        local domain timestamp size
        domain=$(python3 -c "import json; print(json.load(open('${manifest}')).get('domain',''))" 2>/dev/null || echo "")
        timestamp=$(python3 -c "import json; print(json.load(open('${manifest}')).get('timestamp',''))" 2>/dev/null || echo "")
        [[ -z "${domain}" ]] && continue
        local archive
        archive=$(echo "${manifest}" | sed 's/\.manifest\.json$//')
        size=$(du -h "${archive}" 2>/dev/null | cut -f1 || echo "?")
        echo "  ${domain}  ${timestamp}  ${size}"
    done
}

main() {
    require_root

    local domain=""
    local all="false"
    local post_hook=""
    local list="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)    domain="$2"; shift 2 ;;
            --all)       all="true"; shift ;;
            --post-hook) post_hook="$2"; shift 2 ;;
            --list)      list="true"; shift ;;
            -h|--help)   usage ;;
            *)           echo "Unknown option: $1"; usage ;;
        esac
    done

    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${BACKUP_DIR}"

    if [[ "${list}" == "true" ]]; then
        list_backups
        exit 0
    fi

    if [[ "${all}" == "true" ]]; then
        backup_all "${post_hook}"
        exit 0
    fi

    if [[ -z "${domain}" ]]; then
        exit_input_error "Specify --domain <domain> or --all"
    fi

    validate_domain "${domain}"

    local result
    if result=$(backup_single_site "${domain}" "${post_hook}"); then
        echo "${result}"
    else
        exit_internal "Backup failed for ${domain}"
    fi

    exit 0
}

main "$@"
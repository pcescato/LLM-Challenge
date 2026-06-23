#!/usr/bin/env bash
# scripts/backup.sh — backup webroot and databases for one or all sites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/db.sh
source "${SCRIPT_DIR}/lib/db.sh"

DOMAIN=""
ALL_SITES=false
PRUNE=false
POST_HOOK=""

usage() {
    cat >&2 <<EOF
Usage: $0 [--domain <domain> | --all] [--prune] [--post-hook <cmd>]
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --all)
                ALL_SITES=true
                shift
                ;;
            --prune)
                PRUNE=true
                shift
                ;;
            --post-hook)
                POST_HOOK="$2"
                shift 2
                ;;
            *)
                die_input "unknown option: $1"
                ;;
        esac
    done
}

dump_database() {
    local engine="$1"
    local db_name="$2"
    local target="$3"
    case "${engine}" in
        mariadb)
            require_command mysqldump
            mysqldump -u root --single-transaction --quick "${db_name}" > "${target}" || die_internal "mariadb dump failed"
            ;;
        postgres)
            require_command pg_dump
            sudo -u postgres pg_dump -d "${db_name}" -f "${target}" || die_internal "postgres dump failed"
            ;;
    esac
}

backup_domain() {
    local domain="$1"
    if ! state_exists "${domain}"; then
        die_notfound "site not found: ${domain}"
    fi

    local webroot timestamp archive staging
    webroot=$(state_get "${domain}" '.webroot')
    timestamp=$(date -u '+%Y-%m-%d_%H-%M-%S')
    archive="${BACKUP_DIR}/${domain}/${timestamp}.tar.gz"
    mkdir -p "$(dirname "${archive}")"

    staging=$(mktemp -d)
    mkdir -p "${staging}/webroot" "${staging}/databases"

    if [[ -d ${webroot} ]]; then
        rsync -a "${webroot}/" "${staging}/webroot/" 2>/dev/null || true
    fi

    local dbs count i
    dbs=$(state_get "${domain}" '.databases')
    count=$(jq 'length' <<< "${dbs}")
    if [[ ${count} -gt 0 ]]; then
        for i in $(seq 0 $((count - 1))); do
            local engine db_name
            engine=$(jq -r ".[${i}].engine" <<< "${dbs}")
            db_name=$(jq -r ".[${i}].name" <<< "${dbs}")
            dump_database "${engine}" "${db_name}" "${staging}/databases/${db_name}.sql"
        done
    fi

    tar -czf "${archive}" -C "${staging}" . || die_internal "failed to create archive ${archive}"
    rm -rf "${staging}"
    chmod 0600 "${archive}"
    chown root:root "${archive}"

    if [[ -n ${POST_HOOK} ]]; then
        VPSMGR_BACKUP_ARCHIVE="${archive}" bash -c "${POST_HOOK}" || true
    fi

    vpsmgr_log INFO "backup created for ${domain}: ${archive}"
    echo "${archive}"
}

prune_all() {
    if [[ -d ${BACKUP_DIR} ]]; then
        find "${BACKUP_DIR}" -type f -mtime "+${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
        vpsmgr_log INFO "pruned backups older than ${BACKUP_RETENTION_DAYS} days"
    fi
}

main() {
    require_root
    require_command jq
    parse_args "$@"

    if [[ ${PRUNE} == true && -z ${DOMAIN} && ${ALL_SITES} == false ]]; then
        prune_all
        echo "Pruned old backups."
        return 0
    fi

    if [[ ${ALL_SITES} == true ]]; then
        local found=false
        for sp in "${STATE_DIR}"/*.json; do
            [[ -f ${sp} ]] || continue
            found=true
            local domain
            domain=$(basename "${sp}" .json)
            backup_domain "${domain}"
        done
        if [[ ${found} == false ]]; then
            echo "No sites to backup."
        fi
    elif [[ -n ${DOMAIN} ]]; then
        backup_domain "${DOMAIN}"
    else
        usage
    fi

    if [[ ${PRUNE} == true ]]; then
        prune_all
    fi
}

main "$@"

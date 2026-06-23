#!/usr/bin/env bash
# scripts/db-create.sh — create a database for an existing site.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/db.sh
source "${SCRIPT_DIR}/lib/db.sh"

usage() {
    echo "Usage: $0 <domain> [mariadb|postgres]" >&2
    exit 1
}

main() {
    require_root
    require_command jq
    [[ $# -ge 1 ]] || usage
    local domain="$1"
    local engine="${2:-${DEFAULT_DB_ENGINE}}"
    validate_domain "${domain}"
    db_validate_engine "${engine}"

    if ! state_exists "${domain}"; then
        die_notfound "site not found: ${domain}"
    fi

    local existing
    existing=$(state_get "${domain}" ".databases[]? | select(.engine==\"${engine}\") | .name")
    if [[ -n ${existing} && ${existing} != "null" ]]; then
        die_conflict "site ${domain} already has a ${engine} database (${existing})"
    fi

    local db_user db_pass db_name
    db_create "${engine}" "${domain}" db_user db_pass
    db_name=$(domain_to_db_name "${domain}" "${engine}")
    state_add_database "${domain}" "${engine}" "${db_name}" "${db_user}"

    vpsmgr_log INFO "created ${engine} database ${db_name} for ${domain}"
    echo "Database ${engine} created for ${domain}."
    echo "  Database: ${db_name}"
    echo "  DB user: ${db_user}"
    print_credentials "database_password" "${db_pass}"
}

main "$@"

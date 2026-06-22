#!/usr/bin/env bash
# db-create.sh — Create a database for an existing site
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/db.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0") --domain <domain> [--engine <mariadb|postgresql>] [--db-name <name>]

Creates a new database for an existing site. Credentials are printed once
to stdout wrapped in <<<CREDENTIALS>>> markers.

Options:
  --domain DOMAIN     Domain name of the site (required)
  --engine ENGINE     Database engine: mariadb or postgresql (default: mariadb)
  --db-name NAME      Database name (default: derived from domain)
  --help              Show this help
USAGE
    exit 1
}

update_state_databases() {
    local domain="$1"
    local engine="$2"
    local db_name="$3"

    local sf
    sf=$(state_file "${domain}")

    local state
    state=$(python3 -c "
import json, sys
with open('${sf}') as f:
    data = json.load(f)
dbs = data.get('databases', [])
dbs.append({'engine': '${engine}', 'name': '${db_name}'})
data['databases'] = dbs
print(json.dumps(data, indent=2))
")

    write_state "${domain}" "${state}"
}

main() {
    require_root

    local domain=""
    local engine="mariadb"
    local db_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)  domain="$2"; shift 2 ;;
            --engine)  engine="$2"; shift 2 ;;
            --db-name) db_name="$2"; shift 2 ;;
            -h|--help) usage ;;
            *)         echo "Unknown option: $1"; usage ;;
        esac
    done

    if [[ -z "${domain}" ]]; then
        exit_input_error "--domain is required"
    fi

    validate_domain "${domain}"

    case "${engine}" in
        mariadb|postgresql) ;;
        *) exit_input_error "Engine must be mariadb or postgresql" ;;
    esac

    if [[ ! -f "$(state_file "${domain}")" ]]; then
        exit_not_found "Site '${domain}' not found. Create the site first with site-create.sh"
    fi

    local sitename
    sitename=$(domain_to_sftp_user "${domain}")

    if [[ -z "${db_name}" ]]; then
        local shortname
        shortname=$(domain_to_shortname "${domain}")
        db_name="${sitename:0:16}"
    fi

    # Validate db_name
    if [[ ! "${db_name}" =~ ^[a-z][a-z0-9_]{0,63}$ ]]; then
        exit_input_error "Invalid database name: ${db_name}"
    fi

    # Ensure database engine is installed
    case "${engine}" in
        mariadb)
            mariadb_install
            # Check for duplicate DB name
            if mariadb_database_exists "${db_name}"; then
                exit_conflict "MariaDB database '${db_name}' already exists"
            fi
            mariadb_create_database "${db_name}" "${sitename}"
            ;;
        postgresql)
            postgresql_install
            if postgresql_database_exists "${db_name}"; then
                exit_conflict "PostgreSQL database '${db_name}' already exists"
            fi
            postgresql_create_database "${db_name}" "${sitename}"
            ;;
    esac

    update_state_databases "${domain}" "${engine}" "${db_name}"

    log_info "Database '${db_name}' (${engine}) created for site '${domain}'"

    exit 0
}

main "$@"
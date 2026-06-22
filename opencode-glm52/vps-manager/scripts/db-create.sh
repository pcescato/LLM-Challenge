#!/usr/bin/env bash
# scripts/db-create.sh — attach a new database to an existing site.
# Credentials printed once to stdout wrapped in <<<CREDENTIALS>>> markers (D1).
# State updated to list the new database (no password fields).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
for lib in db; do
    source "${VPSMGR_LIB_DIR}/${lib}.sh"
done

require_root

usage() {
    cat <<USAGE
Usage: $0 --domain <fqdn> --engine <engine> [--name <name>]
  Attaches a new database to an existing site.
  engine: mariadb | postgresql
  name: optional; auto-generated if omitted.
  Credentials are printed once to stdout (<<<CREDENTIALS>>> markers), then forgotten.
USAGE
}

DOMAIN="" ENGINE="" DB_NAME_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --engine) ENGINE="$2"; shift 2 ;;
        --name) DB_NAME_OVERRIDE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "${E_USAGE}" "unknown arg: $1" ;;
    esac
done

[[ -n "${DOMAIN}" && -n "${ENGINE}" ]] || { usage; die "${E_USAGE}" "--domain and --engine required"; }
validate_domain "${DOMAIN}" || die "${E_USAGE}" "invalid domain: ${DOMAIN}"
db_engine_available "${ENGINE}" || die "${E_USAGE}" "unsupported engine: ${ENGINE}"

if ! site_exists "${DOMAIN}"; then
    die "${E_NOTFOUND}" "site not found: ${DOMAIN}"
fi

STATE="$(state_read "${DOMAIN}")"

DB_NAME="${DB_NAME_OVERRIDE:-$(gen_db_name "${DOMAIN}")}"
DB_USER="$(gen_db_user "${DOMAIN}")"

# Check if a db with same name+engine already attached to this site.
EXISTING="$(json_get "${STATE}" databases)"
if [[ -n "${EXISTING}" && "${EXISTING}" != "null" && "${EXISTING}" != "[]" ]]; then
    if python3 -c "
import json, sys
for e in json.loads('''${EXISTING}'''):
    if e['engine']=='${ENGINE}' and e['name']=='${DB_NAME}':
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        die "${E_CONFLICT}" "database already attached: ${ENGINE}/${DB_NAME}"
    fi
fi

DB_PASS="$(db_create "${ENGINE}" "${DB_NAME}" "${DB_USER}")"

# Update state to append the new database entry (no password).
NEW_ENTRY="{\"engine\": \"${ENGINE}\", \"name\": \"${DB_NAME}\"}"
STATE_NEW="$(python3 -c "
import json, sys
d = json.loads('''${STATE}''')
d.setdefault('databases', []).append(json.loads('''${NEW_ENTRY}'''))
print(json.dumps(d, indent=2))
")"
state_write "${DOMAIN}" "${STATE_NEW}"

# Print credentials once.
{
    echo "db_engine=${ENGINE}"
    echo "db_name=${DB_NAME}"
    echo "db_user=${DB_USER}"
    echo "db_password=${DB_PASS}"
} | print_credentials

unset DB_PASS

log_info "database attached: ${DOMAIN} ${ENGINE}/${DB_NAME}"
echo "db-create: OK ${DOMAIN} ${ENGINE}/${DB_NAME}"
exit 0

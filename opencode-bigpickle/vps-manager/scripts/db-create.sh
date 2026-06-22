#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/db.sh
source "$LIB_DIR/db.sh"

ensure_root

# --- Parse args ---
DOMAIN=""
DB_ENGINE="mariadb"
DB_PREFIX=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)  DOMAIN="$2"; shift 2 ;;
        --engine)  DB_ENGINE="$2"; shift 2 ;;
        --prefix)  DB_PREFIX="$2"; shift 2 ;;
        *) echo "Usage: $0 --domain <domain> [--engine mariadb] [--prefix <prefix>]" >&2; exit 1 ;;
    esac
done

ensure_domain_arg "$DOMAIN"
STATE=$(load_state "$DOMAIN")

SFTP_USER=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['sftp_user'])")

# --- Generate DB name ---
[[ -z "$DB_PREFIX" ]] && DB_PREFIX="db_"
DB_NAME=$(db_sanitize_name "$DB_PREFIX" "$DOMAIN")
DB_USER="${SFTP_USER}"

# --- Create DB ---
DB_PASS=$(db_create "$DB_NAME" "$DB_USER")

# --- Update state ---
UPDATED=$(echo "$STATE" | python3 -c "
import sys, json
s = json.load(sys.stdin)
dbs = s.get('databases', [])
dbs.append({'engine': '$DB_ENGINE', 'name': '$DB_NAME'})
s['databases'] = dbs
print(json.dumps(s))
")
save_state "$DOMAIN" "$UPDATED"

echo ""
echo "<<<CREDENTIALS>>>"
echo "Database: ${DB_NAME}"
echo "User:     ${DB_USER}"
echo "Password: ${DB_PASS}"
echo "Engine:   ${DB_ENGINE}"
echo "<<<CREDENTIALS>>>"

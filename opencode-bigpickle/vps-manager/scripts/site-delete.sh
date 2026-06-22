#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/caddy.sh
source "$LIB_DIR/caddy.sh"
# shellcheck source=scripts/lib/php.sh
source "$LIB_DIR/php.sh"
# shellcheck source=scripts/lib/sftp.sh
source "$LIB_DIR/sftp.sh"
# shellcheck source=scripts/lib/db.sh
source "$LIB_DIR/db.sh"

ensure_root

# --- Parse args ---
DOMAIN=""
SKIP_BACKUP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="$2"; shift 2 ;;
        --skip-backup) SKIP_BACKUP=true ;;
        *) echo "Usage: $0 --domain <domain> [--skip-backup]" >&2; exit 1 ;;
    esac
done

ensure_domain_arg "$DOMAIN"
STATE=$(load_state "$DOMAIN")

# --- Extract state ---
SFTP_USER=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['sftp_user'])")
PHP_VERSION=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('php_version') or '')")
WEBROOT=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['webroot'])")
SITE_TYPE=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['type'])")
DB_NAMES=$(echo "$STATE" | python3 -c "
import sys,json
s=json.load(sys.stdin)
dbs = s.get('databases', [])
for db in dbs:
    print(db.get('name', ''))
")

# --- Backup unless skipped ---
if ! $SKIP_BACKUP; then
    echo "Creating backup before deletion..."
    "$SCRIPT_DIR/backup.sh" --domain "$DOMAIN"
elif $SKIP_BACKUP; then
    echo "WARNING: --skip-backup set. Type DELETE ${DOMAIN} to confirm:"
    read -r confirm
    if [[ "$confirm" != "DELETE ${DOMAIN}" ]]; then
        echo "Confirmation failed. Aborting." >&2
        exit 1
    fi
fi

# --- Remove PHP pool ---
if [[ -n "$PHP_VERSION" ]]; then
    php_remove_pool "$DOMAIN" "$PHP_VERSION"
fi

# --- Remove Caddy block ---
caddy_remove_site "$DOMAIN"

# --- Remove SFTP user ---
sftp_remove_user "$DOMAIN"

# --- Drop databases ---
if [[ -n "$DB_NAMES" ]]; then
    while IFS= read -r db_name; do
        [[ -z "$db_name" ]] && continue
        db_user="${SFTP_USER}_db"
        db_drop "$db_name" "$db_user"
    done <<< "$DB_NAMES"
fi

# --- Remove webroot ---
rm -rf "$WEBROOT"

# --- Remove state ---
delete_state "$DOMAIN"

echo "Site ${DOMAIN} deleted."

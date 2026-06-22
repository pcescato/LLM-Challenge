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
BACKUP_ALL=false
POST_HOOK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)    DOMAIN="$2"; shift 2 ;;
        --all)       BACKUP_ALL=true ;;
        --post-hook) POST_HOOK="$2"; shift 2 ;;
        *) echo "Usage: $0 --domain <domain> | --all [--post-hook <cmd>]" >&2; exit 1 ;;
    esac
done

if $BACKUP_ALL; then
    for state_file in "$STATE_DIR"/*.json; do
        [[ -f "$state_file" ]] || continue
        d="$(basename "$state_file" .json)"
        "$0" --domain "$d" --post-hook "$POST_HOOK"
    done
    exit 0
fi

ensure_domain_arg "$DOMAIN"
STATE=$(load_state "$DOMAIN")

WEBROOT=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['webroot'])")
SFTP_USER=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['sftp_user'])")
DB_NAMES=$(echo "$STATE" | python3 -c "
import sys,json
s=json.load(sys.stdin)
for db in s.get('databases', []):
    print(db.get('name',''))
")

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_PATH="$BACKUP_DIR/${DOMAIN}_${TIMESTAMP}"
mkdir -p "$BACKUP_PATH"

# --- Backup webroot ---
tar czf "$BACKUP_PATH/webroot.tar.gz" -C "$(dirname "$WEBROOT")" "$(basename "$WEBROOT")"
chmod 600 "$BACKUP_PATH/webroot.tar.gz"

# --- Backup databases ---
if [[ -n "$DB_NAMES" ]]; then
    while IFS= read -r db_name; do
        [[ -z "$db_name" ]] && continue
        db_dump "$db_name" "$BACKUP_PATH/${db_name}.sql"
        gzip "$BACKUP_PATH/${db_name}.sql"
        chmod 600 "$BACKUP_PATH/${db_name}.sql.gz"
    done <<< "$DB_NAMES"
fi

# --- Save metadata ---
echo "$STATE" > "$BACKUP_PATH/state.json"
chmod 600 "$BACKUP_PATH/state.json"

echo "Backup created: $BACKUP_PATH"

# --- Post-hook ---
if [[ -n "$POST_HOOK" ]]; then
    eval "$POST_HOOK"
fi

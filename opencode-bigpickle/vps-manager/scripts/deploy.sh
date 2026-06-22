#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/wp.sh
source "$LIB_DIR/wp.sh"

ensure_root

# --- Parse args ---
DOMAIN=""
SOURCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        *) echo "Usage: $0 --domain <domain> [--source <path>]" >&2; exit 1 ;;
    esac
done

ensure_domain_arg "$DOMAIN"
STATE=$(load_state "$DOMAIN")

SITE_TYPE=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['type'])")
WEBROOT=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['webroot'])")
SFTP_USER=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['sftp_user'])")

case "$SITE_TYPE" in
    static)
        if [[ -n "$SOURCE" ]]; then
            rsync -a --delete "$SOURCE/" "$WEBROOT/"
            chown -R "$SFTP_USER:$SFTP_USER" "$WEBROOT"
            info "Static site deployed to ${WEBROOT}"
        fi
        ;;
    php)
        if [[ -n "$SOURCE" ]]; then
            rsync -a --delete "$SOURCE/" "$WEBROOT/"
            chown -R "$SFTP_USER:$SFTP_USER" "$WEBROOT"
            info "PHP site deployed to ${WEBROOT}"
        fi
        ;;
    wordpress)
        DB_NAME=$(echo "$STATE" | python3 -c "
import sys,json
s=json.load(sys.stdin)
dbs=s.get('databases',[])
print(dbs[0]['name'] if dbs else '')
")
        DB_USER="${SFTP_USER}"
        if [[ -z "$DB_NAME" ]]; then
            echo "No database found for $DOMAIN. Run db-create.sh first." >&2
            exit 4
        fi

        if [[ -n "$SOURCE" ]]; then
            # Deploy from source (e.g. uploaded files)
            rsync -a --delete "$SOURCE/" "$WEBROOT/"
            chown -R "$SFTP_USER:$SFTP_USER" "$WEBROOT"
            info "WordPress files deployed to ${WEBROOT}"
        else
            # Fresh WP install
            wp_download "$WEBROOT"
            # wp-config will be written on first db-create+deploy
            # If wp-config.php doesn't exist, prompt for DB creds (interactive only)
            if [[ ! -f "${WEBROOT}/wp-config.php" ]] && [[ -t 0 ]]; then
                echo "wp-config.php not found. Please enter database credentials."
                read -r -p "DB Name: " wp_db_name
                read -r -p "DB User: " wp_db_user
                read -r -s -p "DB Password: " wp_db_pass
                echo
                wp_configure "$WEBROOT" "$wp_db_name" "$wp_db_user" "$wp_db_pass" "$DOMAIN"
            fi
        fi
        ;;
esac

echo "Deploy complete for ${DOMAIN}"

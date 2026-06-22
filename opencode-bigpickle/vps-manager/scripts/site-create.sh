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
# shellcheck source=scripts/lib/wp.sh
source "$LIB_DIR/wp.sh"

ensure_root

# --- Parse args ---
DOMAIN=""
SITE_TYPE="static"
PHP_VERSION=""
PHP_ENABLE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)     DOMAIN="$2"; shift 2 ;;
        --type)       SITE_TYPE="$2"; shift 2 ;;
        --php-version) PHP_VERSION="$2"; shift 2 ;;
        --proxy)      PROXY_TARGET="$2"; shift 2 ;;
        *) echo "Usage: $0 --domain <domain> [--type static|php|wordpress] [--php-version <ver>] [--proxy <url>]" >&2; exit 1 ;;
    esac
done

[[ -n "$DOMAIN" ]] || { echo "FATAL: --domain is required" >&2; exit 1; }

# Validate site type
case "$SITE_TYPE" in
    static|php|wordpress) ;;
    *) echo "FATAL: Invalid type '$SITE_TYPE'. Must be static, php, or wordpress" >&2; exit 1 ;;
esac

# --- Check conflict ---
if [[ -f "$(site_state_path "$DOMAIN")" ]]; then
    echo "Site $DOMAIN already exists" >&2
    exit 3
fi

# --- Resolve paths ---
SFTP_USER="$(site_user_for "$DOMAIN")"
WEBROOT="$(site_webroot_for "$DOMAIN")"

# --- Determine PHP version ---
if [[ "$SITE_TYPE" == "php" || "$SITE_TYPE" == "wordpress" ]]; then
    PHP_ENABLE=true
    if [[ -z "$PHP_VERSION" ]]; then
        PHP_VERSION="${php_default_version:-}"
    fi
    if [[ -z "$PHP_VERSION" ]]; then
        PHP_VERSION="$(php_resolve_version)"
    fi
fi

# --- Create SFTP user (and webroot) ---
SFTP_PASS="$(sftp_create_user "$DOMAIN" "$WEBROOT")"

# --- PHP-FPM pool ---
PHP_POOL=""
if $PHP_ENABLE && [[ -n "$PHP_VERSION" ]]; then
    php_add_pool "$DOMAIN" "$PHP_VERSION" "$SFTP_USER"
    PHP_POOL="/etc/php/${PHP_VERSION}/fpm/pool.d/${DOMAIN}.conf"
fi

# --- Caddy block ---
CADDY_BLOCK_PATH="$CADDY_SITES_DIR/${DOMAIN}.caddy"
CADDY_PHP_ENABLE=false
CADDY_FPM_ADDR=""
if $PHP_ENABLE && [[ -n "$PHP_VERSION" ]]; then
    CADDY_PHP_ENABLE=true
    CADDY_FPM_ADDR="$(php_socket_path "$PHP_VERSION")"
fi
caddy_add_site "$DOMAIN" "$WEBROOT" "$CADDY_PHP_ENABLE" "$CADDY_FPM_ADDR"

# --- Proxy override ---
if [[ -n "${PROXY_TARGET:-}" ]]; then
    cat > "$CADDY_BLOCK_PATH" <<CADDY
${DOMAIN} {
    reverse_proxy ${PROXY_TARGET}
}
CADDY
    chmod 644 "$CADDY_BLOCK_PATH"
    systemctl reload caddy
fi

# --- WordPress install ---
WP_ADMIN_CREDS=""
if [[ "$SITE_TYPE" == "wordpress" ]]; then
    # WordPress requires a database — db-create.sh must be run separately if non-interactive
    info "WordPress type selected. Run db-create.sh then deploy.sh for full setup."
    info "Or re-run with interactive TTY for wp admin setup."
fi

# --- Save state ---
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
STATE=$(cat <<JSON
{
  "domain": "$DOMAIN",
  "type": "$SITE_TYPE",
  "sftp_user": "$SFTP_USER",
  "webroot": "$WEBROOT",
  "php_version": "${PHP_VERSION:-null}",
  "php_pool": "${PHP_POOL:-null}",
  "caddy_block": "$CADDY_BLOCK_PATH",
  "databases": [],
  "proxy_target": ${PROXY_TARGET:-null},
  "created_at": "$CREATED_AT"
}
JSON
)
save_state "$DOMAIN" "$STATE"

# --- Output ---
echo ""
echo "<<<CREDENTIALS>>>"
echo "SFTP User: ${SFTP_USER}"
echo "SFTP Password: ${SFTP_PASS}"
echo "Webroot: ${WEBROOT}"
echo "<<<CREDENTIALS>>>"

# --- Cleanup memory ---
SFTP_PASS=""

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"

ensure_root

# --- Parse args ---
COMPONENT="${1:-all}"
ACTION="${2:-status}"

SERVICES=()
case "$COMPONENT" in
    all)
        SERVICES=(caddy mariadb "php*-fpm" sshd)
        ;;
    caddy)
        SERVICES=(caddy)
        ;;
    mariadb|mysql|database)
        SERVICES=(mariadb)
        ;;
    php|php-fpm)
        SERVICES=("php*-fpm")
        ;;
    ssh|sshd)
        SERVICES=(sshd)
        ;;
    *)
        echo "Usage: $0 [component] [action]" >&2
        echo "Components: all, caddy, mariadb, php, ssh" >&2
        echo "Actions: status, start, stop, restart, reload, enable, disable" >&2
        exit 1
        ;;
esac

case "$ACTION" in
    status)
        for svc in "${SERVICES[@]}"; do
            for unit in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E "^${svc}\.service$|^${svc}$" || true); do
                systemctl status "$unit" --no-pager 2>&1 || true
            done
        done
        ;;
    start|stop|restart|reload|enable|disable)
        for svc in "${SERVICES[@]}"; do
            for unit in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E "^${svc}\.service$|^${svc}$" || true); do
                systemctl "$ACTION" "$unit" --no-pager 2>&1 || true
            done
        done
        echo "Action '${ACTION}' completed for ${COMPONENT}"
        ;;
    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac

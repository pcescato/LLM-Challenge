#!/bin/bash
# Manage system services (Caddy, PHP-FPM, MariaDB, PostgreSQL)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root

# Parse arguments
declare -A args
args[component]=""
args[action]=""

for arg in "$@"; do
    if [[ "$arg" =~ ^([a-z_]+)=(.+)$ ]]; then
        args["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    else
        if [[ -z "${args[component]}" ]]; then
            args[component]="$arg"
        elif [[ -z "${args[action]}" ]]; then
            args[action]="$arg"
        fi
    fi
done

component="${args[component]}"
action="${args[action]}"

if [[ -z "$component" ]]; then
    log_error "component is required (caddy, php, mariadb, postgresql, all)"
    exit $E_USAGE
fi

if [[ -z "$action" ]]; then
    log_error "action is required (start, stop, restart, reload, status)"
    exit $E_USAGE
fi

# Validate action
case "$action" in
    start|stop|restart|reload|status)
        : # valid
        ;;
    *)
        log_error "Invalid action: $action"
        exit $E_USAGE
        ;;
esac

# Map component names to systemd services
declare -A services
services[caddy]="caddy"
services[php]=""  # Special handling for PHP (multiple versions)
services[mariadb]="mariadb"
services[mysql]="mariadb"  # Alias
services[postgres]="postgresql"
services[postgresql]="postgresql"

manage_service() {
    local svc="$1"
    local act="$2"

    if [[ -z "$svc" ]]; then
        return 0
    fi

    log_info "Performing $act on $svc..."

    case "$act" in
        start)
            systemctl start "$svc" 2>&1 | redact_credentials || {
                log_error "Failed to start $svc"
                return $E_INTERNAL
            }
            ;;
        stop)
            systemctl stop "$svc" 2>&1 | redact_credentials || {
                log_error "Failed to stop $svc"
                return $E_INTERNAL
            }
            ;;
        restart)
            systemctl restart "$svc" 2>&1 | redact_credentials || {
                log_error "Failed to restart $svc"
                return $E_INTERNAL
            }
            ;;
        reload)
            systemctl reload "$svc" 2>&1 | redact_credentials || {
                log_error "Failed to reload $svc"
                return $E_INTERNAL
            }
            ;;
        status)
            systemctl status "$svc" 2>&1 | redact_credentials || {
                log_warn "$svc is not running"
                return 0
            }
            ;;
    esac

    log_info "$svc $act completed"
}

show_status() {
    local svc="$1"

    if [[ -z "$svc" ]]; then
        return 0
    fi

    local status="unknown"
    if systemctl is-active --quiet "$svc"; then
        status="active"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        status="inactive (enabled)"
    else
        status="inactive (disabled)"
    fi

    printf "%-20s %s\n" "$svc:" "$status"
}

# Handle special cases and all components
case "$component" in
    all)
        # Manage all services
        for svc in caddy php mariadb postgresql; do
            manage_service "${services[$svc]}" "$action" || true
        done
        ;;
    php)
        # PHP requires special handling (multiple versions)
        if [[ "$action" == "status" ]]; then
            # List all installed PHP versions
            dpkg -l | grep -E "^ii.*php[0-9]\.[0-9]-fpm" | \
            sed -E 's/.*php([0-9]\.[0-9]).*/php\1-fpm/' | \
            while read -r svc; do
                show_status "$svc"
            done
        else
            # Apply action to all PHP versions
            dpkg -l | grep -E "^ii.*php[0-9]\.[0-9]-fpm" | \
            sed -E 's/.*php([0-9]\.[0-9]).*/php\1-fpm/' | \
            while read -r svc; do
                manage_service "$svc" "$action" || true
            done
        fi
        ;;
    *)
        # Single service management
        local svc="${services[$component]:-$component}"

        if [[ "$action" == "status" ]]; then
            show_status "$svc"
        else
            manage_service "$svc" "$action" || exit $?
        fi
        ;;
esac

log_info "Service operation completed"

exit $E_OK

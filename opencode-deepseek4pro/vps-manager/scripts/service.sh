#!/usr/bin/env bash
# service.sh — Manage services (caddy, php-fpm, mariadb, postgresql)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/caddy.sh"
source "${SCRIPT_DIR}/lib/php.sh"
source "${SCRIPT_DIR}/lib/db.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0") <component> <action>
       $(basename "$0") all status

Manage VPS services.

Components:  caddy | php-fpm | mariadb | postgresql | all
Actions:     start | stop | restart | reload | status

When component is "all" and action is "status", prints a JSON status snapshot.

Examples:
  $(basename "$0") caddy reload
  $(basename "$0") php-fpm restart
  $(basename "$0") all status
USAGE
    exit 1
}

service_action() {
    local svc="$1"
    local action="$2"

    case "${action}" in
        start|stop|restart|status)
            systemctl "${action}" "${svc}" 2>/dev/null || log_warn "Failed to ${action} ${svc}"
            ;;
        reload)
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                systemctl reload "${svc}" 2>/dev/null || log_warn "Failed to reload ${svc}, trying restart"
                systemctl restart "${svc}" 2>/dev/null || true
            else
                systemctl restart "${svc}" 2>/dev/null || log_warn "Failed to start ${svc}"
            fi
            ;;
        *) exit_input_error "Unknown action: ${action}" ;;
    esac
}

resolve_php_services() {
    local svcs=""
    for svc in $(systemctl list-units --type=service --all 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}'); do
        svcs="${svcs} ${svc}"
    done
    echo "${svcs}"
}

all_status() {
    local caddy_status mariadb_status pg_status

    caddy_status=$(caddy_status 2>/dev/null || echo "unknown")
    mariadb_status=$(mariadb_status 2>/dev/null || echo "unknown")
    pg_status=$(postgresql_status 2>/dev/null || echo "unknown")

    # PHP-FPM versions
    local php_versions=()
    for php_svc in $(resolve_php_services); do
        local ver
        ver=$(echo "${php_svc}" | grep -oP '\d+\.\d+')
        local st
        st=$(systemctl is-active "${php_svc}" 2>/dev/null || echo "inactive")
        php_versions+=("{\"version\": \"${ver}\", \"status\": \"${st}\"}")
    done
    local php_json
    php_json=$(IFS=,; echo "[${php_versions[*]}]")

    cat <<JSON
{
  "services": {
    "caddy": {"status": "${caddy_status}"},
    "php_fpm": ${php_json},
    "mariadb": {"status": "${mariadb_status}"},
    "postgresql": {"status": "${pg_status}"}
  }
}
JSON
}

main() {
    require_root

    local component="${1:-}"
    local action="${2:-}"

    if [[ -z "${component}" || -z "${action}" ]]; then
        usage
    fi

    # Special: all status
    if [[ "${component}" == "all" && "${action}" == "status" ]]; then
        all_status
        exit 0
    fi

    # Validate action
    case "${action}" in
        start|stop|restart|reload|status) ;;
        *) exit_input_error "Invalid action: ${action} (use start|stop|restart|reload|status)" ;;
    esac

    case "${component}" in
        caddy)
            if [[ "${action}" == "reload" ]]; then
                caddy_reload
            else
                service_action "caddy" "${action}"
            fi
            ;;
        php-fpm)
            local handled=false
            for php_svc in $(resolve_php_services); do
                service_action "${php_svc}" "${action}"
                handled=true
            done
            if [[ "${handled}" == "false" ]]; then
                exit_input_error "No PHP-FPM services found"
            fi
            ;;
        mariadb)
            service_action "mariadb" "${action}"
            ;;
        postgresql)
            local found=false
            for pg_svc in $(systemctl list-units --type=service --all 'postgresql*' --no-legend 2>/dev/null | awk '{print $1}'); do
                service_action "${pg_svc}" "${action}"
                found=true
            done
            if [[ "${found}" == "false" ]]; then
                exit_input_error "No PostgreSQL services found"
            fi
            ;;
        all)
            for svc in caddy mariadb $(resolve_php_services); do
                service_action "${svc}" "${action}"
            done
            for pg_svc in $(systemctl list-units --type=service --all 'postgresql*' --no-legend 2>/dev/null | awk '{print $1}'); do
                service_action "${pg_svc}" "${action}"
            done
            ;;
        *)
            exit_input_error "Unknown component: ${component} (use caddy|php-fpm|mariadb|postgresql|all)"
            ;;
    esac

    exit 0
}

main "$@"
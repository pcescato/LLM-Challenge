#!/usr/bin/env bash
# scripts/service.sh — start/stop/restart/reload/status for stack components.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/php.sh
source "${SCRIPT_DIR}/lib/php.sh"

usage() {
    cat >&2 <<EOF
Usage: $0 <component> <action>
  component: caddy | php-current | php-fallback | mariadb | postgresql | valkey | all
  action:    start | stop | restart | reload | status
EOF
    exit 1
}

resolve_service() {
    local component="$1"
    case "${component}" in
        caddy)
            echo "caddy"
            ;;
        php-current)
            php_resolve_version current >/dev/null
            php_service_name "$(php_resolve_version current)"
            ;;
        php-fallback)
            php_resolve_version fallback >/dev/null
            php_service_name "$(php_resolve_version fallback)"
            ;;
        mariadb)
            echo "mariadb"
            ;;
        postgresql)
            echo "postgresql"
            ;;
        valkey)
            echo "valkey"
            ;;
        *)
            die_input "unknown component: ${component}"
            ;;
    esac
}

component_status_line() {
    local component="$1"
    local svc
    svc=$(resolve_service "${component}") 2>/dev/null || { echo "${component}: unknown"; return; }
    local active="unknown"
    active=$(systemctl is-active "${svc}" 2>/dev/null || true)
    echo "${component}: ${active}"
}

all_status() {
    for comp in caddy php-current php-fallback mariadb postgresql valkey; do
        component_status_line "${comp}"
    done
}

all_action() {
    local action="$1"
    local status=0
    for comp in mariadb postgresql valkey php-current php-fallback caddy; do
        local svc
        svc=$(resolve_service "${comp}")
        echo "==> ${comp} (${action})"
        if ! systemctl "${action}" "${svc}"; then
            status=1
        fi
    done
    exit "${status}"
}

main() {
    require_root
    require_command systemctl
    [[ $# -ge 1 ]] || usage
    local component="$1"
    local action="${2:-status}"

    case "${action}" in
        start|stop|restart|reload|status) ;;
        *) die_input "invalid action: ${action}" ;;
    esac

    if [[ ${component} == "all" ]]; then
        if [[ ${action} == "status" ]]; then
            all_status
        else
            all_action "${action}"
        fi
    else
        local svc
        svc=$(resolve_service "${component}")
        if [[ ${action} == "status" ]]; then
            component_status_line "${component}"
        else
            systemctl "${action}" "${svc}" || die_internal "failed to ${action} ${component}"
        fi
    fi
}

main "$@"

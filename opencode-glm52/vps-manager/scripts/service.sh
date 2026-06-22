#!/usr/bin/env bash
# scripts/service.sh — control host services managed by vps-manager.
# Usage: $0 <component> <action>
#   component: caddy | php | mariadb | postgresql | all
#   action:    start | stop | restart | reload | status | enable | disable
# `all` applies the action across all known components.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
for lib in php; do
    source "${VPSMGR_LIB_DIR}/${lib}.sh"
done

require_root

usage() {
    cat <<USAGE
Usage: $0 <component> <action>
  component: caddy | php | mariadb | postgresql | all
  action:    start | stop | restart | reload | status | enable | disable
  Notes:
    - 'php' resolves the currently active PHP-FPM version (first installed).
    - 'status' prints a one-line summary per service (active/inactive/failed).
USAGE
}

# Map a logical component to its systemd unit name(s).
component_units() {
    local comp="$1"
    case "${comp}" in
        caddy) echo "caddy" ;;
        mariadb)
            systemctl list-unit-files 'mariadb.service' 2>/dev/null | grep -q mariadb && echo "mariadb" || echo "mysql"
            ;;
        postgresql) echo "postgresql" ;;
        php)
            # Resolve any installed php*-fpm.
            local unit
            unit="$(systemctl list-unit-files 'php*-fpm.service' 2>/dev/null \
                    | awk '/php.*-fpm\.service/ {print $1; exit}')"
            [[ -n "${unit}" ]] && echo "${unit}" || echo "php-fpm"
            ;;
        all)
            echo "caddy"
            systemctl list-unit-files 'mariadb.service' 2>/dev/null | grep -q mariadb && echo "mariadb" || echo "mysql"
            echo "postgresql"
            systemctl list-unit-files 'php*-fpm.service' 2>/dev/null \
                | awk '/php.*-fpm\.service/ {print $1}'
            ;;
        *) return 1 ;;
    esac
}

# Apply an action to a single unit. status is treated specially.
apply_action() {
    local unit="$1" action="$2"
    case "${action}" in
        start|stop|restart|reload|enable|disable)
            if ! systemctl "${action}" "${unit}" 2>/dev/null; then
                # reload may fail if not running; fall back to restart.
                if [[ "${action}" == "reload" ]]; then
                    systemctl restart "${unit}" 2>/dev/null || true
                else
                    log_warn "systemctl ${action} ${unit} failed"
                    return 1
                fi
            fi
            log_info "service ${action} ${unit}"
            ;;
        status)
            local st
            st="$(systemctl is-active "${unit}" 2>/dev/null || true)"
            printf '%-24s %s\n' "${unit}" "${st:-unknown}"
            ;;
        *) return 1 ;;
    esac
}

if [[ $# -lt 2 ]]; then
    { usage; die "${E_USAGE}" "component and action required"; }
fi
COMPONENT="$1"; ACTION="$2"
shift 2

case "${ACTION}" in
    start|stop|restart|reload|status|enable|disable) ;;
    *) die "${E_USAGE}" "invalid action: ${ACTION}" ;;
esac

if [[ "${COMPONENT}" != "all" ]] && [[ "${COMPONENT}" != "caddy" ]] \
   && [[ "${COMPONENT}" != "php" ]] && [[ "${COMPONENT}" != "mariadb" ]] \
   && [[ "${COMPONENT}" != "postgresql" ]]; then
    die "${E_USAGE}" "invalid component: ${COMPONENT}"
fi

mapfile -t UNITS < <(component_units "${COMPONENT}")
if [[ ${#UNITS[@]} -eq 0 ]]; then
    die "${E_NOTFOUND}" "no systemd units found for component: ${COMPONENT}"
fi

rc=0
for u in "${UNITS[@]}"; do
    [[ -z "${u}" ]] && continue
    if ! apply_action "${u}" "${ACTION}"; then
        rc=5
    fi
done

if [[ ${rc} -ne 0 ]]; then
    exit "${E_INTERNAL}"
fi
echo "service: OK ${COMPONENT} ${ACTION}"
exit 0

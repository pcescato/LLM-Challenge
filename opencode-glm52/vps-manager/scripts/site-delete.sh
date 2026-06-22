#!/usr/bin/env bash
# scripts/site-delete.sh — delete a site. Backups run automatically before
# deletion unless --skip-backup is given WITH the explicit confirmation
# "DELETE <domain>". Removes user, webroot, Caddy block, PHP pool, DBs, state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
for lib in caddy php sftp db sftp wp; do
    source "${VPSMGR_LIB_DIR}/${lib}.sh"
done

require_root

usage() {
    cat <<USAGE
Usage: $0 --domain <fqdn> [--skip-backup] [--confirm "DELETE <domain>"]
  Backs up the site automatically before deletion (default).
  --skip-backup    Requires --confirm "DELETE <domain>" exactly.
USAGE
}

DOMAIN="" SKIP_BACKUP=0 CONFIRM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --skip-backup) SKIP_BACKUP=1; shift ;;
        --confirm) CONFIRM="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "${E_USAGE}" "unknown arg: $1" ;;
    esac
done

[[ -n "${DOMAIN}" ]] || { usage; die "${E_USAGE}" "--domain required"; }
validate_domain "${DOMAIN}" || die "${E_USAGE}" "invalid domain: ${DOMAIN}"

# Existence check.
if ! site_exists "${DOMAIN}"; then
    die "${E_NOTFOUND}" "site not found: ${DOMAIN}"
fi

STATE="$(state_read "${DOMAIN}")"

# --- Confirmation for skip-backup ------------------------------------------
if [[ ${SKIP_BACKUP} -eq 1 ]]; then
    if [[ "${CONFIRM}" != "DELETE ${DOMAIN}" ]]; then
        die "${E_USAGE}" "skip-backup requires --confirm \"DELETE ${DOMAIN}\" exactly"
    fi
    log_warn "skipping backup for ${DOMAIN} (explicit confirmation given)"
else
    # Interactive prompt if TTY available; otherwise require --confirm for non-tty.
    if [[ -t 0 ]]; then
        read -r -p "Type DELETE ${DOMAIN} to confirm deletion: " answer
        if [[ "${answer}" != "DELETE ${DOMAIN}" ]]; then
            die "${E_USAGE}" "confirmation did not match; aborted"
        fi
    elif [[ "${CONFIRM}" != "DELETE ${DOMAIN}" ]]; then
        die "${E_USAGE}" "non-interactive deletion requires --confirm \"DELETE ${DOMAIN}\""
    fi
fi

# --- Automatic backup (unless skipped) -----------------------------------
if [[ ${SKIP_BACKUP} -eq 0 ]]; then
    log_info "automatic backup starting for ${DOMAIN}"
    "${SCRIPT_DIR}/backup.sh" --domain "${DOMAIN}" >/dev/null 2>&1 \
        || die "${E_INTERNAL}" "pre-delete backup failed; aborting deletion"
fi

# --- Drop databases (no passwords needed; root access) --------------------
DBS_JSON="$(json_get "${STATE}" databases)"
if [[ -n "${DBS_JSON}" && "${DBS_JSON}" != "null" && "${DBS_JSON}" != "[]" ]]; then
    python3 -c "
import json, sys
for e in json.loads('''${DBS_JSON}'''):
    print(e['engine'] + ' ' + e['name'])
" | while read -r engine name; do
        DB_USER="$(gen_db_user "${DOMAIN}")"
        db_drop "${engine}" "${name}" "${DB_USER}"
    done
fi

# --- Remove PHP pool -------------------------------------------------------
PHP_VER="$(json_get "${STATE}" php_version)"
if [[ -n "${PHP_VER}" ]]; then
    php_remove_pool "${PHP_VER}" "${DOMAIN}"
fi

# --- Remove Caddy block + reload ------------------------------------------
caddy_remove_block "${DOMAIN}"
caddy_reload

# --- Remove SFTP user + home -----------------------------------------------
SFTP_USER="$(json_get "${STATE}" sftp_user)"
if [[ -n "${SFTP_USER}" ]]; then
    sftp_remove_user "${SFTP_USER}"
fi

# --- Remove state ----------------------------------------------------------
state_delete "${DOMAIN}"

log_info "site deleted: ${DOMAIN}"
echo "site-delete: OK ${DOMAIN}"
exit 0

#!/usr/bin/env bash
# scripts/backup.sh — create a site backup archive (webroot + DB dumps + state).
# Archives at 0600 perms, owned by root (D8 — no encryption in v1).
# Supports --all, --domain, --post-hook <cmd> (D3 — escape hatch for off-site).
# Pruning: keeps the latest N days per site (VPSMGR_BACKUP_RETENTION_DAYS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
for lib in db; do
    source "${VPSMGR_LIB_DIR}/${lib}.sh"
done

require_root

usage() {
    cat <<USAGE
Usage: $0 --domain <fqdn> | --all [--post-hook <cmd>]
  Creates a timestamped tar.gz archive under ${VPSMGR_BACKUP_DIR}/<domain>/
  Archive includes: webroot, state JSON, DB dumps for each attached database.
  Perms 0600, owner root. No encryption in v1 (D8).
  --all          Backup every site in state dir.
  --post-hook    Command to run after each archive is created (e.g. off-site
                 upload). Receives the archive path as $1. Escape hatch only (D3).
USAGE
}

DOMAIN="" ALL=0 POST_HOOK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --all) ALL=1; shift ;;
        --post-hook) POST_HOOK="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "${E_USAGE}" "unknown arg: $1" ;;
    esac
done

if [[ ${ALL} -eq 0 && -z "${DOMAIN}" ]]; then
    { usage; die "${E_USAGE}" "either --domain or --all required"; }
fi
if [[ ${ALL} -eq 1 && -n "${DOMAIN}" ]]; then
    die "${E_USAGE}" "--domain and --all are mutually exclusive"
fi
if [[ -n "${DOMAIN}" ]]; then
    validate_domain "${DOMAIN}" || die "${E_USAGE}" "invalid domain: ${DOMAIN}"
fi

backup_one() {
    local domain="$1"
    if ! site_exists "${domain}"; then
        log_warn "skip backup: site not found ${domain}"
        return "${E_NOTFOUND}"
    fi
    local state webroot sftp_user dbs
    state="$(state_read "${domain}")"
    webroot="$(json_get "${state}" webroot)"
    sftp_user="$(json_get "${state}" sftp_user)"
    dbs="$(json_get "${state}" databases)"

    local bdir
    bdir="$(backup_dir_for "${domain}")"
    mkdir -p "${bdir}"
    chmod 750 "${bdir}"

    local ts
    ts="$(timestamp_fn)"
    local archive="${bdir}/${domain}-${ts}.tar.gz"

    local tmpd
    tmpd="$(mktemp -d)"
    trap 'rm -rf "${tmpd}"' RETURN

    # Stage webroot (follow symlinks safely within the tree only).
    if [[ -d "${webroot}" ]]; then
        mkdir -p "${tmpd}/webroot"
        # cp as root to preserve all content; archive perms handle protection.
        cp -a "${webroot}/." "${tmpd}/webroot/" 2>/dev/null || true
    fi

    # Stage state.
    mkdir -p "${tmpd}/state"
    cp "$(state_file_for "${domain}")" "${tmpd}/state/site.json" 2>/dev/null || true

    # Stage DB dumps.
    if [[ -n "${dbs}" && "${dbs}" != "null" && "${dbs}" != "[]" ]]; then
        mkdir -p "${tmpd}/db"
        local idx=0
        python3 -c "
import json
for e in json.loads('''${dbs}'''):
    print(e['engine'] + '|' + e['name'])
" | while IFS='|' read -r engine name; do
            local dump="${tmpd}/db/${idx}-${engine}-${name}.sql"
            db_dump "${engine}" "${name}" > "${dump}" 2>/dev/null || true
            idx=$((idx+1))
        done
    fi

    # Create the archive at 0600 owned by root (D8).
    tar -C "${tmpd}" -czf "${archive}" . 2>/dev/null
    chmod "${VPSMGR_BACKUP_MODE}" "${archive}"
    chown root:root "${archive}"
    log_info "archive created: ${archive}"

    # Prune older backups beyond retention window.
    local kept="${VPSMGR_BACKUP_RETENTION_DAYS}"
    find "${bdir}" -type f -name "${domain}-*.tar.gz" -mtime +${kept} -print \
        | while read -r old; do
            rm -f "${old}"
            log_info "pruned old backup: ${old}"
        done

    # Post-hook escape hatch (D3). Receives archive path as $1.
    if [[ -n "${POST_HOOK}" ]]; then
        # Run the hook; do NOT fail the backup if the hook fails (warn only).
        if bash -c "${POST_HOOK} '${archive}'" 2>&1 | sed 's/^/[post-hook] /'; then
            log_info "post-hook ok: ${POST_HOOK}"
        else
            log_warn "post-hook failed (backup preserved): ${POST_HOOK}"
        fi
    fi

    echo "${archive}"
}

if [[ ${ALL} -eq 1 ]]; then
    shopt -s nullglob
    any_ok=0
    for f in "${VPSMGR_STATE_DIR}"/*.json; do
        d="$(basename "${f}" .json)"
        if backup_one "${d}" >/dev/null 2>&1; then
            any_ok=1
        fi
    done
    shopt -u nullglob
    if [[ ${any_ok} -eq 0 ]]; then
        die "${E_NOTFOUND}" "no sites to back up"
    fi
    echo "backup: OK (all)"
    exit 0
else
    archive_path="$(backup_one "${DOMAIN}")" || die $? "backup failed for ${DOMAIN}"
    echo "backup: OK ${archive_path}"
    exit 0
fi

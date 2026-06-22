#!/usr/bin/env bash
# scripts/deploy.sh — deploy files from a server-local source path into a
# site's webroot. Runs as the site user. Refuses if source missing or unreadable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

usage() {
    cat <<USAGE
Usage: $0 --domain <fqdn> --source <local-path> [--rsync-args <args>]
  Copies <source> into the site's webroot using rsync.
  --source must be a readable server-local path (no remote URLs).
  The destination webroot is taken from site state.
USAGE
}

DOMAIN="" SOURCE="" RSYNC_ARGS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --rsync-args) RSYNC_ARGS="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "${E_USAGE}" "unknown arg: $1" ;;
    esac
done

[[ -n "${DOMAIN}" && -n "${SOURCE}" ]] || { usage; die "${E_USAGE}" "--domain and --source required"; }
validate_domain "${DOMAIN}" || die "${E_USAGE}" "invalid domain: ${DOMAIN}"

# Source must be a local, readable path. No URLs / no remote.
if [[ ! -d "${SOURCE}" && ! -f "${SOURCE}" ]]; then
    die "${E_NOTFOUND}" "source path not found: ${SOURCE}"
fi
if [[ ! -r "${SOURCE}" ]]; then
    die "${E_USAGE}" "source not readable: ${SOURCE}"
fi
case "${SOURCE}" in
    http://*|https://*|rsync://*|*:*@*) die "${E_USAGE}" "remote sources not supported; use a server-local path";;
esac

if ! site_exists "${DOMAIN}"; then
    die "${E_NOTFOUND}" "site not found: ${DOMAIN}"
fi

STATE="$(state_read "${DOMAIN}")"
WEBROOT="$(json_get "${STATE}" webroot)"
SFTP_USER="$(json_get "${STATE}" sftp_user)"
[[ -n "${WEBROOT}" && -n "${SFTP_USER}" ]] || die "${E_INTERNAL}" "state missing webroot/sftp_user"

mkdir -p "${WEBROOT}"
chown "${SFTP_USER}:${SFTP_USER}" "${WEBROOT}"

# rsync from source into webroot. Trailing slash on source → copy contents.
local_src="${SOURCE%/}/"
# shellcheck disable=SC2086  # intentional word-splitting of args
rsync -a --delete ${RSYNC_ARGS} "${local_src}" "${WEBROOT}/" 2>&1 | sed 's/^/[rsync] /' || die "${E_INTERNAL}" "rsync failed"

# Ensure ownership of deployed files is the site user.
chown -R "${SFTP_USER}:${SFTP_USER}" "${WEBROOT}" 2>/dev/null || true
# Directories searchable; files not world-writable.
find "${WEBROOT}" -type d -exec chmod 755 {} + 2>/dev/null || true
find "${WEBROOT}" -type f -exec chmod 644 {} + 2>/dev/null || true
# wp-config.php (if present) stays 600.
[[ -f "${WEBROOT}/wp-config.php" ]] && chmod 600 "${WEBROOT}/wp-config.php" 2>/dev/null || true

log_info "deploy complete: ${DOMAIN} ← ${SOURCE}"
echo "deploy: OK ${DOMAIN}"
exit 0

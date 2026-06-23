#!/usr/bin/env bash
# scripts/deploy.sh — deploy static files into a site webroot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    echo "Usage: $0 <domain> <source-path>" >&2
    exit 1
}

main() {
    require_root
    [[ $# -eq 2 ]] || usage
    local domain="$1"
    local source="$2"
    validate_domain "${domain}"

    if ! state_exists "${domain}"; then
        die_notfound "site not found: ${domain}"
    fi

    local type
    type=$(state_get "${domain}" '.type')
    if [[ ${type} != "static" ]]; then
        die_input "deploy is only supported for static sites (found ${type})"
    fi

    if [[ ! -e ${source} ]]; then
        die_notfound "source path not found: ${source}"
    fi

    local webroot sftp_user
    webroot=$(state_get "${domain}" '.webroot')
    sftp_user=$(state_get "${domain}" '.sftp_user')

    require_command rsync
    if [[ -d ${source} ]]; then
        rsync -a --delete --exclude='.~tmp~' "${source}/" "${webroot}/"
    else
        # Single file deployment not typical; copy into webroot preserving name.
        cp -a "${source}" "${webroot}/"
    fi
    chown -R "${sftp_user}:${sftp_user}" "${webroot}"

    vpsmgr_log INFO "deployed ${source} to ${webroot}"
    echo "Deployed ${source} to ${domain}."
}

main "$@"

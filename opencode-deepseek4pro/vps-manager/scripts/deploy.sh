#!/usr/bin/env bash
# deploy.sh — Deploy site files from a server-local source
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0") --domain <domain> --source <path> [--archive <tar.gz|zip>] [--backup-before]

Deploys site files from a server-local path to the site's webroot.
The source must be a directory or archive on the server.

Options:
  --domain DOMAIN    Domain of the site (required)
  --source PATH      Server-local source path (required)
  --archive TYPE     Archive type if source is a file: tar.gz or zip
  --backup-before    Create a backup before deploying
  --help             Show this help
USAGE
    exit 1
}

main() {
    require_root

    local domain=""
    local source_path=""
    local archive_type=""
    local backup_before="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)        domain="$2"; shift 2 ;;
            --source)        source_path="$2"; shift 2 ;;
            --archive)       archive_type="$2"; shift 2 ;;
            --backup-before) backup_before="true"; shift ;;
            -h|--help)       usage ;;
            *)               echo "Unknown option: $1"; usage ;;
        esac
    done

    if [[ -z "${domain}" || -z "${source_path}" ]]; then
        exit_input_error "--domain and --source are required"
    fi

    validate_domain "${domain}"

    if [[ ! -f "$(state_file "${domain}")" ]]; then
        exit_not_found "Site '${domain}' not found"
    fi

    local webroot sftp_user
    webroot=$(python3 -c "import sys,json; print(json.load(sys.stdin)['webroot'])" < "$(state_file "${domain}")")
    sftp_user=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('sftp_user',''))" < "$(state_file "${domain}")")

    # Backup before deploy if requested
    if [[ "${backup_before}" == "true" ]]; then
        "${SCRIPT_DIR}/backup.sh" --domain "${domain}"
    fi

    # Clear webroot (preserve .well-known for cert renewal)
    log_info "Clearing webroot: ${webroot}"
    find "${webroot}" -mindepth 1 -maxdepth 1 -not -name '.well-known' -exec rm -rf {} + 2>/dev/null || true

    # Deploy from source
    if [[ -f "${source_path}" && -n "${archive_type}" ]]; then
        log_info "Extracting archive: ${source_path}"
        case "${archive_type}" in
            tar.gz|tgz)
                tar -xzf "${source_path}" -C "${webroot}" --strip-components=0
                ;;
            zip)
                if ! command -v unzip &>/dev/null; then
                    apt-get install -y -qq unzip
                fi
                unzip -q -o "${source_path}" -d "${webroot}"
                ;;
            *)
                exit_input_error "Unsupported archive type: ${archive_type} (use tar.gz or zip)"
                ;;
        esac
    elif [[ -d "${source_path}" ]]; then
        log_info "Copying files from: ${source_path}"
        rsync -a --delete "${source_path}/" "${webroot}/" 2>/dev/null || \
            cp -a "${source_path}/." "${webroot}/"
    else
        exit_input_error "Source path does not exist or is not valid: ${source_path}"
    fi

    # Set correct ownership
    chown -R "${sftp_user}:${sftp_user}" "${webroot}"
    find "${webroot}" -type d -exec chmod 755 {} \;
    find "${webroot}" -type f -exec chmod 644 {} \;

    # Ensure .well-known is accessible
    mkdir -p "${webroot}/.well-known"
    chmod 755 "${webroot}/.well-known"

    log_info "Deploy complete for ${domain}"
    echo "Site '${domain}' deployed from: ${source_path}"

    exit 0
}

main "$@"
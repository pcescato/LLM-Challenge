#!/usr/bin/env bash
# site-create.sh — Create a new site (static, php, wordpress, proxy)
# WordPress type blocked via API — contextual CLI-only warning
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/caddy.sh"
source "${SCRIPT_DIR}/lib/php.sh"
source "${SCRIPT_DIR}/lib/sftp.sh"
source "${SCRIPT_DIR}/lib/wp.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0") --domain <domain> --type <static|php|wordpress|proxy> [--proxy-target <url>] [--php-version <ver>] [--wp-interactive]

Creates a new site with SFTP user, webroot, Caddy config, and optionally PHP/WP.

Options:
  --domain DOMAIN        Domain name (required)
  --type TYPE            Site type: static, php, wordpress, proxy (required)
  --proxy-target URL     Proxy upstream URL (required for proxy type)
  --php-version VER      PHP-FPM version (default: latest)
  --wp-interactive       Interactive WordPress admin setup (CLI only; blocked via API)
  --help                 Show this help
USAGE
    exit 1
}

main() {
    require_root

    local domain=""
    local site_type=""
    local proxy_target=""
    local php_version=""
    local wp_interactive="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)       domain="$2"; shift 2 ;;
            --type)         site_type="$2"; shift 2 ;;
            --proxy-target) proxy_target="$2"; shift 2 ;;
            --php-version)  php_version="$2"; shift 2 ;;
            --wp-interactive) wp_interactive="true"; shift ;;
            -h|--help)      usage ;;
            *)              echo "Unknown option: $1"; usage ;;
        esac
    done

    if [[ -z "${domain}" || -z "${site_type}" ]]; then
        exit_input_error "--domain and --type are required"
    fi

    validate_domain "${domain}"
    validate_site_type "${site_type}"

    local sitename
    sitename=$(domain_to_sftp_user "${domain}")

    # Check for conflict — state file already exists
    if [[ -f "$(state_file "${domain}")" ]]; then
        exit_conflict "Site '${domain}' already exists"
    fi

    # --- Create SFTP user ---
    sftp_user_create "${sitename}"

    local webroot="${SITE_BASE_HOME}/${sitename}/public"
    mkdir -p "${webroot}"
    chown "${sitename}:${sitename}" "${webroot}"
    chmod 750 "${webroot}"

    # --- Setup PHP if needed ---
    local php_ver=""
    local php_pool=""
    if [[ "${site_type}" == "php" || "${site_type}" == "wordpress" ]]; then
        if [[ -z "${php_version}" ]]; then
            php_ver=$(php_detect_latest)
        else
            php_ver="${php_version}"
        fi

        # Ensure PHP version is installed
        php_install "${php_ver}"

        # Create PHP-FPM pool
        php_pool=$(php_pool_create "${domain}" "${sitename}" "${php_ver}")
        php_fpm_reload "${php_ver}"
    fi

    # --- Generate Caddy block ---
    local caddy_block
    caddy_block=$(caddy_generate_block "${domain}" "${site_type}" "${webroot}" "${proxy_target}")

    # Try reload, restart if needed
    set +e
    caddy_reload 2>/dev/null
    local caddy_exit=$?
    set -e
    if [[ ${caddy_exit} -ne 0 ]]; then
        log_error "Caddy reload failed — check ${caddy_block} for syntax errors"
        exit_internal "Caddy configuration error"
    fi

    # --- WordPress warning to stderr (CLI only) ---
    if [[ "${site_type}" == "wordpress" ]]; then
        if [[ "${wp_interactive}" == "true" ]]; then
            cat >&2 <<WPNOTICE

╔══════════════════════════════════════════════════════════════════╗
║ WORDPRESS: Site files created. To complete setup:               ║
║                                                                ║
║   1. Create a database:   db-create.sh --domain ${domain}       ║
║   2. Create wp-config.php using the credentials above           ║
║   3. Run the WordPress installer:                               ║
║      cd ${webroot} && wp core install \\                        ║
║        --url='https://${domain}' \\                             ║
║        --title='My Site' \\                                     ║
║        --admin_user='admin' \\                                  ║
║        --admin_email='admin@${domain}'                          ║
║      (admin password will be prompted interactively)            ║
║                                                                ║
║   WordPress admin credentials are interactive TTY only.         ║
╚══════════════════════════════════════════════════════════════════════╝
WPNOTICE
        else
            cat >&2 <<WPNOTICE

╔══════════════════════════════════════════════════════════════════╗
║ WORDPRESS: Site files and configuration created. WordPress      ║
║ admin credentials require interactive TTY. Run this script      ║
║ with --wp-interactive from a terminal to complete setup.        ║
╚══════════════════════════════════════════════════════════════════╝
WPNOTICE
        fi
    fi

    # --- Write state file ---
    local now
    now=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

    local db_array="[]"
    local proxy_json="null"

    if [[ "${site_type}" == "proxy" ]]; then
        proxy_json="\"${proxy_target}\""
    fi

    local state_json
    state_json=$(cat <<STATEJSON
{
  "domain": "${domain}",
  "type": "${site_type}",
  "sftp_user": "${sitename}",
  "webroot": "${webroot}",
  "php_version": "${php_ver:-null}",
  "php_pool": "${php_pool:-null}",
  "caddy_block": "${caddy_block}",
  "databases": ${db_array},
  "proxy_target": ${proxy_json},
  "created_at": "${now}"
}
STATEJSON
)

    write_state "${domain}" "${state_json}"
    mkdir -p "${STATE_DIR}" 2>/dev/null || true

    # --- Status output ---
    echo ""
    echo "Site created: ${domain}"
    echo "  Type:       ${site_type}"
    echo "  Webroot:    ${webroot}"
    echo "  SFTP User:  ${sitename}"
    if [[ -n "${php_ver}" ]]; then
        echo "  PHP:        ${php_ver}"
    fi
    if [[ "${site_type}" == "proxy" ]]; then
        echo "  Proxy:      ${proxy_target}"
    fi
    echo ""

    exit 0
}

main "$@"
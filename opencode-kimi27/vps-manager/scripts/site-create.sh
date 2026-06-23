#!/usr/bin/env bash
# scripts/site-create.sh — provision a new site.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/caddy.sh
source "${SCRIPT_DIR}/lib/caddy.sh"
# shellcheck source=lib/php.sh
source "${SCRIPT_DIR}/lib/php.sh"
# shellcheck source=lib/db.sh
source "${SCRIPT_DIR}/lib/db.sh"
# shellcheck source=lib/sftp.sh
source "${SCRIPT_DIR}/lib/sftp.sh"
# shellcheck source=lib/wp.sh
source "${SCRIPT_DIR}/lib/wp.sh"

DOMAIN=""
TYPE=""
PHP_VERSION_ARG="${DEFAULT_PHP_VERSION}"
WANT_DB=false
DB_ENGINE="${DEFAULT_DB_ENGINE}"
PROXY_TARGET=""

usage() {
    cat >&2 <<EOF
Usage: $0 <domain> <type> [options]
  type: static | php | wordpress | reverse_proxy
Options:
  --php-version current|fallback|<version>   (default: ${DEFAULT_PHP_VERSION})
  --database                                 create a database (php only)
  --db-engine mariadb|postgres               (default: ${DEFAULT_DB_ENGINE})
  --proxy-target <url>                       required for reverse_proxy
EOF
    exit 1
}

parse_args() {
    [[ $# -ge 2 ]] || usage
    DOMAIN="$1"
    TYPE="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --php-version)
                PHP_VERSION_ARG="$2"
                shift 2
                ;;
            --database)
                WANT_DB=true
                shift
                ;;
            --db-engine)
                DB_ENGINE="$2"
                shift 2
                ;;
            --proxy-target)
                PROXY_TARGET="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                die_input "unknown option: $1"
                ;;
        esac
    done
}

main() {
    require_root
    require_command jq
    parse_args "$@"
    validate_domain "${DOMAIN}"

    if state_exists "${DOMAIN}"; then
        die_conflict "site already exists: ${DOMAIN}"
    fi

    case "${TYPE}" in
        static|php|wordpress|reverse_proxy) ;;
        *) die_input "invalid site type: ${TYPE}" ;;
    esac

    if [[ ${TYPE} == "reverse_proxy" && -z ${PROXY_TARGET} ]]; then
        die_input "--proxy-target is required for reverse_proxy sites"
    fi

    if [[ ${TYPE} == "static" || ${TYPE} == "reverse_proxy" ]] && [[ ${WANT_DB} == true ]]; then
        die_input "database not supported for ${TYPE} sites"
    fi

    db_validate_engine "${DB_ENGINE}"

    local sftp_user sftp_pass db_user db_pass db_name php_version pool_file caddy_file
    db_user=""
    db_pass=""
    db_name=""
    sftp_pass=""

    sftp_user_create "${DOMAIN}" sftp_user sftp_pass
    local webroot
    webroot=$(sftp_webroot "${sftp_user}")
    chmod 0755 "${webroot}"

    php_version=""
    pool_file=""
    if [[ ${TYPE} == "php" || ${TYPE} == "wordpress" ]]; then
        php_version=$(php_resolve_version "${PHP_VERSION_ARG}")
        if [[ ! -d /etc/php/${php_version}/fpm ]]; then
            die_dependency "php ${php_version} is not installed"
        fi
        php_render_pool "${DOMAIN}" "${php_version}" "${sftp_user}" "${webroot}"
        pool_file=$(php_pool_file "${DOMAIN}" "${php_version}")
        php_ensure_service_running "${php_version}"
    fi

    if [[ ${TYPE} == "wordpress" || (${TYPE} == "php" && ${WANT_DB} == true) ]]; then
        db_create "${DB_ENGINE}" "${DOMAIN}" db_user db_pass
        db_name=$(domain_to_db_name "${DOMAIN}" "${DB_ENGINE}")
    fi

    caddy_ensure_sites_dir
    local socket=""
    [[ -n ${php_version} ]] && socket=$(php_socket_for "${DOMAIN}" "${php_version}")
    caddy_render_site "${DOMAIN}" "${TYPE}" "${webroot}" "${socket}" "${PROXY_TARGET}"
    caddy_file=$(caddy_site_path "${DOMAIN}")

    if [[ ${TYPE} == "wordpress" ]]; then
        wp_download "${webroot}" "${sftp_user}"
        wp_create_config "${webroot}" "${db_name}" "${db_user}" "${db_pass}" "${DOMAIN}" "${sftp_user}"
        wp_install_interactive "${DOMAIN}" "${webroot}" "${sftp_user}"
    elif [[ ${TYPE} == "php" ]]; then
        # Place a placeholder index so the pool is reachable.
        echo "<?php phpinfo();" > "${webroot}/index.php"
        chown "${sftp_user}:${sftp_user}" "${webroot}/index.php"
    elif [[ ${TYPE} == "static" ]]; then
        cat > "${webroot}/index.html" <<EOF
<!doctype html>
<html><head><title>${DOMAIN}</title></head>
<body><h1>${DOMAIN}</h1></body></html>
EOF
        chown "${sftp_user}:${sftp_user}" "${webroot}/index.html"
    fi

    # Persist state (no passwords).
    state_create "${DOMAIN}" "${TYPE}" "${sftp_user}" "${webroot}" "${php_version}" "${pool_file}" "${caddy_file}" "${PROXY_TARGET:-null}"
    if [[ -n ${db_name} ]]; then
        state_add_database "${DOMAIN}" "${DB_ENGINE}" "${db_name}" "${db_user}"
    fi

    caddy_reload
    if [[ -n ${php_version} ]]; then
        php_reload "${php_version}"
    fi

    vpsmgr_log INFO "site ${DOMAIN} created (type=${TYPE})"
    echo "Site ${DOMAIN} (${TYPE}) created."
    echo "  Webroot: ${webroot}"
    echo "  SFTP user: ${sftp_user}"
    print_credentials "sftp_password" "${sftp_pass}"
    if [[ -n ${db_name} ]]; then
        echo "  Database: ${db_name}"
        echo "  DB user: ${db_user}"
        print_credentials "database_password" "${db_pass}"
    fi
}

main "$@"

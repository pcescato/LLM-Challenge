#!/usr/bin/env bash
# scripts/site-create.sh — create a site (static | php | proxy | wordpress).
# Wordpress type is CLI-only (interactive admin credentials) — API must reject.
# SFTP password printed once to stdout wrapped in <<<CREDENTIALS>>> markers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
for lib in caddy php sftp db wp; do
    source "${VPSMGR_LIB_DIR}/${lib}.sh"
done

require_root

usage() {
    cat <<USAGE
Usage: $0 --domain <fqdn> --type <type> [--proxy-target <url>] [--php-version <ver>] [--db-engine <engine>] [--db-name <name>] [--no-db]
  type: static | php | proxy | wordpress
  --proxy-target <url>      Required for type=proxy (e.g. http://127.0.0.1:3000)
  --php-version <ver>       Override the dynamically resolved PHP version.
  --db-engine <engine>      mariadb | postgresql (wordpress defaults to mariadb)
  --db-name <name>          Override generated DB name.
  --no-db                   Skip database creation (php/static only).
  For type=wordpress, admin credentials are prompted on TTY only.
USAGE
}

DOMAIN="" TYPE="" PROXY_TARGET="" PHP_VERSION_OVERRIDE="" DB_ENGINE="" DB_NAME_OVERRIDE="" NO_DB=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --type) TYPE="$2"; shift 2 ;;
        --proxy-target) PROXY_TARGET="$2"; shift 2 ;;
        --php-version) PHP_VERSION_OVERRIDE="$2"; shift 2 ;;
        --db-engine) DB_ENGINE="$2"; shift 2 ;;
        --db-name) DB_NAME_OVERRIDE="$2"; shift 2 ;;
        --no-db) NO_DB=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "${E_USAGE}" "unknown arg: $1" ;;
    esac
    shift
done

# --- Validation ------------------------------------------------------------
[[ -n "${DOMAIN}" && -n "${TYPE}" ]] || { usage; die "${E_USAGE}" "--domain and --type required"; }
validate_domain "${DOMAIN}" || die "${E_USAGE}" "invalid domain: ${DOMAIN}"
case "${TYPE}" in
    static|php|proxy|wordpress) ;;
    *) die "${E_USAGE}" "invalid type: ${TYPE} (static|php|proxy|wordpress)" ;;
esac
if [[ "${TYPE}" == "proxy" && -z "${PROXY_TARGET}" ]]; then
    die "${E_USAGE}" "--proxy-target required for type=proxy"
fi
if [[ ! -t 0 && "${TYPE}" == "wordpress" ]]; then
    # D7/constraint: admin creds are TTY-only. API must reject before here,
    # but defend in depth.
    die "${E_USAGE}" "wordpress type requires an interactive TTY (admin credentials)"
fi

# --- Idempotency -----------------------------------------------------------
if site_exists "${DOMAIN}"; then
    die "${E_CONFLICT}" "site already exists: ${DOMAIN}"
fi

# --- SFTP user + webroot ----------------------------------------------------
SFTP_USER="$(domain_to_user "${DOMAIN}")"
WEBROOT="$(sftp_user_home "${SFTP_USER}")/public"

SFTP_PASS="$(sftp_create_user "${DOMAIN}" "${SFTP_USER}")"
sftp_add_to_group "${SFTP_USER}"

# --- PHP version resolution (only for php/wordpress) ----------------------
PHP_VER="" PHP_POOL="" PHP_SOCKET=""
if [[ "${TYPE}" == "php" || "${TYPE}" == "wordpress" ]]; then
    if [[ -n "${PHP_VERSION_OVERRIDE}" ]]; then
        PHP_VER="${PHP_VERSION_OVERRIDE}"
        _php_version_ok "${PHP_VER}" || die "${E_USAGE}" "php version below minimum: ${PHP_VER}"
    elif [[ -f "${VPSMGR_CONFIG_DIR}/php.version" ]]; then
        PHP_VER="$(cat "${VPSMGR_CONFIG_DIR}/php.version")"
    else
        PHP_VER="$(php_resolve_version)" || die "${E_DEP}" "no PHP version available; run bootstrap"
    fi
    # Ensure the FPM service is installed.
    if ! systemctl list-unit-files "php${PHP_VER}-fpm.service" 2>/dev/null | grep -q "php${PHP_VER}-fpm"; then
        php_install "${PHP_VER}"
    fi
    php_ensure_running "${PHP_VER}"
    PHP_SOCKET="$(php_socket_path "${DOMAIN}" "${PHP_VER}")"
    PHP_POOL="$(php_pool_path "${PHP_VER}" "${DOMAIN}")"
    php_create_pool "${DOMAIN}" "${SFTP_USER}" "${WEBROOT}" "${PHP_VER}"
fi

# --- Database (mariadb default for wordpress) ------------------------------
DB_ENTRY="" DB_NAME="" DB_USER="" DB_ENGINE_USED=""
if [[ "${TYPE}" == "wordpress" ]]; then
    DB_ENGINE_USED="${DB_ENGINE:-mariadb}"
    DB_NAME="${DB_NAME_OVERRIDE:-$(gen_db_name "${DOMAIN}")}"
    DB_USER="$(gen_db_user "${DOMAIN}")"
    DB_PASS="$(db_create "${DB_ENGINE_USED}" "${DB_NAME}" "${DB_USER}")"
    DB_ENTRY="{\"engine\": \"${DB_ENGINE_USED}\", \"name\": \"${DB_NAME}\"}"
elif [[ "${TYPE}" == "php" ]] && [[ ${NO_DB} -eq 0 ]] && [[ -n "${DB_ENGINE}" ]]; then
    DB_ENGINE_USED="${DB_ENGINE}"
    DB_NAME="${DB_NAME_OVERRIDE:-$(gen_db_name "${DOMAIN}")}"
    DB_USER="$(gen_db_user "${DOMAIN}")"
    DB_PASS="$(db_create "${DB_ENGINE_USED}" "${DB_NAME}" "${DB_USER}")"
    DB_ENTRY="{\"engine\": \"${DB_ENGINE_USED}\", \"name\": \"${DB_NAME}\"}"
fi

# --- WordPress specific ----------------------------------------------------
if [[ "${TYPE}" == "wordpress" ]]; then
    wp_download_core "${SFTP_USER}" "${WEBROOT}"
    # wp-config.php written directly into app config (chmod 600, owned by user). D1.
    wp_config_write "${SFTP_USER}" "${WEBROOT}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "localhost" "${DB_ENGINE_USED}"
    # Interactive install on TTY.
    wp_install_interactive "${SFTP_USER}" "${WEBROOT}" "${DOMAIN}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${DB_ENGINE_USED}"
    # Forget DB password immediately after WP install.
    unset DB_PASS
fi

# --- Caddy block -----------------------------------------------------------
CADDY_BLOCK="$(caddy_block_path "${DOMAIN}")"
caddy_write_block "${DOMAIN}" "${TYPE}" "${WEBROOT}" "${PHP_SOCKET}" "${PROXY_TARGET}"
caddy_reload

# --- State (no passwords — D1) ----------------------------------------------
CREATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
DATABASES_JSON="[]"
if [[ -n "${DB_ENTRY}" ]]; then
    DATABASES_JSON="[${DB_ENTRY}]"
fi
STATE=$(python3 -c "
import json, sys
d = {
    'domain': '${DOMAIN}',
    'type': '${TYPE}',
    'sftp_user': '${SFTP_USER}',
    'webroot': '${WEBROOT}',
    'php_version': '${PHP_VER}' if '${PHP_VER}' else None,
    'php_pool': '${PHP_POOL}' if '${PHP_POOL}' else None,
    'caddy_block': '${CADDY_BLOCK}',
    'databases': json.loads('''${DATABASES_JSON}'''),
    'proxy_target': '${PROXY_TARGET}' if '${PROXY_TARGET}' else None,
    'created_at': '${CREATED_AT}',
}
print(json.dumps(d, indent=2))
")
state_write "${DOMAIN}" "${STATE}"

# --- Credentials output (SFTP + DB password) printed once to stdout -------
{
    echo "sftp_user=${SFTP_USER}"
    echo "sftp_password=${SFTP_PASS}"
    if [[ -n "${DB_USER}" ]]; then
        echo "db_engine=${DB_ENGINE_USED}"
        echo "db_name=${DB_NAME}"
        echo "db_user=${DB_USER}"
        echo "db_password=${DB_PASS}"
    fi
} | print_credentials

# Forget in-memory secrets at the earliest point.
unset SFTP_PASS DB_PASS

log_info "site created: ${DOMAIN} (type=${TYPE})"
echo "site-create: OK ${DOMAIN}"
exit 0

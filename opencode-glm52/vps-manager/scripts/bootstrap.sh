#!/usr/bin/env bash
# scripts/bootstrap.sh — one-shot host provisioning. Idempotent.
# Installs: Caddy (stable channel), PHP-FPM (latest dynamic), MariaDB,
# PostgreSQL (latest from PGDG), WP-CLI, Python/uvicorn for the API.
# Creates runtime dirs, generates API token if missing, hardens SSH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
# Source all libs now since bootstrap orchestrates everything.
for lib in caddy php db sftp wp; do
    source "${VPSMGR_LIB_DIR}/${lib}.sh"
done

require_root

usage() {
    cat <<USAGE
Usage: $0 [--with-api] [--no-caddy] [--no-php] [--no-db] [--no-wp] [--no-sftp-harden] [--help]
  Provisions this host for VPS management. All steps idempotent.
  --with-api          Install + enable the vpsmgr-api systemd unit (needs repo at /opt/vps-manager).
  --no-caddy          Skip Caddy install.
  --no-php            Skip PHP-FPM install.
  --no-db             Skip database engines.
  --no-wp             Skip WP-CLI install.
  --no-sftp-harden    Skip SSH password-auth hardening.
  --help              Show this help.
USAGE
}

WITH_API=0
DO_CADDY=1 DO_PHP=1 DO_DB=1 DO_WP=1 DO_SFTP=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-api) WITH_API=1 ;;
        --no-caddy) DO_CADDY=0 ;;
        --no-php) DO_PHP=0 ;;
        --no-db) DO_DB=0 ;;
        --no-wp) DO_WP=0 ;;
        --no-sftp-harden) DO_SFTP=0 ;;
        --help|-h) usage; exit 0 ;;
        *) die "${E_USAGE}" "unknown arg: $1" ;;
    esac
    shift
done

log_info "bootstrap starting (api=${WITH_API} caddy=${DO_CADDY} php=${DO_PHP} db=${DO_DB} wp=${DO_WP})"

# --- 0. Apt base -----------------------------------------------------------
apt_get_update() {
    apt-get update -qq >/dev/null 2>&1 || true
}
install_pkgs() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq "$@" >/dev/null
}

require_cmd apt-get
apt_get_update
install_pkgs ca-certificates curl gnupg lsb-release software-properties-common \
             python3 python3-venv python3-pip jq rsync tar

# --- 1. Runtime directories -------------------------------------------------
mkdir -p "${VPSMGR_CONFIG_DIR}" "${VPSMGR_LOG_DIR}" "${VPSMGR_STATE_DIR}" \
         "${VPSMGR_BACKUP_DIR}" "${VPSMGR_CADDY_SITES_DIR}" \
         "${VPSMGR_TEMPLATES_DIR}"
chmod 750 "${VPSMGR_CONFIG_DIR}" "${VPSMGR_LOG_DIR}" "${VPSMGR_BACKUP_DIR}"
chmod 755 "${VPSMGR_STATE_DIR}" "${VPSMGR_CADDY_SITES_DIR}"

# Install the bundled config if none exists yet.
if [[ ! -f "${VPSMGR_CONFIG_DIR}/vpsmgr.conf" ]]; then
    if [[ -f "${VPSMGR_REPO_ROOT}/config/vpsmgr.conf" ]]; then
        install -m 640 "${VPSMGR_REPO_ROOT}/config/vpsmgr.conf" "${VPSMGR_CONFIG_DIR}/vpsmgr.conf"
    fi
fi

# Install templates into the shared templates dir.
if [[ -d "${VPSMGR_REPO_ROOT}/templates" ]]; then
    cp -a "${VPSMGR_REPO_ROOT}/templates/." "${VPSMGR_TEMPLATES_DIR}/" 2>/dev/null || true
fi

# --- 2. Caddy (stable channel only — D10) ----------------------------------
if [[ ${DO_CADDY} -eq 1 ]]; then
    if ! command -v caddy >/dev/null 2>&1; then
        log_info "installing caddy (stable channel)"
        # Official Caddy apt repo — stable only.
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://dl.caddyrc.com/keys/caddy-stable-archive.asc \
            | gpg --dearmor -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/caddy-stable-archive-keyring.gpg] https://dl.caddyrc.com/stable/debian $(. /etc/os-release; echo "${VERSION_CODENAME:-bookworm}") main" \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt_get_update
        install_pkgs caddy
    fi
    caddy_ensure_import
    systemctl enable --now caddy 2>/dev/null || true
    log_info "caddy ready"
fi

# --- 3. PHP-FPM (dynamic latest — D9) --------------------------------------
if [[ ${DO_PHP} -eq 1 ]]; then
    # Sury PHP PPA provides latest PHP for Debian.
    if ! grep -q '^deb .*packages.sury.org/php' /etc/apt/sources.list.d/*.list 2>/dev/null; then
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/keyrings/sury-php-archive-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/sury-php-archive-keyring.gpg] https://packages.sury.org/php $(. /etc/os-release; echo "${VERSION_CODENAME:-bookworm}") main" \
            > /etc/apt/sources.list.d/sury-php.list
        apt_get_update
    fi
    PHP_VER="$(php_resolve_version)" || die "${E_DEP}" "no suitable PHP version available"
    log_info "selected php ${PHP_VER}"
    php_install "${PHP_VER}"
    php_ensure_running "${PHP_VER}"
    # Store the chosen version in bootstrap state for later scripts.
    mkdir -p "${VPSMGR_CONFIG_DIR}"
    echo "${PHP_VER}" > "${VPSMGR_CONFIG_DIR}/php.version"
fi

# --- 4. MariaDB ------------------------------------------------------------
if [[ ${DO_DB} -eq 1 ]]; then
    if ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
        log_info "installing mariadb-server"
        install_pkgs mariadb-server
    fi
    systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || true
    # Root via unix_socket; remove anonymous + test db if present (mysql_secure_installation essentials).
    if command -v mariadb >/dev/null 2>&1; then
        mariadb -uroot -e "DELETE FROM mysql.user WHERE User=''; DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'); DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" 2>/dev/null || true
    fi

    # PostgreSQL from PGDG (latest dynamic — D5).
    if ! command -v psql >/dev/null 2>&1; then
        log_info "installing postgresql from PGDG"
        codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-bookworm}")"
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            | gpg --dearmor -o /etc/apt/keyrings/postgresql-archive-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/postgresql-archive-keyring.gpg] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
        apt_get_update
        install_pkgs postgresql
    fi
    systemctl enable --now postgresql 2>/dev/null || true
fi

# --- 5. WP-CLI -------------------------------------------------------------
if [[ ${DO_WP} -eq 1 ]]; then
    wp_install_cli
fi

# --- 6. SFTP hardening -----------------------------------------------------
if [[ ${DO_SFTP} -eq 1 ]]; then
    sftp_configure_sshd
    sftp_disable_global_password_auth
fi

# --- 7. API token (chmod 600) and service ----------------------------------
if [[ ! -f "${VPSMGR_API_TOKEN_FILE}" ]]; then
    install -d -m 750 "$(dirname "${VPSMGR_API_TOKEN_FILE}")"
    TOKEN="$(gen_password 40)"
    umask 077
    printf '%s\n' "${TOKEN}" > "${VPSMGR_API_TOKEN_FILE}"
    unset TOKEN
    chmod 600 "${VPSMGR_API_TOKEN_FILE}"
    chown root:root "${VPSMGR_API_TOKEN_FILE}"
    log_info "api token generated at ${VPSMGR_API_TOKEN_FILE} (chmod 600)"
fi

if [[ ${WITH_API} -eq 1 ]]; then
    if [[ -d "${VPSMGR_REPO_ROOT}/api" ]]; then
        # Python venv with uvicorn + fastapi.
        VENV="/opt/vps-manager/venv"
        mkdir -p /opt/vps-manager
        python3 -m venv "${VENV}" 2>/dev/null || true
        "${VENV}/bin/pip" install --quiet fastapi uvicorn[standard] 2>/dev/null || true
        install -m 644 "${VPSMGR_REPO_ROOT}/systemd/vpsmgr-api.service" /etc/systemd/system/ 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now vpsmgr-api 2>/dev/null || true
        log_info "api service installed and started"
    fi
fi

log_info "bootstrap complete"
echo "vpsmgr bootstrap: OK"
exit 0

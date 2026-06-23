#!/usr/bin/env bash
# scripts/bootstrap.sh — one-shot server bootstrap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

UBUNTU_CODENAME=""

require_root
require_command apt-get
require_command lsb_release

UBUNTU_CODENAME=$(lsb_release -cs)

vpsmgr_log INFO "bootstrap started (Ubuntu ${UBUNTU_CODENAME})"

# ---------------------------------------------------------------------------
# Utility installers
# ---------------------------------------------------------------------------
install_base_utils() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        apt-transport-https ca-certificates curl gnupg lsb-release \
        software-properties-common wget jq openssl rsync gettext-base \
        coreutils tar gzip bzip2 xz-utils build-essential libssl-dev pkg-config \
        python3 python3-pip python3-venv python3-virtualenv \
        debian-keyring debian-archive-keyring || die_internal "failed to install base utilities"
    vpsmgr_log INFO "base utilities installed"
}

# ---------------------------------------------------------------------------
# Repository management
# ---------------------------------------------------------------------------
add_caddy_repo() {
    if [[ -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
        vpsmgr_log INFO "caddy repo already present"
        return 0
    fi
    curl -1sLf "https://dl.cloudsmith.io/public/caddy/${CADDY_APT_CHANNEL}/gpg.key" \
        | gpg --dearmor -o "/usr/share/keyrings/caddy-${CADDY_APT_CHANNEL}-archive-keyring.gpg"
    echo "deb [signed-by=/usr/share/keyrings/caddy-${CADDY_APT_CHANNEL}-archive-keyring.gpg] \
https://dl.cloudsmith.io/public/caddy/${CADDY_APT_CHANNEL}/deb/debian any-version main" \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    vpsmgr_log INFO "added caddy apt repo"
}

add_php_repo() {
    if [[ -f /etc/apt/sources.list.d/ondrej-ubuntu-php-noble.sources ]] || grep -Rq "ondrej" /etc/apt/sources.list.d/ 2>/dev/null; then
        vpsmgr_log INFO "php repo already present"
        return 0
    fi
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || die_internal "failed to add php ppa"
    vpsmgr_log INFO "added php ppa"
}

add_mariadb_repo() {
    if [[ -f /etc/apt/sources.list.d/mariadb.list ]] || [[ -f /etc/apt/sources.list.d/mariadb.sources ]]; then
        vpsmgr_log INFO "mariadb repo already present"
        return 0
    fi
    local setup
    setup=$(mktemp)
    curl -fsSL "${MARIADB_SETUP_URL}" -o "${setup}" || die_internal "failed to download mariadb repo setup"
    bash "${setup}" --skip-verify --mariadb-server-version=auto || die_internal "failed to run mariadb repo setup"
    rm -f "${setup}"
    vpsmgr_log INFO "added mariadb apt repo"
}

add_postgresql_repo() {
    if [[ -f /etc/apt/sources.list.d/pgdg.list ]]; then
        vpsmgr_log INFO "postgresql repo already present"
        return 0
    fi
    curl -fsSL "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
        | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] ${POSTGRESQL_APT_REPO} ${UBUNTU_CODENAME}-pgdg main" \
        | tee /etc/apt/sources.list.d/pgdg.list >/dev/null
    vpsmgr_log INFO "added postgresql apt repo"
}

# ---------------------------------------------------------------------------
# Version resolution helpers
# ---------------------------------------------------------------------------
detect_php_versions() {
    require_command apt-cache
    local pkgs versions current fallback
    pkgs=$(apt-cache search php-fpm 2>/dev/null | grep -E '^php[0-9]+\.[0-9]+-fpm' | awk '{print $1}')
    versions=$(echo "${pkgs}" | sed -E 's/^php([0-9]+\.[0-9]+)-fpm$/\1/' | sort -V | uniq)

    if [[ -z ${versions} ]]; then
        die_dependency "no php-fpm packages found in configured repositories"
    fi

    current=$(echo "${versions}" | tail -n1)
    fallback=$(echo "${versions}" | grep -F "$(echo "${current}" | awk -F. '{print $1"."($2-1)}')" | tail -n1)

    if [[ -z ${fallback} ]]; then
        fallback=$(echo "${versions}" | tail -n2 | head -n1)
    fi

    echo "{\"current\":\"${current}\",\"fallback\":\"${fallback}\"}"
}

# ---------------------------------------------------------------------------
# Component installers
# ---------------------------------------------------------------------------
install_caddy() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y caddy || die_internal "failed to install caddy"
    systemctl enable caddy || true
    vpsmgr_log INFO "caddy installed"
}

install_php() {
    export DEBIAN_FRONTEND=noninteractive
    local php_json
    php_json=$(detect_php_versions)
    local php_current php_fallback
    php_current=$(jq -r '.current' <<< "${php_json}")
    php_fallback=$(jq -r '.fallback' <<< "${php_json}")

    local version
    for version in "${php_current}" "${php_fallback}"; do
        apt-get install -y \
            "php${version}-fpm" "php${version}-cli" "php${version}-common" \
            "php${version}-mysql" "php${version}-pgsql" "php${version}-redis" \
            "php${version}-mbstring" "php${version}-xml" "php${version}-zip" \
            "php${version}-gd" "php${version}-intl" "php${version}-opcache" \
            "php${version}-curl" || die_internal "failed to install php ${version}"
        systemctl enable "php${version}-fpm" || true
    done

    vpsmgr_log INFO "php ${php_current} and fallback ${php_fallback} installed"
    # Persist resolution for later scripts.
    mkdir -p "$(dirname "${BOOTSTRAP_STATE}")"
    jq -n --arg current "${php_current}" --arg fallback "${php_fallback}" \
        --argjson installed '{"caddy":true,"mariadb":true,"postgresql":true}' \
        '{php:{current:$current,fallback:$fallback},installed:$installed,created_at:now}' \
        > "${BOOTSTRAP_STATE}"
    chmod 0644 "${BOOTSTRAP_STATE}"
}

install_mariadb() {
    export DEBIAN_FRONTEND=noninteractive
    if systemctl list-unit-files mariadb.service >/dev/null 2>&1; then
        vpsmgr_log INFO "mariadb already installed"
    else
        apt-get install -y mariadb-server mariadb-client || die_internal "failed to install mariadb"
    fi
    systemctl enable mariadb || true
    systemctl start mariadb || true
    vpsmgr_log INFO "mariadb installed"
}

install_postgresql() {
    export DEBIAN_FRONTEND=noninteractive
    if systemctl list-unit-files postgresql.service >/dev/null 2>&1; then
        vpsmgr_log INFO "postgresql already installed"
    else
        apt-get install -y postgresql postgresql-client || die_internal "failed to install postgresql"
    fi
    systemctl enable postgresql || true
    systemctl start postgresql || true
    vpsmgr_log INFO "postgresql installed"
}

install_valkey() {
    if [[ -x /usr/local/bin/valkey-server ]]; then
        vpsmgr_log INFO "valkey already installed"
    else
        local release_json tag tarball tmpdir
        release_json=$(curl -fsSL "https://api.github.com/repos/${VALKEY_GITHUB_REPO}/releases/latest")
        tag=$(jq -er '.tag_name' <<< "${release_json}")
        tarball="https://github.com/${VALKEY_GITHUB_REPO}/archive/refs/tags/${tag}.tar.gz"
        tmpdir=$(mktemp -d)
        curl -fsSL "${tarball}" | tar -xz -C "${tmpdir}" --strip-components=1
        (cd "${tmpdir}" && make BUILD_TLS=yes MALLOC=libc && make install)
        rm -rf "${tmpdir}"
    fi

    id -u valkey >/dev/null 2>&1 || useradd -r -s /bin/false -M -d /var/lib/valkey valkey
    mkdir -p /var/lib/valkey /etc/valkey /var/log/valkey
    chown -R valkey:valkey /var/lib/valkey /var/log/valkey

    if [[ ! -f /etc/valkey/valkey.conf ]]; then
        curl -fsSL "https://raw.githubusercontent.com/${VALKEY_GITHUB_REPO}/refs/heads/unstable/valkey.conf" \
            -o /etc/valkey/valkey.conf 2>/dev/null || true
    fi
    if [[ -f /etc/valkey/valkey.conf ]]; then
        sed -i -E 's/^[#[:space:]]*(bind\s+).*/bind 127.0.0.1 ::1/' /etc/valkey/valkey.conf || true
        sed -i -E 's/^[#[:space:]]*(supervised\s+).*/supervised systemd/' /etc/valkey/valkey.conf || true
        sed -i -E 's/^[#[:space:]]*(dir\s+).*/dir \/var\/lib\/valkey/' /etc/valkey/valkey.conf || true
        chown root:valkey /etc/valkey/valkey.conf
        chmod 0640 /etc/valkey/valkey.conf
    fi

    cat > /etc/systemd/system/valkey.service <<'EOF'
[Unit]
Description=Valkey in-memory key-value store
After=network.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/local/bin/valkey-server /etc/valkey/valkey.conf
ExecStop=/usr/local/bin/valkey-cli shutdown
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemd_reload
    systemctl enable valkey || true
    systemctl restart valkey || die_internal "failed to start valkey"
    vpsmgr_log INFO "valkey installed and started"
}

install_wpcli() {
    if [[ -x /usr/local/bin/wp ]]; then
        vpsmgr_log INFO "wp-cli already installed"
        return 0
    fi
    local release_json phar
    release_json=$(curl -fsSL "https://api.github.com/repos/${WPCLI_GITHUB_REPO}/releases/latest")
    phar=$(jq -er '.assets[] | select(.name=="wp-cli.phar") | .browser_download_url' <<< "${release_json}")
    curl -fsSL "${phar}" -o /usr/local/bin/wp || die_internal "failed to download wp-cli"
    chmod +x /usr/local/bin/wp
    vpsmgr_log INFO "wp-cli installed"
}

# ---------------------------------------------------------------------------
# API installation
# ---------------------------------------------------------------------------
setup_api_user() {
    if ! id -u "${API_USER}" >/dev/null 2>&1; then
        useradd -r -d "${API_HOME}" -s /bin/false -M "${API_USER}" || die_internal "failed to create api user"
    fi
    mkdir -p "${API_HOME}"
    chown "${API_USER}:${API_USER}" "${API_HOME}"
}

install_python_api() {
    setup_api_user
    local target="/opt/vpsmgr"
    mkdir -p "${target}"
    # Copy the entire project tree so scripts, templates and config are present.
    rsync -a --delete "${VPSMGR_ROOT}/" "${target}/" || die_internal "failed to copy project to ${target}"

    mkdir -p "${API_VENV}"
    python3 -m venv "${API_VENV}" || die_internal "failed to create api venv"
    "${API_VENV}/bin/pip" install --upgrade pip setuptools wheel || die_internal "pip upgrade failed"
    "${API_VENV}/bin/pip" install fastapi uvicorn[standard] pydantic jinja2 python-multipart || die_internal "pip install failed"

    # Runtime config will be used by installed scripts.
    mkdir -p /etc/vpsmgr
    cp "${target}/config/vpsmgr.conf" /etc/vpsmgr/vpsmgr.conf
    chown root:root /etc/vpsmgr/vpsmgr.conf
    chmod 0644 /etc/vpsmgr/vpsmgr.conf

    # Allow the API user to run vpsmgr scripts as root without a password.
    cat > /etc/sudoers.d/vpsmgr-api <<EOF
Defaults:vpsmgr-api !requiretty
vpsmgr-api ALL=(root) NOPASSWD: ${target}/scripts/*.sh
EOF
    chmod 0440 /etc/sudoers.d/vpsmgr-api
    visudo -c || die_internal "sudoers file check failed"

    cat > /etc/systemd/system/vpsmgr-api.service <<EOF
[Unit]
Description=VPS Manager API
After=network.target

[Service]
Type=simple
User=${API_USER}
Group=${API_USER}
WorkingDirectory=${target}/api
Environment=VPSMGR_ROOT=${target}
EnvironmentFile=-/etc/vpsmgr/vpsmgr.env
ExecStart=${API_VENV}/bin/uvicorn main:app --host ${API_BIND_HOST} --port ${API_BIND_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemd_reload
    systemctl enable vpsmgr-api || true
    vpsmgr_log INFO "API installed"
}

install_backup_timer() {
    cat > /etc/systemd/system/vpsmgr-backup-prune.service <<'EOF'
[Unit]
Description=VPS Manager backup retention pruning

[Service]
Type=oneshot
ExecStart=/opt/vpsmgr/scripts/backup.sh --prune
EOF
    cat > /etc/systemd/system/vpsmgr-backup-prune.timer <<'EOF'
[Unit]
Description=Run VPS Manager backup pruning daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemd_reload
    systemctl enable vpsmgr-backup-prune.timer || true
    systemctl start vpsmgr-backup-prune.timer || true
    vpsmgr_log INFO "backup prune timer installed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    install_base_utils
    add_caddy_repo
    add_php_repo
    add_mariadb_repo
    add_postgresql_repo
    apt-get update
    install_caddy
    install_php
    install_mariadb
    install_postgresql
    install_valkey
    install_wpcli
    install_python_api
    install_backup_timer

    # Ensure the global Caddyfile imports site configs.
    # shellcheck source=lib/caddy.sh
    source "${SCRIPT_DIR}/lib/caddy.sh"
    caddy_ensure_global_config
    caddy_reload

    vpsmgr_log INFO "bootstrap completed"
    echo "Bootstrap complete."
    echo "Set VPSMGR_API_TOKEN, then run: systemctl enable --now vpsmgr-api"
}

main "$@"

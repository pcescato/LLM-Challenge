#!/usr/bin/env bash
# db.sh — Database management functions (MariaDB + PostgreSQL)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- MariaDB ---

mariadb_install() {
    log_info "Installing MariaDB server..."

    if command -v mariadb &>/dev/null; then
        log_info "MariaDB already installed"
        return 0
    fi

    apt-get update -qq
    apt-get install -y -qq apt-transport-https curl 2>/dev/null

    curl -fsSL "${MARIADB_KEY_URL}" | gpg --dearmor -o "${MARIADB_KEYRING}" 2>/dev/null
    echo "${MARIADB_REPO}" | tee /etc/apt/sources.list.d/mariadb.list > /dev/null

    apt-get update -qq

    # Pre-configure: no root password prompt during install
    debconf-set-selections <<< "mariadb-server-10.0 mysql-server/root_password password ''"
    debconf-set-selections <<< "mariadb-server-10.0 mysql-server/root_password_again password ''"

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server

    # Secure the installation
    mysql -u root <<'EOSQL' 2>/dev/null || true
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL

    log_info "MariaDB installed and secured"
}

mariadb_database_exists() {
    local db_name="$1"
    local count
    count=$(mariadb -N -e "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db_name}';" 2>/dev/null || echo "0")
    [[ "${count}" -gt 0 ]]
}

mariadb_user_exists() {
    local db_user="$1"
    local count
    count=$(mariadb -N -e "SELECT COUNT(*) FROM mysql.user WHERE User='${db_user}';" 2>/dev/null || echo "0")
    [[ "${count}" -gt 0 ]]
}

mariadb_create_database() {
    local db_name="$1"
    local db_user="$2"

    if mariadb_database_exists "${db_name}"; then
        log_warn "MariaDB database '${db_name}' already exists"
    else
        mariadb -e "CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
        log_info "MariaDB database created: ${db_name}"
    fi

    if mariadb_user_exists "${db_user}"; then
        log_warn "MariaDB user '${db_user}' already exists"
    else
        local db_pass
        db_pass=$(generate_password 32)
        mariadb -e "CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';" 2>/dev/null
        mariadb -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';" 2>/dev/null
        mariadb -e "FLUSH PRIVILEGES;" 2>/dev/null
        log_info "MariaDB user created: ${db_user}"

        emit_credentials "DB_NAME=${db_name} DB_USER=${db_user} DB_PASSWORD=${db_pass} DB_HOST=localhost DB_ENGINE=mariadb" ""
    fi
}

mariadb_delete_database() {
    local db_name="$1"
    local db_user="$2"

    if mariadb_user_exists "${db_user}"; then
        mariadb -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null
        log_info "MariaDB user dropped: ${db_user}"
    fi

    if mariadb_database_exists "${db_name}"; then
        mariadb -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null
        log_info "MariaDB database dropped: ${db_name}"
    fi
}

mariadb_status() {
    if systemctl is-active --quiet mariadb 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

# --- PostgreSQL ---

postgresql_detect_latest() {
    apt-get update -qq 2>/dev/null
    local latest
    latest=$(apt-cache search '^postgresql-[0-9]+$' 2>/dev/null | grep -oP '\d+' | sort -Vr | head -1)
    echo "${latest}"
}

postgresql_install() {
    local version="${1:-}"
    if [[ -z "${version}" ]]; then
        version=$(postgresql_detect_latest)
    fi

    log_info "Installing PostgreSQL ${version}..."

    if dpkg -l "postgresql-${version}" &>/dev/null; then
        log_info "PostgreSQL ${version} already installed"
        echo "${version}"
        return 0
    fi

    apt-get update -qq
    apt-get install -y -qq curl ca-certificates 2>/dev/null

    curl -fsSL "${PGDG_KEY_URL}" | gpg --dearmor -o "${PGDG_KEYRING}" 2>/dev/null

    local codename
    codename=$(lsb_release -cs)
    local repo_line="deb [signed-by=${PGDG_KEYRING}] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main"
    echo "${repo_line}" | tee /etc/apt/sources.list.d/pgdg.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq "postgresql-${version}" "postgresql-contrib-${version}"

    log_info "PostgreSQL ${version} installed"
    echo "${version}"
}

postgresql_database_exists() {
    local db_name="$1"
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';" 2>/dev/null | grep -q 1
}

postgresql_role_exists() {
    local db_user="$1"
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${db_user}';" 2>/dev/null | grep -q 1
}

postgresql_create_database() {
    local db_name="$1"
    local db_user="$2"

    if postgresql_database_exists "${db_name}"; then
        log_warn "PostgreSQL database '${db_name}' already exists"
    else
        sudo -u postgres createdb "${db_name}" 2>/dev/null
        log_info "PostgreSQL database created: ${db_name}"
    fi

    if postgresql_role_exists "${db_user}"; then
        log_warn "PostgreSQL role '${db_user}' already exists"
    else
        local db_pass
        db_pass=$(generate_password 32)
        sudo -u postgres psql -c "CREATE ROLE \"${db_user}\" WITH LOGIN PASSWORD '${db_pass}';" 2>/dev/null
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${db_name}\" TO \"${db_user}\";" 2>/dev/null
        sudo -u postgres psql -d "${db_name}" -c "GRANT ALL ON SCHEMA public TO \"${db_user}\";" 2>/dev/null
        log_info "PostgreSQL user created: ${db_user}"

        emit_credentials "DB_NAME=${db_name} DB_USER=${db_user} DB_PASSWORD=${db_pass} DB_HOST=localhost DB_PORT=5432 DB_ENGINE=postgresql" ""
    fi
}

postgresql_delete_database() {
    local db_name="$1"
    local db_user="$2"

    if postgresql_role_exists "${db_user}"; then
        # Revoke and disconnect before dropping
        sudo -u postgres psql -c "REVOKE ALL ON DATABASE \"${db_name}\" FROM \"${db_user}\";" 2>/dev/null || true
        sudo -u postgres psql -c "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname='${db_name}' AND pid <> pg_backend_pid();" 2>/dev/null || true
        sudo -u postgres psql -c "DROP ROLE IF EXISTS \"${db_user}\";" 2>/dev/null
        log_info "PostgreSQL role dropped: ${db_user}"
    fi

    if postgresql_database_exists "${db_name}"; then
        sudo -u postgres dropdb "${db_name}" 2>/dev/null
        log_info "PostgreSQL database dropped: ${db_name}"
    fi
}

postgresql_status() {
    local version="${1:-}"
    local service_name
    if [[ -n "${version}" ]]; then
        service_name="postgresql@${version}-main"
    else
        # Find running postgresql instance
        service_name=$(systemctl list-units --type=service --state=active 'postgresql*' --no-legend 2>/dev/null | awk '{print $1}' | head -1)
    fi
    if [[ -n "${service_name}" ]] && systemctl is-active --quiet "${service_name}" 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}
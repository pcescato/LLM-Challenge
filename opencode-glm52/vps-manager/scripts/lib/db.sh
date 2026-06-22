#!/usr/bin/env bash
# lib/db.sh — database (MariaDB / PostgreSQL) user + database lifecycle.
# No passwords are ever persisted. Caller receives credentials via stdout
# wrapped in <<<CREDENTIALS>>> markers (D1).
# Relies on lib/common.sh (already sourced by caller).

# --- Engine availability ---------------------------------------------------
db_engine_available() {
    local engine="$1"
    local e
    local IFS=','
    for e in ${VPSMGR_DB_ENGINES}; do
        [[ "${e}" == "${engine}" ]] && return 0
    done
    return 1
}

db_engine_running() {
    local engine="$1"
    case "${engine}" in
        mariadb|mysql)
            systemctl is-active --quiet mariadb 2>/dev/null \
                || systemctl is-active --quiet mysql 2>/dev/null
            ;;
        postgresql|postgres)
            systemctl is-active --quiet postgresql 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# --- MariaDB helpers -------------------------------------------------------
_mariadb_exec() {
    # Runs as root via unix_socket auth (installed by bootstrap).
    mariadb --protocol=socket -uroot "$@"
}

_mariadb_db_exists() {
    local db="$1"
    _mariadb_exec -sN -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}';" 2>/dev/null \
        | grep -qx "${db}"
}

_mariadb_user_exists() {
    local user="$1"
    _mariadb_exec -sN -e "SELECT COUNT(*) FROM mysql.user WHERE User='${user}';" 2>/dev/null \
        | grep -qx "1"
}

# _mariadb_create <db_name> <db_user> <db_pass>
_mariadb_create() {
    local db="$1" user="$2" pass="$3"
    _mariadb_exec <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';
ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

_mariadb_drop_db() {
    local db="$1" user="$2"
    _mariadb_exec -e "DROP DATABASE IF EXISTS \`${db}\`;" 2>/dev/null
    _mariadb_exec -e "DROP USER IF EXISTS '${user}'@'localhost';" 2>/dev/null
}

# --- PostgreSQL helpers ----------------------------------------------------
_pg_exec() {
    sudo -u postgres psql -v ON_ERROR_STOP=1 "$@"
}

_pg_db_exists() {
    local db="$1"
    _pg_exec -tAc "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null | grep -qx 1
}

_pg_user_exists() {
    local user="$1"
    _pg_exec -tAc "SELECT 1 FROM pg_roles WHERE rolname='${user}';" 2>/dev/null | grep -qx 1
}

# _pg_create <db_name> <db_user> <db_pass>
_pg_create() {
    local db="$1" user="$2" pass="$3"
    _pg_exec -c "CREATE USER \"${user}\" WITH PASSWORD '${pass}';" 2>/dev/null \
        || _pg_exec -c "ALTER USER \"${user}\" WITH PASSWORD '${pass}';" 2>/dev/null
    _pg_exec -c "CREATE DATABASE \"${db}\" OWNER \"${user}\";" 2>/dev/null \
        || _pg_exec -c "ALTER DATABASE \"${db}\" OWNER TO \"${user}\";" 2>/dev/null
}

_pg_drop_db() {
    local db="$1" user="$2"
    _pg_exec -c "DROP DATABASE IF EXISTS \"${db}\";" 2>/dev/null || true
    _pg_exec -c "DROP USER IF EXISTS \"${user}\";" 2>/dev/null || true
}

# --- Public API ------------------------------------------------------------

# db_create <engine> <db_name> <db_user>
# Echoes generated password to stdout (NOT to logs). Caller prints with markers.
db_create() {
    local engine="$1" db="$2" user="$3"
    if ! db_engine_available "${engine}"; then
        die "${E_USAGE}" "unsupported db engine: ${engine}"
    fi
    if ! db_engine_running "${engine}"; then
        die "${E_DEP}" "db engine not running: ${engine}"
    fi
    local pass
    pass="$(gen_password 32)"
    case "${engine}" in
        mariadb|mysql)
            _mariadb_create "${db}" "${user}" "${pass}"
            ;;
        postgresql|postgres)
            _pg_create "${db}" "${user}" "${pass}"
            ;;
    esac
    # Return the password to caller via stdout ONLY.
    echo "${pass}"
    log_info "database created: engine=${engine} db=${db} user=${user}"
}

# db_drop <engine> <db_name> <db_user>
db_drop() {
    local engine="$1" db="$2" user="$3"
    case "${engine}" in
        mariadb|mysql)
            _mariadb_drop_db "${db}" "${user}"
            ;;
        postgresql|postgres)
            _pg_drop_db "${db}" "${user}"
            ;;
    esac
    log_info "database dropped: engine=${engine} db=${db} user=${user}"
}

# Dump a database to stdout (for backups). Returns non-zero on failure.
db_dump() {
    local engine="$1" db="$2"
    case "${engine}" in
        mariadb|mysql)
            _mariadb_exec --single-transaction "${db}" 2>/dev/null
            ;;
        postgresql|postgres)
            sudo -u postgres pg_dump --no-owner --no-acl "${db}" 2>/dev/null
            ;;
    esac
}

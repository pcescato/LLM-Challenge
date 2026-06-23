#!/usr/bin/env bash
# scripts/lib/db.sh — MariaDB / PostgreSQL helpers.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

db_validate_engine() {
    case "${1:-}" in
        mariadb|postgres) ;;
        *) die_input "invalid database engine: ${1:-} (expected mariadb or postgres)" ;;
    esac
}

db_create() {
    local engine="$1"
    local domain="$2"
    local db_user_var="$3"
    local db_pass_var="$4"
    db_validate_engine "${engine}"

    local db_name db_user db_pass
    db_name=$(domain_to_db_name "${domain}" "${engine}")
    db_user=$(domain_to_db_user "${domain}" "${engine}")
    db_pass=$(generate_password 32)

    case "${engine}" in
        mariadb)
            require_command mysql
            mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\`;" || die_internal "failed to create mariadb database"
            mysql -u root -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';" || die_internal "failed to create mariadb user"
            mysql -u root -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';" || die_internal "failed to grant mariadb privileges"
            mysql -u root -e "FLUSH PRIVILEGES;" || die_internal "failed to flush mariadb privileges"
            ;;
        postgres)
            require_command psql
            # Use the postgres system user; role cannot exist already.
            if sudo -u postgres psql -Atc "SELECT 1 FROM pg_database WHERE datname='${db_name}';" | grep -q 1; then
                die_conflict "postgres database already exists: ${db_name}"
            fi
            sudo -u postgres psql -c "CREATE DATABASE \"${db_name}\";" || die_internal "failed to create postgres database"
            sudo -u postgres psql -c "CREATE USER \"${db_user}\" WITH PASSWORD '${db_pass}';" || die_internal "failed to create postgres user"
            sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${db_name}\" TO \"${db_user}\";" || die_internal "failed to grant postgres privileges"
            ;;
    esac

    printf -v "${db_user_var}" '%s' "${db_user}"
    printf -v "${db_pass_var}" '%s' "${db_pass}"
    vpsmgr_log INFO "created ${engine} database and user for ${domain}"
}

db_drop() {
    local engine="$1"
    local db_name="$2"
    local db_user="$3"
    db_validate_engine "${engine}"

    case "${engine}" in
        mariadb)
            require_command mysql
            mysql -u root -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null || true
            mysql -u root -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null || true
            ;;
        postgres)
            require_command psql
            sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"${db_name}\";" 2>/dev/null || true
            sudo -u postgres psql -c "DROP USER IF EXISTS \"${db_user}\";" 2>/dev/null || true
            ;;
    esac
    vpsmgr_log INFO "dropped ${engine} database ${db_name}"
}

db_dump() {
    local engine="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local target="$5"
    db_validate_engine "${engine}"

    case "${engine}" in
        mariadb)
            require_command mysqldump
            MYSQL_PWD="${db_pass}" mysqldump -u "${db_user}" --single-transaction --quick "${db_name}" > "${target}"
            ;;
        postgres)
            require_command pg_dump
            PGPASSWORD="${db_pass}" pg_dump -U "${db_user}" -d "${db_name}" -f "${target}"
            ;;
    esac
}

db_exists() {
    local engine="$1"
    local db_name="$2"
    db_validate_engine "${engine}"

    case "${engine}" in
        mariadb)
            require_command mysql
            mysql -u root -e "USE \`${db_name}\`;" >/dev/null 2>&1
            ;;
        postgres)
            require_command psql
            sudo -u postgres psql -Atc "SELECT 1 FROM pg_database WHERE datname='${db_name}';" | grep -q 1
            ;;
    esac
}

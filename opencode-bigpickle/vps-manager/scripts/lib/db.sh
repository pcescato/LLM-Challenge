#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DB_ROOT_USER="${db_root_user:-root}"
DB_ROOT_PASS="${db_root_password:-}"

db_mysql_cmd() {
    if [[ -n "$DB_ROOT_PASS" ]]; then
        mysql -u"$DB_ROOT_USER" -p"$DB_ROOT_PASS" -e "$*" 2>/dev/null
    else
        mysql -u"$DB_ROOT_USER" -e "$*" 2>/dev/null
    fi
}

db_install_mariadb() {
    ensure_root
    if command -v mariadb &>/dev/null || command -v mysql &>/dev/null; then
        info "MariaDB/MySQL already installed"
        return 0
    fi
    apt-get update -qq
    apt-get install -y -qq mariadb-server mariadb-client
    systemctl enable mariadb
    systemctl start mariadb
    info "MariaDB installed"
}

db_create() {
    local db_name="$1" db_user="$2"
    local db_pass
    db_pass="$(openssl rand -base64 24)"
    db_mysql_cmd "CREATE DATABASE IF NOT EXISTS \`${db_name}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    db_mysql_cmd "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    db_mysql_cmd "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    db_mysql_cmd "FLUSH PRIVILEGES;"
    info "Database ${db_name} created for user ${db_user}"
    echo "$db_pass"
}

db_drop() {
    local db_name="$1" db_user="$2"
    db_mysql_cmd "DROP DATABASE IF EXISTS \`${db_name}\`;"
    db_mysql_cmd "DROP USER IF EXISTS '${db_user}'@'localhost';"
    db_mysql_cmd "FLUSH PRIVILEGES;"
    info "Database ${db_name} and user ${db_user} dropped"
}

db_dump() {
    local db_name="$1" outfile="$2"
    if [[ -n "$DB_ROOT_PASS" ]]; then
        mysqldump -u"$DB_ROOT_USER" -p"$DB_ROOT_PASS" "$db_name" > "$outfile" 2>/dev/null
    else
        mysqldump -u"$DB_ROOT_USER" "$db_name" > "$outfile" 2>/dev/null
    fi
    info "Database ${db_name} dumped to ${outfile}"
}

db_restore() {
    local db_name="$1" infile="$2"
    if [[ -n "$DB_ROOT_PASS" ]]; then
        mysql -u"$DB_ROOT_USER" -p"$DB_ROOT_PASS" "$db_name" < "$infile" 2>/dev/null
    else
        mysql -u"$DB_ROOT_USER" "$db_name" < "$infile" 2>/dev/null
    fi
    info "Database ${db_name} restored from ${infile}"
}

db_list_databases() {
    db_mysql_cmd "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys');" | tail -n +2
}

db_sanitize_name() {
    local prefix="$1" domain="$2"
    local sanitized
    sanitized="${domain//[^a-zA-Z0-9]/_}"
    sanitized="${sanitized:0:16}"
    echo "${prefix}${sanitized}"
}

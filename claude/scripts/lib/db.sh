#!/bin/bash
# Database management library (MariaDB / PostgreSQL)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Detect available database systems
detect_mariadb_version() {
    # Query available MariaDB server versions from repository
    apt-cache search --names-only "^mariadb-server" 2>/dev/null | \
        grep -oE '[0-9]+\.[0-9]+' | \
        sort -rV | \
        head -1
}

detect_postgres_version() {
    # Query available PostgreSQL versions from repository
    apt-cache search --names-only "^postgresql-[0-9]+" 2>/dev/null | \
        grep -oE 'postgresql-[0-9]+' | \
        sed 's/postgresql-//' | \
        sort -rV | \
        head -1
}

# Install MariaDB server
install_mariadb() {
    if is_package_installed "mariadb-server"; then
        log_debug "MariaDB already installed"
        return 0
    fi

    log_info "Installing MariaDB server..."

    # Add MariaDB official repository
    if [[ ! -f /etc/apt/sources.list.d/mariadb.sources ]]; then
        apt-get install -y -qq software-properties-common curl gpg >/dev/null 2>&1 || true

        # Download and add MariaDB repository
        curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc | gpg --dearmor -o /usr/share/keyrings/mariadb-archive-keyring.gpg 2>/dev/null || {
            log_warn "Could not fetch MariaDB GPG key, using system packages"
        }
    fi

    # Set root password to random (generated in memory, not stored)
    local root_pass
    root_pass=$(gen_password 24)

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        mariadb-server \
        mariadb-client \
        >/dev/null 2>&1 || {
        log_error "Failed to install MariaDB"
        return $E_INTERNAL
    }

    # Initialize database
    systemctl enable mariadb 2>/dev/null || true
    systemctl start mariadb || {
        log_error "Failed to start MariaDB"
        return $E_INTERNAL
    }

    # Secure installation: set root password
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pass}';" 2>/dev/null || {
        log_error "Failed to secure MariaDB installation"
        return $E_INTERNAL
    }

    log_info "MariaDB installed successfully"
    # Password printed by caller if needed
    echo "$root_pass"
}

# Install PostgreSQL server
install_postgres() {
    if is_package_installed "postgresql"; then
        log_debug "PostgreSQL already installed"
        return 0
    fi

    log_info "Installing PostgreSQL server..."

    # Add PostgreSQL official repository
    if [[ ! -f /usr/share/keyrings/postgresql-archive-keyring.gpg ]]; then
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg 2>/dev/null || {
            log_warn "Could not fetch PostgreSQL GPG key"
        }
    fi

    apt-get update -qq
    apt-get install -y -qq \
        postgresql \
        postgresql-contrib \
        >/dev/null 2>&1 || {
        log_error "Failed to install PostgreSQL"
        return $E_INTERNAL
    }

    systemctl enable postgresql 2>/dev/null || true
    systemctl start postgresql || {
        log_error "Failed to start PostgreSQL"
        return $E_INTERNAL
    }

    log_info "PostgreSQL installed successfully"
}

# Create a database and user
# Usage: create_database <engine> <db_name> <username>
# Returns: password on stdout (printed once, not stored)
create_database() {
    local engine="$1"
    local db_name="$2"
    local username="$3"
    local password
    password=$(gen_password 24)

    log_info "Creating $engine database: $db_name"

    case "$engine" in
        mariadb)
            # Connect as root (no password in init, or use socket auth)
            mysql -u root << EOF
CREATE DATABASE IF NOT EXISTS \`${db_name}\`;
CREATE USER IF NOT EXISTS '${username}'@'localhost' IDENTIFIED BY '${password}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${username}'@'localhost';
FLUSH PRIVILEGES;
EOF
            [[ $? -eq 0 ]] || {
                log_error "Failed to create MariaDB database"
                return $E_INTERNAL
            }
            ;;
        postgresql)
            sudo -u postgres psql << EOF
CREATE DATABASE "${db_name}";
CREATE USER "${username}" WITH PASSWORD '${password}';
ALTER DATABASE "${db_name}" OWNER TO "${username}";
GRANT ALL PRIVILEGES ON DATABASE "${db_name}" TO "${username}";
EOF
            [[ $? -eq 0 ]] || {
                log_error "Failed to create PostgreSQL database"
                return $E_INTERNAL
            }
            ;;
        *)
            log_error "Unsupported database engine: $engine"
            return $E_USAGE
            ;;
    esac

    log_info "Database created: $db_name (user: $username)"
    # Print credentials once, wrapped in markers (design decision D1)
    echo "<<<CREDENTIALS>>>"
    echo "Engine: $engine"
    echo "Database: $db_name"
    echo "Username: $username"
    echo "Password: $password"
    echo "<<<CREDENTIALS>>>"
}

# Delete a database and user
delete_database() {
    local engine="$1"
    local db_name="$2"
    local username="$3"

    log_info "Deleting $engine database: $db_name"

    case "$engine" in
        mariadb)
            mysql -u root << EOF
DROP DATABASE IF EXISTS \`${db_name}\`;
DROP USER IF EXISTS '${username}'@'localhost';
FLUSH PRIVILEGES;
EOF
            [[ $? -eq 0 ]] || {
                log_warn "Could not fully clean up MariaDB database"
                return 0  # Don't fail on cleanup
            }
            ;;
        postgresql)
            sudo -u postgres psql << EOF
DROP DATABASE IF EXISTS "${db_name}";
DROP USER IF EXISTS "${username}";
EOF
            [[ $? -eq 0 ]] || {
                log_warn "Could not fully clean up PostgreSQL database"
                return 0  # Don't fail on cleanup
            }
            ;;
    esac

    log_info "Database deleted: $db_name"
}

# Verify database connection
test_db_connection() {
    local engine="$1"
    local db_name="$2"
    local username="$3"
    local password="$4"

    case "$engine" in
        mariadb)
            mysql -u "$username" -p"$password" -D "$db_name" -e "SELECT 1;" 2>/dev/null >/dev/null || {
                return 1
            }
            ;;
        postgresql)
            PGPASSWORD="$password" psql -U "$username" -d "$db_name" -c "SELECT 1;" 2>/dev/null >/dev/null || {
                return 1
            }
            ;;
        *)
            return 1
            ;;
    esac

    return 0
}

# Get database user from state
get_database_user() {
    local domain="$1"
    local db_name="$2"

    domain=$(normalize_domain "$domain") || return 1

    # For now, derive from domain: ex_example_com -> ex_${db_name}
    # This is a simple convention; state stores the actual mapping
    printf "ex_%s" "${db_name}"
}

# Check if database exists
database_exists() {
    local engine="$1"
    local db_name="$2"

    case "$engine" in
        mariadb)
            mysql -u root -e "USE \`${db_name}\`;" 2>/dev/null >/dev/null
            ;;
        postgresql)
            sudo -u postgres psql -lqt | cut -d '|' -f 1 | grep -qw "$db_name"
            ;;
        *)
            return 1
            ;;
    esac
}

# Export database backup
export_database() {
    local engine="$1"
    local db_name="$2"
    local output_file="$3"

    log_info "Exporting $engine database: $db_name"

    case "$engine" in
        mariadb)
            mysqldump -u root "$db_name" > "$output_file" 2>/dev/null || {
                log_error "Failed to export MariaDB database"
                return $E_INTERNAL
            }
            ;;
        postgresql)
            sudo -u postgres pg_dump "$db_name" > "$output_file" 2>/dev/null || {
                log_error "Failed to export PostgreSQL database"
                return $E_INTERNAL
            }
            ;;
        *)
            log_error "Unsupported database engine: $engine"
            return $E_USAGE
            ;;
    esac

    chmod 600 "$output_file"
    log_debug "Database exported: $output_file"
}

# Import database backup
import_database() {
    local engine="$1"
    local db_name="$2"
    local input_file="$3"

    if [[ ! -f "$input_file" ]]; then
        log_error "Backup file not found: $input_file"
        return $E_NOTFOUND
    fi

    log_info "Importing $engine database: $db_name"

    case "$engine" in
        mariadb)
            mysql -u root "$db_name" < "$input_file" 2>/dev/null || {
                log_error "Failed to import MariaDB database"
                return $E_INTERNAL
            }
            ;;
        postgresql)
            sudo -u postgres psql "$db_name" < "$input_file" 2>/dev/null || {
                log_error "Failed to import PostgreSQL database"
                return $E_INTERNAL
            }
            ;;
        *)
            log_error "Unsupported database engine: $engine"
            return $E_USAGE
            ;;
    esac

    log_info "Database imported: $db_name"
}

export -f detect_mariadb_version detect_postgres_version install_mariadb install_postgres
export -f create_database delete_database test_db_connection get_database_user database_exists
export -f export_database import_database

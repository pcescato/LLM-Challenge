#!/bin/bash
# VPS Manager — Common utilities library
set -euo pipefail

# Source configuration if available
if [[ -f /etc/vpsmgr/vpsmgr.conf ]]; then
    source /etc/vpsmgr/vpsmgr.conf
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../../config/vpsmgr.conf" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../../config/vpsmgr.conf"
fi

# Exit codes (API mapping documented in architecture)
readonly E_OK=0
readonly E_USAGE=1
readonly E_NOTFOUND=2
readonly E_EXISTS=3
readonly E_MISSING_DEP=4
readonly E_INTERNAL=5

# Logging to file and stderr
log() {
    local level="$1"
    shift
    local msg="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local logfile="${LOG_DIR:-/var/log/vpsmgr}/vpsmgr.log"

    mkdir -p "${LOG_DIR:-/var/log/vpsmgr}"
    echo "[${timestamp}] [${level}] ${msg}" >> "$logfile" 2>/dev/null || true
    echo "[${level}] ${msg}" >&2
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        log "DEBUG" "$@"
    fi
}

# Redact sensitive patterns from output
redact_credentials() {
    local text="$1"
    # Redact common credential patterns
    echo "$text" | sed -E \
        -e 's/(password|passwd)=([^ "'"'"']+)/"password"=***/gi' \
        -e 's/(MARIADB_ROOT_PASSWORD|DB_PASSWORD)=([^ "'"'"']+)/\1=***/g' \
        -e 's/(mysql_password|db_password)=([^ "'"'"']+)/"mysql_password"=***/gi'
}

# Idempotency check — exit 0 if target already exists in desired state
is_idempotent_ok() {
    local check_cmd="$1"
    if eval "$check_cmd" &>/dev/null; then
        return 0
    fi
    return 1
}

# Ensure running as root
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit $E_USAGE
    fi
}

# Ensure dependency is available
require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        exit $E_MISSING_DEP
    fi
}

# Check if a package is installed
is_package_installed() {
    local pkg="$1"
    dpkg -l | grep -q "^ii  $pkg " 2>/dev/null || return 1
}

# Install a package if not present
ensure_package() {
    local pkg="$1"
    if ! is_package_installed "$pkg"; then
        log_info "Installing $pkg..."
        apt-get update -qq
        apt-get install -y -qq "$pkg" >/dev/null 2>&1
    fi
}

# Normalize domain (lowercase, strip www., validate)
normalize_domain() {
    local domain="$1"
    domain="${domain,,}"  # lowercase
    domain="${domain#www\.}"  # strip leading www.

    # Validate DNS label format
    if ! [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
        log_error "Invalid domain: $domain"
        return 1
    fi
    echo "$domain"
}

# Generate SFTP username from domain: example.com -> ex_example_com
make_sftp_username() {
    local domain="$1"
    domain=$(normalize_domain "$domain") || return 1

    # First 2 chars of each label, then underscore-joined labels (truncated)
    # example.com -> ex_example_com
    local parts=(${domain//./ })
    local prefix="${parts[0]:0:2}"  # first 2 chars of domain
    local sanitized="${domain//./_}"  # dots -> underscores

    # Truncate to 32 chars (Linux username limit)
    printf "%.32s" "${prefix}_${sanitized}"
}

# Read state JSON for a site
get_state_file() {
    local domain="$1"
    domain=$(normalize_domain "$domain") || return 1
    echo "${STATE_DIR}/${domain}.json"
}

# Check if site exists (state file present)
site_exists() {
    local domain="$1"
    local state_file
    state_file=$(get_state_file "$domain") || return 1
    [[ -f "$state_file" ]]
}

# Read single field from site state JSON
read_state() {
    local domain="$1"
    local field="$2"
    local state_file
    state_file=$(get_state_file "$domain") || return 1

    if [[ ! -f "$state_file" ]]; then
        log_error "Site state not found: $domain"
        return $E_NOTFOUND
    fi

    jq -r ".${field} // empty" "$state_file" 2>/dev/null || true
}

# Write state JSON for a site
write_state() {
    local domain="$1"
    local state_json="$2"
    local state_file
    state_file=$(get_state_file "$domain") || return 1

    mkdir -p "$STATE_DIR"
    echo "$state_json" | jq . > "$state_file.tmp" 2>/dev/null
    mv "$state_file.tmp" "$state_file"
    chmod 600 "$state_file"
}

# List all sites (state files in state dir)
list_sites() {
    if [[ ! -d "$STATE_DIR" ]]; then
        echo "[]"
        return 0
    fi

    local sites_json="["
    local first=true
    for state_file in "$STATE_DIR"/*.json; do
        [[ -f "$state_file" ]] || continue
        if [[ "$first" == false ]]; then
            sites_json+=","
        fi
        sites_json+="$(cat "$state_file")"
        first=false
    done
    sites_json+="]"
    echo "$sites_json" | jq .
}

# Generate a random password (used for DB/SFTP credentials)
gen_password() {
    local length="${1:-16}"
    # Alphanumeric + safe special chars, no ambiguous chars (0/O, 1/l)
    tr -dc 'A-Za-z2-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length"
}

# Generate ISO8601 timestamp
iso_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Execute a command with timeout and capture exit code
run_with_timeout() {
    local timeout_sec="$1"
    shift
    local cmd="$@"

    timeout "$timeout_sec" bash -c "$cmd" || {
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_error "Command timed out after ${timeout_sec}s: $cmd"
            return $E_INTERNAL
        fi
        return $exit_code
    }
}

# Ensure a system user exists (for SFTP/services)
ensure_system_user() {
    local username="$1"
    local shell="${2:-/bin/bash}"

    if id "$username" &>/dev/null 2>&1; then
        log_debug "User already exists: $username"
        return 0
    fi

    useradd -m -s "$shell" "$username" || {
        log_error "Failed to create user: $username"
        return $E_INTERNAL
    }
}

# Ensure a directory exists with proper permissions
ensure_dir() {
    local path="$1"
    local perms="${2:-755}"
    local owner="${3:-root:root}"

    mkdir -p "$path"
    chmod "$perms" "$path"
    chown "$owner" "$path"
}

# Ensure a service is installed and started
ensure_service() {
    local svc="$1"

    if ! systemctl list-unit-files "$svc" &>/dev/null; then
        log_warn "Service not found: $svc"
        return $E_NOTFOUND
    fi

    systemctl start "$svc" || {
        log_error "Failed to start service: $svc"
        return $E_INTERNAL
    }
    systemctl enable "$svc" 2>/dev/null || true
}

# Parse command-line arguments in key=value format
parse_args() {
    local -n args_map=$1
    shift

    for arg in "$@"; do
        if [[ "$arg" =~ ^([a-z_]+)=(.+)$ ]]; then
            args_map["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        else
            log_error "Invalid argument format: $arg (use key=value)"
            return $E_USAGE
        fi
    done
}

# Check if port is available
port_available() {
    local port="$1"
    ! nc -z localhost "$port" 2>/dev/null
}

# Acquire exclusive lock (for concurrent operation safety)
acquire_lock() {
    local lock_file="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while [[ -f "$lock_file" ]] && [[ $elapsed -lt $timeout ]]; do
        sleep 0.5
        ((elapsed += 1))
    done

    if [[ -f "$lock_file" ]]; then
        log_error "Could not acquire lock: $lock_file"
        return $E_INTERNAL
    fi

    echo $$ > "$lock_file"
}

# Release lock
release_lock() {
    local lock_file="$1"
    rm -f "$lock_file"
}

export -f log_info log_warn log_error log_debug
export -f redact_credentials is_idempotent_ok require_root require_cmd
export -f is_package_installed ensure_package normalize_domain make_sftp_username
export -f get_state_file site_exists read_state write_state list_sites
export -f gen_password iso_timestamp run_with_timeout
export -f ensure_system_user ensure_dir ensure_service parse_args port_available
export -f acquire_lock release_lock

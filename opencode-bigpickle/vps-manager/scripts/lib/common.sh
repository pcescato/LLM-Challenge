#!/usr/bin/env bash
set -euo pipefail

CONFIG=${VPSMGR_CONFIG:-/etc/vpsmgr/vpsmgr.conf}
[[ -f "$CONFIG" ]] && source "$CONFIG"

STATE_DIR="${state_dir:-/var/lib/vpsmgr/sites}"
LOG_DIR="${log_dir:-/var/log/vpsmgr}"
BACKUP_DIR="${backup_dir:-/var/backups/vpsmgr}"
WEBROOT_BASE="${webroot_base:-/home}"
CADDY_SITES_DIR="${caddy_sites_dir:-/etc/caddy/sites}"
BACKUP_RETENTION_DAYS="${backup_retention_days:-30}"

log() {
    local level="$1" msg="$2"
    msg="$(redact_secrets "$msg")"
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] [$level] $msg" >> "$LOG_DIR/vpsmgr.log"
}

info()  { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERR"   "$*"; }
die()   { error "$*"; echo "FATAL: $*" >&2; exit 5; }

redact_secrets() {
    local line="$1"
    line="${line//DB_PASSWORD=[^ ]*/DB_PASSWORD=***}"
    line="${line//SFTP_PASSWORD=[^ ]*/SFTP_PASSWORD=***}"
    line="${line//AUTH_KEY=[^ ]*/AUTH_KEY=***}"
    line="${line//SECURE_AUTH_KEY=[^ ]*/SECURE_AUTH_KEY=***}"
    line="${line//LOGGED_IN_KEY=[^ ]*/LOGGED_IN_KEY=***}"
    line="${line//NONCE_KEY=[^ ]*/NONCE_KEY=***}"
    line="${line//AUTH_SALT=[^ ]*/AUTH_SALT=***}"
    line="${line//SECURE_AUTH_SALT=[^ ]*/SECURE_AUTH_SALT=***}"
    line="${line//LOGGED_IN_SALT=[^ ]*/LOGGED_IN_SALT=***}"
    line="${line//NONCE_SALT=[^ ]*/NONCE_SALT=***}"
    echo "$line"
}

site_state_path() {
    echo "$STATE_DIR/${1}.json"
}

site_user_for() {
    local domain="$1"
    echo "ex_${domain//./_}"
}

site_webroot_for() {
    local domain="$1"
    local user
    user="$(site_user_for "$domain")"
    echo "$WEBROOT_BASE/$user/public"
}

ensure_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

ensure_domain_arg() {
    [[ -n "${1:-}" ]] || { echo "Usage: $0 <domain>" >&2; exit 1; }
}

load_state() {
    local path
    path="$(site_state_path "$1")"
    if [[ ! -f "$path" ]]; then
        echo "Site $1 not found" >&2
        exit 2
    fi
    cat "$path"
}

save_state() {
    local domain="$1" data="$2"
    mkdir -p "$STATE_DIR"
    echo "$data" > "$(site_state_path "$domain")"
}

delete_state() {
    local path
    path="$(site_state_path "$1")"
    rm -f "$path"
}

map_exit_code() {
    local ec="$1"
    case "$ec" in
        0) echo 200 ;;
        1) echo 400 ;;
        2) echo 404 ;;
        3) echo 409 ;;
        4) echo 422 ;;
        5) echo 500 ;;
        *) echo 500 ;;
    esac
}

#!/usr/bin/env bash
# common.sh — Shared utilities sourced by all vpsmgr scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve config path: allow override via VPSMGR_CONFIG, else use standard path
if [[ -z "${VPSMGR_CONFIG:-}" ]]; then
    if [[ -f "/etc/vpsmgr/vpsmgr.conf" ]]; then
        VPSMGR_CONFIG="/etc/vpsmgr/vpsmgr.conf"
    elif [[ -f "${SCRIPT_DIR}/../../config/vpsmgr.conf" ]]; then
        VPSMGR_CONFIG="$(cd "${SCRIPT_DIR}/../../config" && pwd)/vpsmgr.conf"
    fi
fi

if [[ ! -f "${VPSMGR_CONFIG:-}" ]]; then
    echo "ERROR: vpsmgr.conf not found. Set VPSMGR_CONFIG or run bootstrap first." >&2
    exit 5
fi

source "${VPSMGR_CONFIG}"

# Ensure log directory exists
mkdir -p "${LOG_DIR}" 2>/dev/null || true

# --- Logging ---

log_info()  { echo "[INFO]  $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*" | tee -a "${LOG_DIR}/vpsmgr.log" >&2; }
log_warn()  { echo "[WARN]  $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*" | tee -a "${LOG_DIR}/vpsmgr.log" >&2; }
log_error() { echo "[ERROR] $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*" | tee -a "${LOG_DIR}/vpsmgr.log" >&2; }

# Redact sensitive patterns from log output
redact() {
    local data="$1"
    local patterns="${LOG_REDACT_PATTERNS}"
    local out="${data}"
    while IFS='|' read -ra pats; do
        for pat in "${pats[@]}"; do
            out=$(echo "${out}" | sed -E "s/${pat}[=: ]['\"]?[^ '\"\\n;]+['\"]?/${pat}=[REDACTED]/gi")
        done
    done <<< "${patterns}"
    echo "${out}"
}

# --- Exit code helpers ---

exit_success()         { exit 0; }
exit_input_error()     { log_error "$1"; exit 1; }
exit_not_found()       { log_error "$1"; exit 2; }
exit_conflict()        { log_error "$1"; exit 3; }
exit_dependency()      { log_error "$1"; exit 4; }
exit_internal()        { log_error "$1"; exit 5; }

# --- Validation helpers ---

validate_domain() {
    local domain="$1"
    if [[ ! "${domain}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        exit_input_error "Invalid domain: ${domain}"
    fi
    if [[ "${#domain}" -gt 253 ]]; then
        exit_input_error "Domain too long: ${domain}"
    fi
}

validate_site_type() {
    local type="$1"
    case "${type}" in
        static|php|wordpress|proxy) ;;
        *) exit_input_error "Invalid site type: ${type}. Must be one of: static, php, wordpress, proxy" ;;
    esac
}

validate_site_user() {
    local sitename="$1"
    if [[ ! "${sitename}" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
        exit_input_error "Invalid site username: ${sitename}"
    fi
}

# Derive sftp username from domain
domain_to_sftp_user() {
    local domain="$1"
    # Replace dots and dashes with underscores, truncate to 32 chars
    echo "${domain}" | tr '.-' '_' | cut -c1-32
}

# Derive short name for DB naming
domain_to_shortname() {
    local domain="$1"
    # First segment before dot, alphanumeric only, max 16 chars
    local base
    base=$(echo "${domain}" | cut -d. -f1 | tr -cd 'a-zA-Z0-9' | tr '[:upper:]' '[:lower:]')
    echo "${base:0:16}"
}

# --- State file management ---

state_file() {
    local domain="$1"
    echo "${STATE_DIR}/${domain}.json"
}

read_state() {
    local domain="$1"
    local sf
    sf=$(state_file "${domain}")
    if [[ ! -f "${sf}" ]]; then
        return 1
    fi
    cat "${sf}"
}

write_state() {
    local domain="$1"
    local json="$2"
    local sf
    sf=$(state_file "${domain}")
    echo "${json}" > "${sf}"
    chmod 600 "${sf}"
}

delete_state() {
    local domain="$1"
    local sf
    sf=$(state_file "${domain}")
    rm -f "${sf}"
}

list_states() {
    local dir="${STATE_DIR}"
    if [[ -d "${dir}" ]]; then
        for f in "${dir}"/*.json; do
            [[ -f "${f}" ]] || continue
            basename "${f}" .json
        done
    fi
}

# --- Password generation ---

generate_password() {
    local length="${1:-32}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=' | head -c "${length}"
}

# --- Ensure running as root ---

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        exit_input_error "This script must be run as root"
    fi
}

# --- JSON output helpers (for API consumption) ---

json_output() {
    local exit_code="$1"
    local stdout_content="$2"
    local stderr_content="$3"
    local http_status="${4:-200}"

    cat <<EOJSON
{
  "exit_code": ${exit_code},
  "stdout": $(echo "${stdout_content}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""'),
  "stderr": $(echo "${stderr_content}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""'),
  "http_status": ${http_status}
}
EOJSON
}

# --- Credential wrapper ---
# Print credential once to stdout wrapped in markers
emit_credentials() {
    local label="$1"
    local creds="$2"
    echo ""
    echo "<<<CREDENTIALS>>>"
    echo "${label}"
    echo "${creds}"
    echo "<<<END_CREDENTIALS>>>"
    echo ""
}
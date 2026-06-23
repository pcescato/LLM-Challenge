#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers for the vpsmgr toolkit.
# This file is sourced, not executed directly.

# Determine the project root. BASH_SOURCE[0] is .../scripts/lib/common.sh.
VPSMGR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPSMGR_ROOT="$(realpath "${VPSMGR_LIB_DIR}/../..")"

# ---------------------------------------------------------------------------
# Configuration loading
# ---------------------------------------------------------------------------
_load_config() {
    local runtime_cfg="/etc/vpsmgr/vpsmgr.conf"
    local repo_cfg="${VPSMGR_ROOT}/config/vpsmgr.conf"

    if [[ -f ${runtime_cfg} ]]; then
        # shellcheck source=/dev/null
        set -a; source "${runtime_cfg}"; set +a
    elif [[ -f ${repo_cfg} ]]; then
        # Running from the repository during development/testing.
        # shellcheck source=/dev/null
        set -a; source "${repo_cfg}"; set +a
    else
        echo "FATAL: vpsmgr.conf not found at ${runtime_cfg} or ${repo_cfg}" >&2
        exit 5
    fi
}
_load_config

# Runtime directories (bootstrap is expected to create them; we ensure anyway)
mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging with redaction
# ---------------------------------------------------------------------------
_vpsmgr_redact() {
    # Strip anything that looks like a credential. This is a best-effort
    # safeguard against accidental secret leakage in logs.
    sed -E \
        -e 's/(password|passwd|pass|secret|token|key|pwd)=[^[:space:]]+/\1=***REDACTED***/gi' \
        -e 's/[a-f0-9]{32,}/***REDACTED***/gi'
}

vpsmgr_log() {
    local level="$1"
    shift
    local msg
    msg="$(printf '%s' "$*" | _vpsmgr_redact)"
    { printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [${level}] ${msg}"; } >> "${LOG_DIR}/vpsmgr.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Exit helpers matching the API exit-code contract
# ---------------------------------------------------------------------------
die_input()      { vpsmgr_log ERROR "Input/usage error: $*"; echo "ERROR: $*" >&2; exit 1; }
die_notfound()   { vpsmgr_log ERROR "Not found: $*";        echo "ERROR: $*" >&2; exit 2; }
die_conflict()   { vpsmgr_log ERROR "Conflict: $*";         echo "ERROR: $*" >&2; exit 3; }
die_dependency() { vpsmgr_log ERROR "Dependency error: $*"; echo "ERROR: $*" >&2; exit 4; }
die_internal()   { vpsmgr_log ERROR "Internal error: $*";   echo "ERROR: $*" >&2; exit 5; }

# ---------------------------------------------------------------------------
# Common prerequisites
# ---------------------------------------------------------------------------
require_root() {
    if [[ ${EUID:-} -ne 0 ]]; then
        die_internal "this script must run as root"
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die_dependency "required command not found: ${cmd}"
    fi
}

# ---------------------------------------------------------------------------
# Secret handling
# ---------------------------------------------------------------------------
generate_password() {
    local length="${1:-32}"
    openssl rand -base64 "${length}" | tr -dc 'a-zA-Z0-9' | head -c "${length}"
}

print_credentials() {
    local label="$1"
    local value="$2"
    # Printed once to stdout so the API can surface it and then forget it.
    printf '<<<CREDENTIALS>>>%s=%s<<<>>>\n' "${label}" "${value}"
}

# ---------------------------------------------------------------------------
# Domain / identifier helpers
# ---------------------------------------------------------------------------
_safe_name() {
    local input="$1"
    local max_len="${2:-32}"
    echo "${input}" \
        | tr '[:upper:]' '[:lower:]' \
        | tr '.-' '_' \
        | sed 's/[^a-z0-9_]//g;s/^_//;s/_$//;s/__*/_/g' \
        | cut -c1-"${max_len}"
}

domain_to_safe_name() { _safe_name "$1" 32; }

domain_to_sftp_user() {
    local domain="$1"
    echo "${SFTP_USER_PREFIX}$(domain_to_safe_name "${domain}")"
}

domain_to_db_name() {
    local domain="$1"
    local engine="$2"
    local base
    base="$(domain_to_safe_name "${domain}" 16)_$(echo "${engine}" | tr '[:upper:]' '[:lower:]')"
    echo "${base}" | cut -c1-32
}

domain_to_db_user() {
    local domain="$1"
    local engine="$2"
    local base
    base="$(domain_to_safe_name "${domain}" 16)_$(echo "${engine}" | cut -c1-3)"
    echo "${base}" | cut -c1-32
}

validate_domain() {
    local domain="$1"
    if [[ -z ${domain} ]]; then
        die_input "domain is required"
    fi
    if [[ ! ${domain} =~ ^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?)*$ ]]; then
        die_input "invalid domain: ${domain}"
    fi
    if [[ ${domain} == *..* ]]; then
        die_input "invalid domain: ${domain}"
    fi
}

# ---------------------------------------------------------------------------
# State helpers (JSON on disk; no credential fields ever)
# ---------------------------------------------------------------------------
state_path() {
    local domain="$1"
    echo "${STATE_DIR}/${domain}.json"
}

state_exists() {
    local domain="$1"
    [[ -f $(state_path "${domain}") ]]
}

state_load() {
    local domain="$1"
    local sp
    sp=$(state_path "${domain}")
    if [[ -f ${sp} ]]; then
        cat "${sp}"
    else
        echo '{}'
    fi
}

state_write() {
    local domain="$1"
    local payload="$2"
    local sp tmp
    sp=$(state_path "${domain}")
    tmp=$(mktemp)
    require_command jq
    if ! jq '.' <<< "${payload}" > "${tmp}"; then
        rm -f "${tmp}"
        die_internal "invalid JSON for state update"
    fi
    mv "${tmp}" "${sp}"
    chmod 0644 "${sp}"
    vpsmgr_log INFO "state updated for ${domain}"
}

state_create() {
    local domain="$1"
    local type="$2"
    local sftp_user="$3"
    local webroot="$4"
    local php_version="$5"
    local php_pool="$6"
    local caddy_block="$7"
    local proxy_target="${8:-null}"

    local payload
    payload=$(jq -n \
        --arg domain "${domain}" \
        --arg type "${type}" \
        --arg sftp_user "${sftp_user}" \
        --arg webroot "${webroot}" \
        --arg php_version "${php_version}" \
        --arg php_pool "${php_pool}" \
        --arg caddy_block "${caddy_block}" \
        --argjson proxy_target "${proxy_target}" \
        '{domain: $domain, type: $type, sftp_user: $sftp_user, webroot: $webroot, php_version: $php_version, php_pool: $php_pool, caddy_block: $caddy_block, databases: [], proxy_target: $proxy_target, created_at: now}')
    state_write "${domain}" "${payload}"
}

state_get() {
    local domain="$1"
    local key="$2"
    state_load "${domain}" | jq -r "${key}"
}

state_add_database() {
    local domain="$1"
    local engine="$2"
    local db_name="$3"
    local db_user="$4"
    local sp payload
    sp=$(state_path "${domain}")
    if [[ ! -f ${sp} ]]; then
        die_notfound "site state not found: ${domain}"
    fi
    payload=$(jq --arg engine "${engine}" --arg db_name "${db_name}" --arg db_user "${db_user}" \
        '.databases += [{engine: $engine, name: $db_name, user: $db_user}]' "${sp}")
    state_write "${domain}" "${payload}"
}

# ---------------------------------------------------------------------------
# Templating (envsubst)
# ---------------------------------------------------------------------------
render_template() {
    local template="$1"
    local output="$2"
    if [[ ! -f ${template} ]]; then
        die_internal "template not found: ${template}"
    fi
    require_command envsubst
    mkdir -p "$(dirname "${output}")"
    envsubst < "${template}" > "${output}"
}

# ---------------------------------------------------------------------------
# Service helpers
# ---------------------------------------------------------------------------
systemd_reload() {
    require_command systemctl
    systemctl daemon-reload
}

service_action() {
    local svc="$1"
    local action="$2"
    require_command systemctl
    systemctl "${action}" "${svc}" || return $?
}

service_status() {
    local svc="$1"
    require_command systemctl
    systemctl is-active --quiet "${svc}" && echo "active" || echo "inactive"
}

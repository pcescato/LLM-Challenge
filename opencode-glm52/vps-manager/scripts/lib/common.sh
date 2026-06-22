#!/usr/bin/env bash
# lib/common.sh — core helpers shared by every vps-manager script.
# Sourced first by every script. Provides logging, redaction, config load,
# state I/O, exit-code convention, domain validation, and secret generation.

# Exit-code convention (scripts → API)
E_SUCCESS=0
E_USAGE=1      # invalid input/usage          → 400
E_NOTFOUND=2   # not found                    → 404
E_CONFLICT=3   # conflict / exists            → 409
E_DEP=4        # dependency missing           → 422
E_INTERNAL=5   # internal error               → 500

# --------------------------------------------------------------------------
# Configuration loading.
# --------------------------------------------------------------------------
_vpsmgr_load_config() {
    local conf
    for conf in "/etc/vpsmgr/vpsmgr.conf" \
                "${VPSMGR_ROOT:-}/config/vpsmgr.conf" \
                "${BASH_SOURCE[0]%/*/*/*}/../config/vpsmgr.conf"; do
        if [[ -f "${conf}" ]]; then
            # shellcheck disable=SC1090
            source "${conf}"
            VPSMGR_CONF_LOADED="${conf}"
            return 0
        fi
    done
    return 1
}
_vpsmgr_load_config || true

# Sensible defaults if config missing (dev/test mode).
: "${VPSMGR_CONFIG_DIR:=/etc/vpsmgr}"
: "${VPSMGR_LOG_DIR:=/var/log/vpsmgr}"
: "${VPSMGR_STATE_DIR:=/var/lib/vpsmgr/sites}"
: "${VPSMGR_BACKUP_DIR:=/var/backups/vpsmgr}"
: "${VPSMGR_CADDY_SITES_DIR:=/etc/caddy/sites}"
: "${VPSMGR_CADDY_MAIN_CONF:=/etc/caddy/Caddyfile}"
: "${VPSMGR_TEMPLATES_DIR:=/usr/local/share/vpsmgr/templates}"
: "${VPSMGR_HOME_BASE:=/home}"
: "${VPSMGR_PHP_MIN_MAJOR:=8}"
: "${VPSMGR_PHP_MIN_MINOR:=4}"
: "${VPSMGR_DB_ENGINES:="mariadb,postgresql"}"
: "${VPSMGR_SFTP_SHELL:=/usr/sbin/nologin}"
: "${VPSMGR_BACKUP_RETENTION_DAYS:=7}"
: "${VPSMGR_BACKUP_MODE:=0600}"
: "${VPSMGR_API_HOST:=127.0.0.1}"
: "${VPSMGR_API_PORT:=8000}"
: "${VPSMGR_API_TOKEN_FILE:=/etc/vpsmgr/api.token}"
: "${VPSMGR_REDACT_PATTERNS:="<<<CREDENTIALS>>>.*<<<END CREDENTIALS>>>;password=[^[:space:]]+;DB_PASSWORD='[^']*';passwd: [^[:space:]]+"}"
: "${VPSMGR_CADDY_CHANNEL:=stable}"
: "${VPSMGR_WPCLI_PATH:=/usr/local/bin/wp}"

export VPSMGR_CONF_LOADED VPSMGR_CONFIG_DIR VPSMGR_LOG_DIR VPSMGR_STATE_DIR \
       VPSMGR_BACKUP_DIR VPSMGR_CADDY_SITES_DIR VPSMGR_CADDY_MAIN_CONF \
       VPSMGR_TEMPLATES_DIR VPSMGR_HOME_BASE VPSMGR_PHP_MIN_MAJOR \
       VPSMGR_PHP_MIN_MINOR VPSMGR_DB_ENGINES VPSMGR_SFTP_SHELL \
       VPSMGR_BACKUP_RETENTION_DAYS VPSMGR_BACKUP_MODE VPSMGR_API_HOST \
       VPSMGR_API_PORT VPSMGR_API_TOKEN_FILE VPSMGR_REDACT_PATTERNS \
       VPSMGR_CADDY_CHANNEL VPSMGR_WPCLI_PATH

# Resolve script root so we can locate sibling libs and templates.
VPSMGR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
VPSMGR_LIB_DIR="${VPSMGR_SCRIPT_DIR}/lib"
VPSMGR_REPO_ROOT="$(cd "${VPSMGR_SCRIPT_DIR}/.." && pwd)"
# Templates shipped with repo fall back when install dir absent.
VPSMGR_TEMPLATES_FALLBACK="${VPSMGR_REPO_ROOT}/templates"
export VPSMGR_SCRIPT_DIR VPSMGR_LIB_DIR VPSMGR_REPO_ROOT VPSMGR_TEMPLATES_FALLBACK

# --------------------------------------------------------------------------
# Logging with secret redaction (D1).
# --------------------------------------------------------------------------
vpsmgr_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    local script_name
    script_name="$(basename "${0:-common}")"

    # Redact secrets per configured patterns before any write.
    local IFS=';'
    local pat
    for pat in ${VPSMGR_REDACT_PATTERNS}; do
        [[ -z "${pat}" ]] && continue
        msg="$(printf '%s' "${msg}" | sed -E "s/${pat}/[REDACTED]/g")"
    done
    unset IFS

    mkdir -p "${VPSMGR_LOG_DIR}" 2>/dev/null || true
    printf '%s [%s] %s: %s\n' "${ts}" "${level}" "${script_name}" "${msg}" \
        >> "${VPSMGR_LOG_DIR}/vpsmgr.log" 2>/dev/null || true
}

log_info()  { vpsmgr_log INFO  "$*"; }
log_warn()  { vpsmgr_log WARN  "$*"; }
log_error() { vpsmgr_log ERROR "$*"; }
log_debug() { [[ "${VPSMGR_DEBUG:-0}" == "1" ]] && vpsmgr_log DEBUG "$*"; return 0; }

# Die with an exit code and message (to stderr, not logs if secret).
die() {
    local code="$1"; shift
    echo "ERROR: $*" >&2
    log_error "exit=${code} msg=$*"
    exit "${code}"
}

# --------------------------------------------------------------------------
# Privilege / environment checks.
# --------------------------------------------------------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "${E_USAGE}" "this command must be run as root"
    fi
}

# --------------------------------------------------------------------------
# Domain validation.
# --------------------------------------------------------------------------
validate_domain() {
    local domain="$1"
    if [[ -z "${domain}" ]]; then
        return 1
    fi
    # RFC-1035-ish: labels, dots, hyphens; max 253 chars.
    if [[ ${#domain} -gt 253 ]]; then
        return 1
    fi
    if [[ ! "${domain}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    # Reject localhost-style and obviously internal names.
    case "${domain}" in
        localhost|localhost.localdomain|"") return 1 ;;
    esac
    return 0
}

# Normalize a domain into a safe unix username fragment.
# example.com → ex_example_com
domain_to_user() {
    local domain="$1"
    local user
    # Take first char of TLD-less first label + rest with dots → underscores.
    local labels
    IFS='.' read -ra labels <<< "${domain}"
    local first="${labels[0]}"
    if [[ ${#first} -lt 2 ]]; then
        first="${first}x"
    fi
    local prefix="${first:0:2}"
    user="${prefix}_$(echo "${domain}" | tr '.' '_')"
    # Trim to 32 chars (linux username limit).
    echo "${user:0:32}"
}

# --------------------------------------------------------------------------
# State management (JSON per site, NO passwords ever — D1).
# --------------------------------------------------------------------------
state_file_for() {
    local domain="$1"
    echo "${VPSMGR_STATE_DIR}/${domain}.json"
}

site_exists() {
    local domain="$1"
    [[ -f "$(state_file_for "${domain}")" ]]
}

# state_write <domain> <json_string>
state_write() {
    local domain="$1"
    local json="$2"
    mkdir -p "${VPSMGR_STATE_DIR}"
    local tmp
    tmp="$(mktemp "${VPSMGR_STATE_DIR}/.${domain}.XXXXXX")"
    printf '%s\n' "${json}" > "${tmp}"
    chmod 644 "${tmp}"
    mv -f "${tmp}" "$(state_file_for "${domain}")"
    log_info "state written for ${domain}"
}

# state_read <domain> → echoes JSON, returns 0 or E_NOTFOUND
state_read() {
    local domain="$1"
    local f
    f="$(state_file_for "${domain}")"
    if [[ ! -f "${f}" ]]; then
        return "${E_NOTFOUND}"
    fi
    cat "${f}"
}

state_delete() {
    local domain="$1"
    local f
    f="$(state_file_for "${domain}")"
    if [[ -f "${f}" ]]; then
        rm -f "${f}"
        log_info "state removed for ${domain}"
    fi
}

# Minimal JSON field reader (no jq dependency required; falls back to jq if present).
# json_get <json> <key>  → echoes value (string, unquoted) or empty.
json_get() {
    local json="$1"
    local key="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "${key}" '.[$k] // empty' <<< "${json}" 2>/dev/null
        return $?
    fi
    # Naive regex fallback for simple flat values.
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = d.get('${key}')
    if v is None:
        sys.stdout.write('')
    elif isinstance(v, (list, dict)):
        sys.stdout.write(json.dumps(v))
    else:
        sys.stdout.write(str(v))
except Exception:
    pass
" <<< "${json}" 2>/dev/null
}

# json_set <json> <key> <value>  → echoes new JSON
json_set() {
    local json="$1"
    local key="$2"
    local val="$3"
    python3 -c "
import sys, json
d = json.loads(sys.stdin.read() or '{}')
d['${key}'] = '''${val}'''
print(json.dumps(d, indent=2))
" <<< "${json}" 2>/dev/null
}

# json_append_to_list <json> <key> <value_json> → echoes new JSON
json_append_to_list() {
    local json="$1"
    local key="$2"
    local item="$3"
    python3 -c "
import sys, json
d = json.loads(sys.stdin.read() or '{}')
lst = d.setdefault('${key}', [])
if isinstance(lst, list):
    lst.append(json.loads('''${item}'''))
print(json.dumps(d, indent=2))
" <<< "${json}" 2>/dev/null
}

# --------------------------------------------------------------------------
# Secret generation (in-memory, printed once, never persisted — D1/D7).
# --------------------------------------------------------------------------
# gen_password <length> → echoes random alphanumeric password
gen_password() {
    local len="${1:-24}"
    # Use /dev/urandom; map to alnum. Avoid ambiguous chars.
    tr -dc 'A-HJ-NP-Za-km-z2-9' < /dev/urandom 2>/dev/null | head -c "${len}" || true
    echo
}

# gen_db_name <domain> → safe db name (≤ 63 chars, starts with letter).
gen_db_name() {
    local domain="$1"
    local base
    base="$(echo "${domain}" | tr '.' '_')"
    # Prefix to ensure leading letter, trim.
    base="d_${base}"
    echo "${base:0:63}"
}

# gen_db_user <domain> → safe db username.
gen_db_user() {
    local domain="$1"
    local base
    base="$(echo "${domain}" | tr '.' '_')"
    base="u_${base}"
    # MySQL user limit is 32; postgres 63.
    echo "${base:0:32}"
}

# Print credentials block to stdout wrapped in markers. NEVER to logs.
print_credentials() {
    echo "<<<CREDENTIALS>>>"
    cat
    echo "<<<END CREDENTIALS>>>"
}

# --------------------------------------------------------------------------
# Template resolution.
# --------------------------------------------------------------------------
template_path() {
    local name="$1"
    for d in "${VPSMGR_TEMPLATES_DIR}" "${VPSMGR_TEMPLATES_FALLBACK}"; do
        if [[ -f "${d}/${name}" ]]; then
            echo "${d}/${name}"
            return 0
        fi
    done
    return 1
}

# render_template <template_file> <key1=val1> [key2=val2 ...]
# Replaces {{ key }} and {{key}} tokens with values. Uses pure-bash parameter
# expansion (not sed) so values may contain /, &, newlines, etc.
render_template() {
    local tmpl="$1"; shift
    local out
    out="$(cat "${tmpl}")"
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        # Spaced form: {{ key }}
        out="${out//\{\{ ${key} \}\}/${val}}"
        # Unspaced form: {{key}}
        out="${out//\{\{${key}\}\}/${val}}"
    done
    printf '%s' "${out}"
}

# --------------------------------------------------------------------------
# Backup helpers.
# --------------------------------------------------------------------------
backup_dir_for() {
    local domain="$1"
    echo "${VPSMGR_BACKUP_DIR}/${domain}"
}

# ISO8601 timestamp for filenames (no colons — filesystem safe).
timestamp_fn() {
    date -u +'%Y%m%dT%H%M%SZ'
}

# --------------------------------------------------------------------------
# Sanity: confirm a command exists or die with E_DEP.
# --------------------------------------------------------------------------
require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "${E_DEP}" "required command not found: ${cmd}"
    fi
}

# --------------------------------------------------------------------------
# Source sibling libraries if present (best effort).
# --------------------------------------------------------------------------
_vpsmgr_source_libs() {
    local lib
    for lib in caddy php db sftp wp; do
        local f="${VPSMGR_LIB_DIR}/${lib}.sh"
        [[ -f "${f}" ]] && [[ "${BASH_SOURCE[0]}" != "${f}" ]] && source "${f}" 2>/dev/null || true
    done
}
# NOTE: libs are sourced lazily by individual scripts to avoid circular loads.
# This function is available but not called automatically here.

log_debug "common.sh loaded (conf=${VPSMGR_CONF_LOADED:-none})"

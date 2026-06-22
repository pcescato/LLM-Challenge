#!/usr/bin/env bash
# lib/caddy.sh — Caddy reverse proxy / static / PHP-FPM site block management.
# Relies on lib/common.sh (already sourced by caller).

# Per-site Caddy config block path.
caddy_block_path() {
    local domain="$1"
    echo "${VPSMGR_CADDY_SITES_DIR}/${domain}.caddy"
}

# Ensure the sites.d import line exists in the main Caddyfile.
caddy_ensure_import() {
    mkdir -p "${VPSMGR_CADDY_SITES_DIR}"
    if [[ ! -f "${VPSMGR_CADDY_MAIN_CONF}" ]]; then
        # Fresh main Caddyfile with the import directive.
        {
            echo "# Managed by vps-manager. Do not edit by hand."
            echo "import ${VPSMGR_CADDY_SITES_DIR}/*.caddy"
        } > "${VPSMGR_CADDY_MAIN_CONF}"
        log_info "created main Caddyfile with sites import"
        return 0
    fi
    if ! grep -qE "import[[:space:]]+${VPSMGR_CADDY_SITES_DIR}/\*\.caddy" "${VPSMGR_CADDY_MAIN_CONF}" 2>/dev/null; then
        {
            echo ""
            echo "# vps-manager sites import"
            echo "import ${VPSMGR_CADDY_SITES_DIR}/*.caddy"
        } >> "${VPSMGR_CADDY_MAIN_CONF}"
        log_info "appended sites import to existing Caddyfile"
    fi
}

# caddy_write_block <domain> <type> <webroot> <php_socket|-> <proxy_target|->
caddy_write_block() {
    local domain="$1"
    local site_type="$2"
    local webroot="$3"
    local php_socket="${4:-}"
    local proxy_target="${5:-}"

    # Build the type-specific inner block. Kept simple so render_template's
    # flat {{ key }} substitution is sufficient (no jinja conditionals needed).
    local body=""
    case "${site_type}" in
        static)
            body=$'\troot * "'"${webroot}"'"'$'\n\tfile_server'
            ;;
        php)
            body=$'\troot * "'"${webroot}"'"'$'\n\tphp_fastcgi unix/'"${php_socket}"$'\n\tfile_server'
            ;;
        wordpress)
            body=$'\troot * "'"${webroot}"'"'$'\n\tphp_fastcgi unix/'"${php_socket}"$'\n\tfile_server'$'\n\t# WordPress: deny direct access to sensitive files'$'\n\t@sensitive {'$'\n\t\tpath /wp-config.php /xmlrpc.php'$'\n\t}'$'\n\trewrite @sensitive /index.php'
            ;;
        proxy)
            body=$'\treverse_proxy "'"${proxy_target}"'"'
            ;;
        *)
            die "${E_USAGE}" "unsupported site type for caddy block: ${site_type}"
            ;;
    esac

    local tmpl
    tmpl="$(template_path "Caddyfile.site.j2")" \
        || die "${E_INTERNAL}" "Caddyfile.site.j2 template not found"
    local block
    block="$(render_template "${tmpl}" \
        "domain=${domain}" \
        "webroot=${webroot}" \
        "site_type=${site_type}" \
        "php_socket=${php_socket}" \
        "proxy_target=${proxy_target}" \
        "body=${body}")"
    mkdir -p "${VPSMGR_CADDY_SITES_DIR}"
    local f
    f="$(caddy_block_path "${domain}")"
    printf '%s\n' "${block}" > "${f}"
    chmod 644 "${f}"
    log_info "caddy block written for ${domain} (type=${site_type})"
}

caddy_remove_block() {
    local domain="$1"
    local f
    f="$(caddy_block_path "${domain}")"
    if [[ -f "${f}" ]]; then
        rm -f "${f}"
        log_info "caddy block removed for ${domain}"
    fi
}

# Validate and reload Caddy config. Idempotent.
caddy_reload() {
    if ! command -v caddy >/dev/null 2>&1; then
        die "${E_DEP}" "caddy not installed"
    fi
    if ! caddy validate --config "${VPSMGR_CADDY_MAIN_CONF}" >/dev/null 2>&1; then
        local err
        err="$(caddy validate --config "${VPSMGR_CADDY_MAIN_CONF}" 2>&1)"
        die "${E_INTERNAL}" "caddy config invalid: ${err}"
    fi
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
    log_info "caddy reloaded"
}

caddy_is_installed() {
    command -v caddy >/dev/null 2>&1
}

#!/usr/bin/env bash
# lib/wp.sh — WordPress single-site install helpers via WP-CLI.
# Admin credentials are interactive TTY only (never via API — D7/constraint).
# Relies on lib/common.sh (already sourced by caller).

wp_cli_path() {
    echo "${VPSMGR_WPCLI_PATH}"
}

wp_cli_available() {
    [[ -x "${VPSMGR_WPCLI_PATH}" ]] && "${VPSMGR_WPCLI_PATH}" --info >/dev/null 2>&1
}

# Install WP-CLI phar if missing (idempotent).
wp_install_cli() {
    if wp_cli_available; then
        return 0
    fi
    if [[ ! -f "${VPSMGR_WPCLI_PATH}" ]]; then
        curl -sS -o "${VPSMGR_WPCLI_PATH}" \
            https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
            2>/dev/null || die "${E_DEP}" "failed to download wp-cli.phar"
        chmod +x "${VPSMGR_WPCLI_PATH}"
    fi
    log_info "wp-cli installed at ${VPSMGR_WPCLI_PATH}"
}

# wp_run_as <user> <webroot> <args...>
wp_run_as() {
    local user="$1"
    local webroot="$2"
    shift 2
    sudo -u "${user}" -- "${VPSMGR_WPCLI_PATH}" --path="${webroot}" "$@"
}

# wp_download_core <user> <webroot>
wp_download_core() {
    local user="$1"
    local webroot="$2"
    wp_run_as "${user}" "${webroot}" core download --skip-content 2>/dev/null
}

# wp_config_write <user> <webroot> <db_name> <db_user> <db_pass> <db_host> <db_engine>
# Writes wp-config.php directly into the app's own config (chmod 600, owned by
# site user). Never echoed to stdout/logs and never stored in toolkit state (D1).
wp_config_write() {
    local user="$1"
    local webroot="$2"
    local db_name="$3"
    local db_user="$4"
    local db_pass="$5"
    local db_host="${6:-localhost}"
    local db_engine="$7"

    local tmpl
    tmpl="$(template_path "wp-config.tmpl")" \
        || die "${E_INTERNAL}" "wp-config.tmpl template not found"

    # Generate fresh salts.
    local salts
    salts="$(curl -sS https://api.wordpress.org/secret-keys/1.1/salt/ 2>/dev/null || _wp_fallback_salts)"

    # Choose the appropriate DB_*_HOST constant name for the engine.
    local db_host_name="DB_HOST"
    if [[ "${db_engine}" == "postgresql" || "${db_engine}" == "postgres" ]]; then
        # PostgreSQL via PECL pdo_pgsql — standard constant still DB_HOST.
        :
    fi

    local cfg
    cfg="$(render_template "${tmpl}" \
        "db_name=${db_name}" \
        "db_user=${db_user}" \
        "db_pass=${db_pass}" \
        "db_host=${db_host}" \
        "db_host_name=${db_host_name}" \
        "salts=${salts}")"

    local cfg_path="${webroot}/wp-config.php"
    printf '%s\n' "${cfg}" > "${cfg_path}"
    chown "${user}:${user}" "${cfg_path}"
    chmod 600 "${cfg_path}"
    log_info "wp-config.php written (chmod 600, owner=${user})"
}

# Fallback salts generator (used if WP salt API unreachable).
_wp_fallback_salts() {
    local i
    local names=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY"
                  "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
    for i in "${names[@]}"; do
        local val
        val="$(gen_password 64)"
        printf "define('%s', '%s');\n" "${i}" "${val}"
    done
}

# wp_install_interactive <user> <webroot> <domain> <db_name> <db_user> <db_pass> <db_engine>
# Runs the WP install wizard. Admin credentials are collected from the TTY,
# never from arguments, never stored (D7/constraint).
wp_install_interactive() {
    local user="$1"
    local webroot="$2"
    local domain="$3"
    local db_name="$4"
    local db_user="$5"
    local db_pass="$6"
    local db_engine="$7"
    local db_host="localhost"

    # Ensure config file exists first.
    wp_config_write "${user}" "${webroot}" "${db_name}" "${db_user}" "${db_pass}" "${db_host}" "${db_engine}"

    # Interactive prompts on the controlling TTY only.
    if [[ ! -t 0 ]]; then
        die "${E_USAGE}" "wordpress interactive install requires a TTY"
    fi

    local admin_user admin_email
    read -r -p "WordPress admin username: " admin_user
    read -r -p "WordPress admin email: " admin_email
    # Password hidden input.
    local admin_pass
    read -r -s -p "WordPress admin password: " admin_pass
    echo
    if [[ -z "${admin_user}" || -z "${admin_email}" || -z "${admin_pass}" ]]; then
        die "${E_USAGE}" "admin credentials required"
    fi

    wp_run_as "${user}" "${webroot}" core install \
        --url="https://${domain}" \
        --title="${domain}" \
        --admin_user="${admin_user}" \
        --admin_password="${admin_pass}" \
        --admin_email="${admin_email}" \
        --skip-email 2>/dev/null || die "${E_INTERNAL}" "wp core install failed"

    log_info "wordpress installed for ${domain}"
    # Admin credentials are never printed again after this point.
    unset admin_pass
}

# wp_remove <user> <webroot>  — remove WP files (keeps user/db).
wp_remove() {
    local user="$1"
    local webroot="$2"
    rm -rf "${webroot}/wp-admin" "${webroot}/wp-includes" \
           "${webroot}/wp-content" "${webroot}/*.php" 2>/dev/null || true
    log_info "wordpress files removed from ${webroot}"
}

wp_is_installed() {
    local user="$1"
    local webroot="$2"
    wp_run_as "${user}" "${webroot}" core is-installed 2>/dev/null
}

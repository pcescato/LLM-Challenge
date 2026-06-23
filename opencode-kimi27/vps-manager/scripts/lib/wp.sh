#!/usr/bin/env bash
# scripts/lib/wp.sh — WordPress helpers.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WP_CONFIG_TEMPLATE="${VPSMGR_ROOT}/templates/wp-config.tmpl"

wp_download() {
    local webroot="$1"
    local user="$2"
    require_command wp
    require_command find

    # wp downloads as the site user so ownership is correct out of the box.
    sudo -u "${user}" -H wp core download --path="${webroot}" --locale=en_US || die_internal "failed to download WordPress"
    vpsmgr_log INFO "downloaded WordPress to ${webroot}"
}

wp_fetch_salts() {
    require_command curl
    local salts
    salts=$(curl -fsSL "${WORDPRESS_SALT_URL}")
    if [[ -z ${salts} ]]; then
        die_internal "failed to fetch WordPress salts"
    fi
    echo "${salts}"
}

wp_create_config() {
    local webroot="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local domain="$5"
    local user="$6"

    require_command envsubst
    local salts
    salts=$(wp_fetch_salts)

    local config_out="${webroot}/wp-config.php"
    export DB_NAME="${db_name}"
    export DB_USER="${db_user}"
    export DB_PASSWORD="${db_pass}"
    export DB_HOST="localhost"
    export DOMAIN="${domain}"
    export SALTS="${salts}"
    export DOLLAR='$'

    render_template "${WP_CONFIG_TEMPLATE}" "${config_out}"
    chown "${user}:${user}" "${config_out}"
    chmod 0600 "${config_out}"
    vpsmgr_log INFO "created wp-config.php in ${webroot}"
}

wp_install_interactive() {
    local domain="$1"
    local webroot="$2"
    local user="$3"

    require_command wp
    if [[ ! -t 0 ]]; then
        echo "INFO: WordPress files are ready. Complete installation interactively on a TTY:"
        echo "  sudo -u ${user} -H wp core install --url='https://${domain}' --title='${domain}' --path='${webroot}'"
        return 0
    fi

    echo "WordPress admin credentials will be prompted by WP-CLI. They are never logged."
    sudo -u "${user}" -H wp core install \
        --url="https://${domain}" \
        --title="${domain}" \
        --path="${webroot}" || die_internal "WordPress interactive install failed"
    vpsmgr_log INFO "completed interactive WordPress install for ${domain}"
}

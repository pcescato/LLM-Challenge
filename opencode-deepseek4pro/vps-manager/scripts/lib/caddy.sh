#!/usr/bin/env bash
# caddy.sh — Caddy webserver management functions
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CADDY_MAINFILE="/etc/caddy/Caddyfile"

# Install Caddy from official stable repo
caddy_install() {
    log_info "Installing Caddy (stable channel)..."
    if command -v caddy &>/dev/null; then
        log_info "Caddy already installed: $(caddy version)"
        return 0
    fi

    apt-get update -qq
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl 2>/dev/null

    curl -1sLf "${CADDY_KEY_URL}" | gpg --dearmor -o "${CADDY_KEYRING}" 2>/dev/null

    echo "${CADDY_STABLE_REPO}" | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq caddy

    log_info "Caddy installed: $(caddy version)"
}

# Ensure Caddy import directory and main config
caddy_setup_base() {
    mkdir -p "${CADDY_SITES_DIR}"

    if [[ ! -f "${CADDY_MAINFILE}" ]]; then
        cat > "${CADDY_MAINFILE}" <<'EOF'
# Global Caddyfile — site blocks are imported from sites/ directory
{
    email admin@localhost
}

import /etc/caddy/sites/*.caddy
EOF
        log_info "Created base Caddyfile at ${CADDY_MAINFILE}"
    fi

    # Ensure import directive exists
    if ! grep -q 'import /etc/caddy/sites/\*\.caddy' "${CADDY_MAINFILE}" 2>/dev/null; then
        echo 'import /etc/caddy/sites/*.caddy' >> "${CADDY_MAINFILE}"
        log_info "Added sites import to ${CADDY_MAINFILE}"
    fi
}

# Generate a Caddy site block
caddy_generate_block() {
    local domain="$1"
    local site_type="$2"
    local webroot="$3"
    local proxy_target="${4:-}"

    local block_file="${CADDY_SITES_DIR}/${domain}.caddy"

    case "${site_type}" in
        static)
            cat > "${block_file}" <<EOF
${domain} {
    root * ${webroot}
    file_server
    encode gzip zstd
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
    }
}
EOF
            ;;
        php)
            cat > "${block_file}" <<EOF
${domain} {
    root * ${webroot}
    encode gzip zstd
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
    }
    php_fastcgi unix//run/php/php\${PHP_VERSION}-fpm.sock {
        root ${webroot}
    }
    file_server
}
EOF
            ;;
        wordpress)
            cat > "${block_file}" <<EOF
${domain} {
    root * ${webroot}
    encode gzip zstd
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
    }
    php_fastcgi unix//run/php/php\${PHP_VERSION}-fpm.sock {
        root ${webroot}
    }
    file_server

    # WordPress permalink support
    @wp_paths {
        not path /wp-admin/* /wp-login* /wp-content/* /wp-includes/*
        not file
    }
    redir @wp_paths /index.php{uri}
}
EOF
            ;;
        proxy)
            if [[ -z "${proxy_target}" ]]; then
                exit_input_error "Proxy target required for proxy site type"
            fi
            cat > "${block_file}" <<EOF
${domain} {
    reverse_proxy ${proxy_target}
    encode gzip zstd
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
    }
}
EOF
            ;;
        *)
            exit_input_error "Unknown site type: ${site_type}"
            ;;
    esac

    log_info "Caddy block created: ${block_file}"
    echo "${block_file}"
}

# Remove a Caddy site block
caddy_remove_block() {
    local domain="$1"
    local block_file="${CADDY_SITES_DIR}/${domain}.caddy"

    if [[ -f "${block_file}" ]]; then
        rm -f "${block_file}"
        log_info "Removed Caddy block: ${block_file}"
    fi
}

# Reload Caddy configuration
caddy_reload() {
    if systemctl is-active --quiet caddy 2>/dev/null; then
        systemctl reload caddy
        log_info "Caddy reloaded"
    else
        systemctl restart caddy
        log_info "Caddy restarted"
    fi
}

# Check if Caddy is running
caddy_status() {
    if systemctl is-active --quiet caddy 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}
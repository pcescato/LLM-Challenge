#!/bin/bash
# Caddy integration library
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Check if Caddy is installed and running
caddy_ready() {
    require_cmd caddy
    systemctl is-active --quiet caddy && return 0
    return 1
}

# Ensure Caddy is installed from official repo
install_caddy() {
    if require_cmd caddy 2>/dev/null; then
        log_debug "Caddy already installed"
        return 0
    fi

    log_info "Installing Caddy from official repository..."

    # Import Caddy GPG key
    if [[ ! -f /usr/share/keyrings/caddy-archive-keyring.gpg ]]; then
        curl -fsSL https://apt.everyday.moe/caddy/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-archive-keyring.gpg 2>/dev/null || {
            log_error "Failed to import Caddy GPG key"
            return $E_INTERNAL
        }
    fi

    # Add Caddy repository (stable channel only)
    if [[ ! -f /etc/apt/sources.list.d/caddy-stable.sources ]]; then
        echo "Types: deb
URIs: http://apt.everyday.moe/caddy/debian
Suites: $(lsb_release -cs)
Components: main
Signed-By: /usr/share/keyrings/caddy-archive-keyring.gpg" > /etc/apt/sources.list.d/caddy-stable.sources
    fi

    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null 2>&1 || {
        log_error "Failed to install Caddy"
        return $E_INTERNAL
    }

    # Ensure Caddy site config directory exists
    ensure_dir "${CADDY_CONFIG_DIR}" 755 root:root

    systemctl enable caddy 2>/dev/null || true
    systemctl start caddy || {
        log_error "Failed to start Caddy service"
        return $E_INTERNAL
    }

    log_info "Caddy installed and started"
}

# Create site Caddyfile from template
# Usage: create_caddy_config <domain> <webroot> <site_type>
create_caddy_config() {
    local domain="$1"
    local webroot="$2"
    local site_type="$3"
    local config_file="${CADDY_CONFIG_DIR}/${domain}.caddy"

    domain=$(normalize_domain "$domain") || return 1

    # Verify webroot exists
    if [[ ! -d "$webroot" ]]; then
        log_error "Webroot does not exist: $webroot"
        return $E_NOTFOUND
    fi

    log_info "Creating Caddy config for $domain"

    # Determine root directive based on site type
    local root_directive=""
    if [[ "$site_type" == "wordpress" ]]; then
        root_directive="root * $webroot/wordpress"
    elif [[ "$site_type" == "static" ]]; then
        root_directive="root * $webroot"
    elif [[ "$site_type" == "proxy" ]]; then
        # Proxy config handled separately, no file_server needed
        root_directive=""
    fi

    # Create Caddyfile block for this site
    cat > "$config_file" << 'EOF'
$domain {
$root_directive

  # Security headers
  header / Strict-Transport-Security "max-age=31536000; includeSubDomains"
  header / X-Content-Type-Options nosniff
  header / X-Frame-Options DENY
  header / Referrer-Policy strict-origin-when-cross-origin

  # File server (if applicable)
$fileserver_directive

  # PHP-FPM if needed
$phpfpm_directive

  # HTTPS automatic
  encode gzip
  log {
    output file /var/log/caddy/${domain}-access.log {
      roll_size 100mb
      roll_keep 10
      roll_keep_for 720h
    }
  }

  errors /var/log/caddy/${domain}-error.log {
    roll_size 100mb
    roll_keep 10
    roll_keep_for 720h
  }
}
EOF

    # Interpolate variables
    local fileserver_directive=""
    local phpfpm_directive=""

    if [[ "$site_type" == "wordpress" || "$site_type" == "static" ]]; then
        fileserver_directive="file_server"
    fi

    if [[ "$site_type" == "wordpress" ]]; then
        local php_version
        php_version=$(read_state "$domain" "php_version") || {
            log_error "Could not determine PHP version for $domain"
            return $E_NOTFOUND
        }
        phpfpm_directive="php_fastcgi unix//run/php/php${php_version}-fpm.sock"
    fi

    # Actually write the config with interpolation
    cat > "$config_file" << EOF
$domain {
$root_directive

  # Security headers
  header / Strict-Transport-Security "max-age=31536000; includeSubDomains"
  header / X-Content-Type-Options nosniff
  header / X-Frame-Options DENY
  header / Referrer-Policy strict-origin-when-cross-origin

  # File server (if applicable)
$fileserver_directive

  # PHP-FPM if needed
$phpfpm_directive

  # HTTPS automatic
  encode gzip
  log {
    output file /var/log/caddy/${domain}-access.log {
      roll_size 100mb
      roll_keep 10
      roll_keep_for 720h
    }
  }

  errors /var/log/caddy/${domain}-error.log {
    roll_size 100mb
    roll_keep 10
    roll_keep_for 720h
  }
}
EOF

    chmod 644 "$config_file"
    log_debug "Caddy config created: $config_file"
}

# Update Caddyfile to import site configs
ensure_caddy_import() {
    local main_caddyfile="/etc/caddy/Caddyfile"
    local import_line="import ${CADDY_CONFIG_DIR}/*.caddy"

    if [[ ! -f "$main_caddyfile" ]]; then
        log_error "Main Caddyfile not found: $main_caddyfile"
        return $E_NOTFOUND
    fi

    # Check if import already present
    if grep -q "import.*\${CADDY_CONFIG_DIR}" "$main_caddyfile" 2>/dev/null; then
        log_debug "Caddy import already configured"
        return 0
    fi

    # Add import directive
    echo "" >> "$main_caddyfile"
    echo "# Auto-generated site imports" >> "$main_caddyfile"
    echo "$import_line" >> "$main_caddyfile"

    log_info "Added site imports to main Caddyfile"
}

# Reload Caddy (graceful reload)
reload_caddy() {
    if ! caddy_ready; then
        install_caddy || return $?
    fi

    log_info "Reloading Caddy..."
    caddy reload -c /etc/caddy/Caddyfile 2>&1 | redact_credentials || {
        log_error "Failed to reload Caddy"
        return $E_INTERNAL
    }
    log_info "Caddy reloaded successfully"
}

# Delete site Caddyfile
delete_caddy_config() {
    local domain="$1"
    domain=$(normalize_domain "$domain") || return 1

    local config_file="${CADDY_CONFIG_DIR}/${domain}.caddy"

    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        log_info "Removed Caddy config for $domain"
        reload_caddy || return $?
    fi
}

# Check if Caddy config is valid
validate_caddy_config() {
    if ! require_cmd caddy 2>/dev/null; then
        return 0  # Caddy not installed yet, skip validation
    fi

    log_debug "Validating Caddy configuration..."
    caddy validate -c /etc/caddy/Caddyfile 2>&1 | redact_credentials || {
        log_error "Caddy configuration is invalid"
        return $E_INTERNAL
    }
}

# Get Caddy version
caddy_version() {
    caddy version 2>/dev/null || echo "unknown"
}

export -f caddy_ready install_caddy create_caddy_config ensure_caddy_import
export -f reload_caddy delete_caddy_config validate_caddy_config caddy_version

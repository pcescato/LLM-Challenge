# VPS Manager — Functional Brief

I want to build a minimal VPS management toolkit to replace a control panel
(like aaPanel) on a fresh Ubuntu 24.04 server. The goal is a set of shell
scripts for all operations, exposed through a lightweight FastAPI interface
for automation. No Docker, no control panel, no abstraction layers.

## Server environment

The stack runs Caddy as the web server with automatic HTTPS, two versions of
PHP-FPM (a current and a fallback version), MariaDB and PostgreSQL as database
engines, and Valkey for object caching. All component versions should be
resolved dynamically from their official sources at install time — no hardcoded
version numbers in scripts.

## Site types

The toolkit must handle four types of sites:
- Static sites (HTML/assets only, no PHP, no database)
- PHP sites (custom apps, optional database)
- WordPress sites (full installation via WP-CLI, required database)
- Reverse proxy (forward to a local port)

PHP-FPM should only be activated for site types that actually need it.
A fallback PHP version should be selectable per site for compatibility reasons.

## Operations expected

**Server bootstrap**: a single script to install and configure the entire
stack on a clean server.

**Site provisioning**: create a full site environment — webroot, web server
config, PHP pool if needed, database and user if needed, SFTP access with
a dedicated chrooted user per site. WordPress sites should be fully installed
interactively via WP-CLI (admin credentials prompted, never logged).

**Site deletion**: remove all resources tied to a domain. A full backup must
be created automatically before deletion, and kept for a configurable
retention period. Skipping the backup should require an explicit flag and
a confirmation prompt.

**Database management**: create a database on demand for an existing site,
independently of initial provisioning.

**Static deployment**: push a local build to a site's webroot via rsync.

**Backup**: archive webroot and database dump for a given site or all sites.

**Service management**: start, stop, restart, reload, and check the status
of each component individually or all at once.

## FastAPI interface

A minimal API that wraps the scripts for automation purposes. One route per
operation, Bearer token auth, JSON responses with stdout/stderr and HTTP
status codes mapped to script exit codes.

WordPress interactive prompts (admin credentials) are CLI-only and must not
be exposed through the API.

## General constraints

- No Docker
- Scripts must be idempotent
- All sensitive values (passwords, tokens) must never be written to disk or logs
- All tunable constants (paths, retention periods, PHP versions) centralized
  in a single config file
- Logs written to a dedicated directory

## Expected output for this planning phase

Please propose:
1. A complete project structure
2. The list of scripts with their responsibilities
3. The API route map
4. Any assumptions or design decisions you would make
5. Any questions before starting implementation

Please format your entire response in Markdown.

Please write your response to a file named plan.md in the current directory.

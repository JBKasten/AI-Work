#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — MFA Setup (Authelia + YubiKey/WebAuthn + TOTP)
#
# Usage:
#   bash scripts/setup-mfa.sh                              # interactive setup
#   bash scripts/setup-mfa.sh add-user admin admin@x.com   # add a user
#   bash scripts/setup-mfa.sh enable                       # start MFA services
#   bash scripts/setup-mfa.sh disable                      # stop MFA, revert to basic auth
#   bash scripts/setup-mfa.sh status                       # check MFA status
#
# After setup, users register their YubiKey or TOTP app at:
#   http://<server>/authelia/
#
# Supports:
#   - YubiKey 5 / any FIDO2/WebAuthn hardware key
#   - TOTP (Google Authenticator, Authy, 1Password, etc.)
#   - Password as first factor
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOG_PREFIX="MFA"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

AUTHELIA_DIR="${ROOT_DIR}/authelia"
USERS_DB="${AUTHELIA_DIR}/users_database.yml"
CONFIG="${AUTHELIA_DIR}/configuration.yml"

# ── Generate secrets if not already in .env ──────────────────────────────────
ensure_secrets() {
    local ENV_FILE="${ROOT_DIR}/.env"

    if ! grep -q "^AUTHELIA_JWT_SECRET=" "$ENV_FILE" 2>/dev/null || \
       grep -q "^AUTHELIA_JWT_SECRET=$" "$ENV_FILE" 2>/dev/null; then

        info "Generating Authelia secrets..."

        local JWT_SECRET SESSION_SECRET ENCRYPTION_KEY
        JWT_SECRET="$(openssl rand -hex 32)"
        SESSION_SECRET="$(openssl rand -hex 32)"
        ENCRYPTION_KEY="$(openssl rand -hex 32)"

        # Append or update secrets in .env
        for VAR_LINE in \
            "AUTHELIA_JWT_SECRET=${JWT_SECRET}" \
            "AUTHELIA_SESSION_SECRET=${SESSION_SECRET}" \
            "AUTHELIA_ENCRYPTION_KEY=${ENCRYPTION_KEY}"; do
            VAR_NAME="${VAR_LINE%%=*}"
            if grep -q "^${VAR_NAME}=" "$ENV_FILE" 2>/dev/null; then
                sed -i "s|^${VAR_NAME}=.*|${VAR_LINE}|" "$ENV_FILE"
            else
                echo "$VAR_LINE" >> "$ENV_FILE"
            fi
        done

        success "Secrets generated and saved to .env"
    else
        success "Authelia secrets already configured"
    fi
}

# ── Update Authelia config with correct domain ──────────────────────────────
configure_domain() {
    local ENV_FILE="${ROOT_DIR}/.env"
    local DOMAIN
    DOMAIN="$(grep "^DOMAIN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)"

    if [[ -z "$DOMAIN" ]]; then
        # No domain set — use localhost
        DOMAIN="localhost"
        info "No DOMAIN in .env — using localhost (MFA works but WebAuthn needs HTTPS in production)"
    fi

    # Update Authelia config with domain
    sed -i "s|domain: '.*'|domain: '${DOMAIN}'|" "$CONFIG" 2>/dev/null || true
    sed -i "s|authelia_url: '.*'|authelia_url: 'http://${DOMAIN}/authelia'|" "$CONFIG" 2>/dev/null || true
    sed -i "s|default_redirection_url: '.*'|default_redirection_url: 'http://${DOMAIN}'|" "$CONFIG" 2>/dev/null || true

    info "Authelia domain set to: ${DOMAIN}"
}

# ── Add user ─────────────────────────────────────────────────────────────────
add_user() {
    local USERNAME="$1"
    local EMAIL="${2:-${USERNAME}@local.host}"

    if [[ -z "$USERNAME" ]]; then
        die "Usage: bash scripts/setup-mfa.sh add-user <username> [email]"
    fi

    # Check if user already exists
    if grep -q "^  ${USERNAME}:" "$USERS_DB" 2>/dev/null; then
        warn "User '${USERNAME}' already exists in ${USERS_DB}"
        return 0
    fi

    # Prompt for password
    echo ""
    local PASSWORD PASSWORD_CONFIRM
    read -r -s -p "  Enter password for ${USERNAME}: " PASSWORD
    echo ""
    read -r -s -p "  Confirm password: " PASSWORD_CONFIRM
    echo ""

    if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
        die "Passwords do not match"
    fi

    if [[ ${#PASSWORD} -lt 8 ]]; then
        die "Password must be at least 8 characters"
    fi

    # Generate argon2id hash
    info "Generating password hash..."
    local HASH
    HASH="$(docker run --rm "${AUTHELIA_IMAGE}" authelia crypto hash generate argon2 \
        --password "$PASSWORD" 2>/dev/null | grep 'Digest:' | awk '{print $2}')"

    if [[ -z "$HASH" ]]; then
        die "Failed to generate password hash. Is Docker running?"
    fi

    # Write user to database
    # If users_database.yml has "users: {}", replace it
    if grep -q "^users: {}$" "$USERS_DB"; then
        cat > "$USERS_DB" << USERSEOF
users:
  ${USERNAME}:
    disabled: false
    displayname: "${USERNAME}"
    password: "${HASH}"
    email: ${EMAIL}
    groups:
      - admins
USERSEOF
    else
        # Append user
        cat >> "$USERS_DB" << USERSEOF
  ${USERNAME}:
    disabled: false
    displayname: "${USERNAME}"
    password: "${HASH}"
    email: ${EMAIL}
    groups:
      - admins
USERSEOF
    fi

    success "User '${USERNAME}' added (email: ${EMAIL})"
    echo ""
    echo "  After enabling MFA, this user can register their YubiKey/TOTP at:"
    echo "  http://<server>/authelia/"
    echo ""
}

# ── Enable MFA ───────────────────────────────────────────────────────────────
enable_mfa() {
    # Check that at least one user exists
    if grep -q "^users: {}$" "$USERS_DB" 2>/dev/null; then
        die "No users configured. Add a user first:\n  bash scripts/setup-mfa.sh add-user <username> <email>"
    fi

    ensure_secrets
    configure_domain

    info "Starting Authelia MFA services..."

    cd "$ROOT_DIR"

    # Detect which compose files are active
    local COMPOSE_CMD="docker compose -f docker-compose.yml"
    if [[ -f docker-compose.gh200.yml ]] && docker compose -f docker-compose.yml -f docker-compose.gh200.yml config >/dev/null 2>&1; then
        # Check if GH200 override is being used
        if docker inspect ai-comfyui 2>/dev/null | grep -q "gh200"; then
            COMPOSE_CMD+=" -f docker-compose.gh200.yml"
        fi
    fi
    COMPOSE_CMD+=" -f docker-compose.auth.yml"

    eval "$COMPOSE_CMD up -d"

    success "MFA enabled!"
    echo ""
    echo "  Users can now register their security keys at:"
    echo "  http://<server>/authelia/"
    echo ""
    echo "  Supported methods:"
    echo "    1. YubiKey / FIDO2 hardware key (WebAuthn)"
    echo "    2. TOTP app (Google Authenticator, Authy, etc.)"
    echo ""
    echo "  To restart with MFA:"
    echo "    ${COMPOSE_CMD} up -d"
    echo ""
}

# ── Disable MFA ──────────────────────────────────────────────────────────────
disable_mfa() {
    info "Disabling MFA — reverting to standard auth..."

    cd "$ROOT_DIR"
    docker compose -f docker-compose.yml -f docker-compose.auth.yml down authelia 2>/dev/null || true

    # Restart without auth overlay
    docker compose up -d

    success "MFA disabled. Standard Open WebUI auth is active."
}

# ── Status ───────────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo "MFA Status"
    echo "──────────────────────────────────────"

    # Check if Authelia container is running
    if docker inspect -f '{{.State.Running}}' ai-authelia 2>/dev/null | grep -q true; then
        success "Authelia is running"
        local HEALTH
        HEALTH="$(docker inspect -f '{{.State.Health.Status}}' ai-authelia 2>/dev/null || echo 'unknown')"
        info "Health: ${HEALTH}"
    else
        warn "Authelia is not running"
        echo "  Enable with: bash scripts/setup-mfa.sh enable"
    fi

    # List users
    echo ""
    echo "Configured users:"
    if [[ -f "$USERS_DB" ]] && ! grep -q "^users: {}$" "$USERS_DB"; then
        grep "^  [a-zA-Z]" "$USERS_DB" | sed 's/:$//' | while read -r user; do
            echo "  - ${user}"
        done
    else
        echo "  (none)"
    fi

    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    add-user)
        add_user "${1:-}" "${2:-}"
        ;;
    enable)
        enable_mfa
        ;;
    disable)
        disable_mfa
        ;;
    status)
        show_status
        ;;
    "")
        # Interactive setup
        banner \
            "AI Stack — MFA Setup" \
            "" \
            "This will configure multi-factor authentication" \
            "with support for:" \
            "  - YubiKey / FIDO2 hardware keys (WebAuthn)" \
            "  - TOTP apps (Google Authenticator, Authy, etc.)" \
            "" \
            "You'll need to create at least one admin user."

        echo ""
        read -r -p "  Enter admin username: " ADMIN_USER
        read -r -p "  Enter admin email: " ADMIN_EMAIL

        [[ -z "$ADMIN_USER" ]] && die "Username cannot be empty"
        [[ -z "$ADMIN_EMAIL" ]] && die "Email cannot be empty"

        add_user "$ADMIN_USER" "$ADMIN_EMAIL"

        echo ""
        read -r -p "  Enable MFA now? [Y/n] " ENABLE_NOW
        case "${ENABLE_NOW:-Y}" in
            [Nn]*) info "MFA configured but not enabled. Run: bash scripts/setup-mfa.sh enable" ;;
            *)     enable_mfa ;;
        esac
        ;;
    *)
        echo "Usage: bash scripts/setup-mfa.sh [command]"
        echo ""
        echo "Commands:"
        echo "  (none)     Interactive setup (create user + enable)"
        echo "  add-user   Add a user:  bash scripts/setup-mfa.sh add-user <name> [email]"
        echo "  enable     Start Authelia MFA services"
        echo "  disable    Stop MFA, revert to basic auth"
        echo "  status     Show MFA status and configured users"
        exit 1
        ;;
esac

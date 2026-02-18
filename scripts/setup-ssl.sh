#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — Let's Encrypt SSL/TLS setup
# Usage: bash scripts/setup-ssl.sh your.domain.com admin@your.domain.com
#
# Prerequisites:
#   - Domain DNS A record pointing at this server's public IP
#   - Ports 80 and 443 open in firewall
#   - Stack already running: docker compose up -d
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

DOMAIN="${1:-}"
EMAIL="${2:-}"

info()    { echo "[SSL Setup]  $*"; }
success() { echo "[SSL Setup] ✓ $*"; }
die()     { echo "[SSL Setup] ERROR: $*" >&2; exit 1; }

[[ -z "$DOMAIN" ]] && die "Usage: bash scripts/setup-ssl.sh <domain> <email>"
[[ -z "$EMAIL"  ]] && die "Usage: bash scripts/setup-ssl.sh <domain> <email>"

cd "$ROOT_DIR"

# ── Step 1: start stack with HTTP only (for ACME challenge) ──────────────────
info "Ensuring stack is running with HTTP for domain verification..."
docker compose up -d nginx

# ── Step 2: obtain certificate ───────────────────────────────────────────────
info "Requesting Let's Encrypt certificate for ${DOMAIN}..."
docker compose -f docker-compose.yml -f docker-compose.ssl.yml run --rm certbot \
    certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${EMAIL}" \
    --agree-tos \
    --no-eff-email \
    -d "${DOMAIN}"

success "Certificate issued for ${DOMAIN}"

# ── Step 3: activate SSL nginx config ────────────────────────────────────────
info "Activating SSL Nginx config..."

# Substitute domain into the SSL config template
sed "s/\${DOMAIN}/${DOMAIN}/g" \
    nginx/conf.d/ai-stack-ssl.conf > nginx/conf.d/ai-stack-ssl.conf.tmp \
    && mv nginx/conf.d/ai-stack-ssl.conf.tmp nginx/conf.d/ai-stack-ssl.conf

# Disable the plain HTTP config so it doesn't conflict
mv nginx/conf.d/ai-stack.conf nginx/conf.d/ai-stack.conf.disabled 2>/dev/null || true

# ── Step 4: save domain to .env ──────────────────────────────────────────────
if grep -q "^DOMAIN=" .env 2>/dev/null; then
    sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" .env
else
    echo "DOMAIN=${DOMAIN}" >> .env
fi

# ── Step 5: restart with SSL compose override ────────────────────────────────
info "Restarting stack with HTTPS..."
docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d

success "HTTPS is live at https://${DOMAIN}"
echo ""
echo "  Auto-renewal runs inside the certbot container every 12 hours."
echo "  To renew manually: docker compose -f docker-compose.yml -f docker-compose.ssl.yml restart certbot"

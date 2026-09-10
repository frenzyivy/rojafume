#!/usr/bin/env bash
#
# One-time VPS bootstrap for the RojaFume pre-launch page.
# Ubuntu/Debian. Run once, as root or with sudo:
#
#   sudo DOMAIN=rojafume.com EMAIL=you@example.com bash deploy/setup-vps.sh
#
# It is safe to re-run: every step checks before it changes anything.
#
# What it does:
#   1. installs nginx + certbot
#   2. creates the webroot and publishes public/ into it
#   3. serves the site over plain HTTP
#   4. gets a Let's Encrypt certificate
#   5. switches to the full HTTPS config
#
# DNS must already point at this server before step 4 can succeed — Let's
# Encrypt verifies by fetching a file over the domain. See DEPLOY.md step 1.

set -euo pipefail

DOMAIN="${DOMAIN:-rojafume.com}"
EMAIL="${EMAIL:-}"
WEBROOT="/var/www/${DOMAIN%%.*}"
SITE_NAME="${DOMAIN%%.*}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[0;32m✓\033[0m %s\n' "$1"; }
die()  { printf '\n\033[0;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run this with sudo"
[[ -n "$EMAIL" ]] || die "set EMAIL=you@example.com — Let's Encrypt needs it for expiry warnings"
[[ -f "$REPO_DIR/public/index.html" ]] || die "public/index.html not found next to this script (expected at $REPO_DIR/public)"

say "Domain: $DOMAIN   webroot: $WEBROOT"

# ─── 1. Packages ─────────────────────────────────────────────────────────────
say "Installing nginx and certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot rsync >/dev/null
ok "packages ready"

# ─── 2. Webroot ──────────────────────────────────────────────────────────────
say "Publishing the page"
mkdir -p "$WEBROOT"
rsync -a --delete "$REPO_DIR/public/" "$WEBROOT/"
chown -R www-data:www-data "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} +
find "$WEBROOT" -type f -exec chmod 644 {} +
ok "$(find "$WEBROOT" -type f | wc -l) file(s) in $WEBROOT"

# Ubuntu's default site would otherwise answer for any unmatched hostname.
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    ok "removed nginx's default site"
fi

# ─── 3. Plain HTTP first ─────────────────────────────────────────────────────
# The real config references certificate files. They do not exist yet, and nginx
# refuses to start when a referenced certificate is missing — so serve HTTP
# first, which is also what Let's Encrypt needs to verify the domain.
if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    say "Serving over HTTP so Let's Encrypt can verify the domain"
    cat > "/etc/nginx/sites-available/$SITE_NAME" <<HTTPCONF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEBROOT;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
HTTPCONF
    ln -sfn "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/$SITE_NAME"
    nginx -t || die "nginx rejected the temporary HTTP config"
    systemctl reload nginx
    ok "http://$DOMAIN should now show the page"

    # ─── 4. Certificate ──────────────────────────────────────────────────────
    say "Requesting the certificate"
    echo "    If this fails, DNS is not pointing here yet. Check with:"
    echo "      dig +short $DOMAIN"
    certbot certonly --webroot -w "$WEBROOT" \
        -d "$DOMAIN" -d "www.$DOMAIN" \
        --email "$EMAIL" --agree-tos --no-eff-email --non-interactive \
        || die "certbot failed — fix DNS (see above), then re-run this script"
    ok "certificate issued"
else
    ok "certificate already present, skipping issuance"
fi

# ─── 5. Full HTTPS config ────────────────────────────────────────────────────
say "Installing the HTTPS config"
sed "s/rojafume\.com/$DOMAIN/g; s#/var/www/rojafume#$WEBROOT#g" \
    "$REPO_DIR/deploy/nginx-rojafume.conf" > "/etc/nginx/sites-available/$SITE_NAME"
ln -sfn "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/$SITE_NAME"
nginx -t || die "nginx rejected the HTTPS config — nothing was reloaded, the site is still up"
systemctl reload nginx
ok "nginx reloaded"

# Renewal: the certbot package installs a systemd timer that handles this. The
# hook makes nginx pick up the renewed certificate without a manual reload.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
ok "auto-renewal hook installed"

# ─── 6. Firewall, only if one is already active ──────────────────────────────
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow 'Nginx Full' >/dev/null
    ok "ufw: opened 80/443"
fi

say "Done"
echo "    https://$DOMAIN"
echo "    https://www.$DOMAIN  -> redirects to the apex"
echo
echo "    Check the certificate and headers:"
echo "      curl -sSI https://$DOMAIN | head -20"
echo
echo "    Then submit a real signup and confirm it reaches the sheet and the inbox."

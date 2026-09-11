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

# The vhost filename MUST end in .conf.
#
# Debian's stock nginx.conf has `include /etc/nginx/sites-enabled/*;`, which
# matches any filename — but a CloudPanel/Plesk/ISPConfig box uses
# `include /etc/nginx/sites-enabled/*.conf;` instead. On those, a file without
# the extension is SILENTLY IGNORED: nginx -t passes because the file is never
# parsed, the site is treated as an unknown host, and the catch-all vhost
# answers with 444 (connection closed, no response). Let's Encrypt then fails
# with "Error getting validation data".
#
# `.conf` satisfies both include patterns, so it is always the right choice.
SITE_FILE="$SITE_NAME.conf"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[0;32m✓\033[0m %s\n' "$1"; }
die()  { printf '\n\033[0;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# Renders the site config for this DOMAIN/WEBROOT, adapting to the nginx version.
#
# nginx gained the standalone `http2 on;` directive in 1.25.1. Ubuntu 24.04
# ships nginx 1.24, where it is an UNKNOWN DIRECTIVE and `nginx -t` fails
# outright. So on older nginx, drop it and use the classic `listen ... http2`
# parameter instead: same result, syntax the running nginx actually understands.
render_site_config() {
    local dst="$1"
    sed "s/rojafume\.com/$DOMAIN/g; s#/var/www/rojafume#$WEBROOT#g" \
        "$REPO_DIR/deploy/nginx-rojafume.conf" > "$dst"

    local ver
    ver="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [[ -n "$ver" ]] || return 0

    # If the LOWER of (ver, 1.25.1) is 1.25.1, then ver >= 1.25.1 — leave as is.
    if [[ "$(printf '%s\n' "$ver" "1.25.1" | sort -V | head -1)" != "1.25.1" ]]; then
        sed -i "s/^\( *\)http2 on;/\1# http2 on;  -- nginx $ver predates 1.25.1, so http2 is set on the listen lines/" "$dst"
        sed -i 's/^\( *\)listen 443 ssl;/\1listen 443 ssl http2;/'           "$dst"
        sed -i 's/^\( *\)listen \[::\]:443 ssl;/\1listen [::]:443 ssl http2;/' "$dst"
    fi
}

# Where does THIS nginx actually read vhosts from?
#
# Guessing the path is how the first two attempts failed. `nginx -T` dumps the
# effective config, prefixing every file it read with "# configuration file
# <path>:". Any directory that never appears there is a directory nginx ignores
# — drop a vhost in it and nginx -t still passes while the site stays invisible.
# So: ask nginx, do not assume.
detect_site_dir() {
    local dir
    while read -r dir; do
        [[ -n "$dir" && -d "$dir" && "$dir" != "/etc/nginx" ]] || continue
        # Prefer a loaded directory that already holds vhosts, so we never drop
        # a site into a snippets or modules folder.
        if grep -rlsq 'server_name' "$dir" 2>/dev/null; then
            printf '%s\n' "$dir"
            return 0
        fi
    done < <(nginx -T 2>/dev/null \
               | sed -n 's/^# configuration file \(.*\):$/\1/p' \
               | xargs -r -n1 dirname | sort | uniq -c | sort -rn | awk '{print $2}')

    printf '%s\n' /etc/nginx/sites-enabled
}


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

SITE_DIR="$(detect_site_dir)"
mkdir -p "$SITE_DIR"
VHOST="$SITE_DIR/$SITE_FILE"
ok "nginx loads vhosts from $SITE_DIR"

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

# An earlier version of this script wrote the vhost without the .conf suffix,
# where an *.conf include never picked it up. Clear it out so the two cannot
# both exist and declare the same server_name.
for legacy in "/etc/nginx/sites-enabled/$SITE_NAME" "/etc/nginx/sites-available/$SITE_NAME"               "/etc/nginx/sites-enabled/$SITE_FILE" "/etc/nginx/sites-available/$SITE_FILE"               "/etc/nginx/conf.d/$SITE_FILE"; do
    if [[ "$legacy" != "$VHOST" && ( -e "$legacy" || -L "$legacy" ) ]]; then
        rm -f "$legacy"
        ok "removed a stale copy of the vhost at $legacy"
    fi
done

# ─── 3. Plain HTTP first ─────────────────────────────────────────────────────
# The real config references certificate files. They do not exist yet, and nginx
# refuses to start when a referenced certificate is missing — so serve HTTP
# first, which is also what Let's Encrypt needs to verify the domain.
if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    say "Serving over HTTP so Let's Encrypt can verify the domain"
    cat > "$VHOST" <<HTTPCONF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEBROOT;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
HTTPCONF
    nginx -t || die "nginx rejected the temporary HTTP config"
    systemctl reload nginx || systemctl restart nginx

    # ─── 3b. Prove the vhost is really being served ──────────────────────────
    # Do NOT call certbot on faith. Let's Encrypt rate-limits failed validations
    # (5 per hostname per hour), so a wasted attempt is expensive. Put a real
    # file where the ACME challenge will go and fetch it exactly the way Let's
    # Encrypt will: plain HTTP, with this Host header.
    say "Checking the challenge path is reachable before asking for a certificate"
    mkdir -p "$WEBROOT/.well-known/acme-challenge"
    SELFTEST="rojafume-selftest-$$"
    echo "$SELFTEST" > "$WEBROOT/.well-known/acme-challenge/$SELFTEST"
    chown -R www-data:www-data "$WEBROOT/.well-known" 2>/dev/null || true

    CHALLENGE_URL="http://$DOMAIN/.well-known/acme-challenge/$SELFTEST"

    # Force the connection to this machine, but keep the Host header as the
    # real domain — the Host header is what selects the vhost.
    probe_local() {
        curl -sS --max-time 15 --resolve "$DOMAIN:80:127.0.0.1" "$CHALLENGE_URL" 2>/dev/null
    }
    # No --resolve here: real DNS over the public internet, exactly as Let's
    # Encrypt does it. (--resolve takes an IP, never a hostname.)
    probe_public() {
        curl -sS --max-time 20 "$CHALLENGE_URL" 2>/dev/null
    }

    if [[ "$(probe_local || true)" != "$SELFTEST" ]]; then
        rm -f "$WEBROOT/.well-known/acme-challenge/$SELFTEST"
        die "nginx is not serving $DOMAIN on port 80, so the certificate would fail.

       Almost always this means the vhost is not being loaded. Check which
       filenames this server's nginx actually includes:

         grep -rn 'include.*sites-enabled' /etc/nginx/nginx.conf
         ls -l /etc/nginx/sites-enabled/

       If the include ends in '*.conf', the vhost file must too — this script
       writes '$SITE_FILE', which satisfies both forms.

       Also check nothing else already claims this name:

         grep -rn 'server_name .*$DOMAIN' /etc/nginx/"
    fi
    ok "served locally"

    # Now the same fetch over the public internet. This is the one Let's Encrypt
    # actually performs, so it also catches a closed port 80 or wrong DNS.
    if [[ "$(probe_public || true)" != "$SELFTEST" ]]; then
        rm -f "$WEBROOT/.well-known/acme-challenge/$SELFTEST"
        die "the vhost works locally but not from the internet, so the certificate would fail.

       Check, in this order:
         dig +short $DOMAIN            # must be this server's public IP
         dig +short www.$DOMAIN        # the certificate covers both
         ufw status                    # 80 and 443 must be allowed
       And your VPS provider's own firewall, which sits outside the machine."
    fi
    rm -f "$WEBROOT/.well-known/acme-challenge/$SELFTEST"
    ok "reachable from the internet — safe to request the certificate"

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
render_site_config "$VHOST"
nginx -t || die "nginx rejected the HTTPS config — nothing was reloaded, the site is still up"
# reload needs nginx already running; restart covers a stopped or crashed one.
systemctl reload nginx || systemctl restart nginx
ok "nginx $(nginx -v 2>&1 | grep -oE '[0-9]+[.][0-9]+[.][0-9]+' | head -1) reloaded"

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

# ─── 7. Verify, rather than assume ───────────────────────────────────────────
# The script has claimed success at this point before while the site was in fact
# unreachable. Prove it instead.
say "Verifying the live site"
FAILED=0
for url in "https://$DOMAIN/" "https://$DOMAIN/rojafume-logo.png" "http://$DOMAIN/"; do
    code="$(curl -sS -o /dev/null -m 20 -w '%{http_code}' -L "$url" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
        ok "$url -> $code"
    else
        printf '    \033[0;31m✗\033[0m %s -> %s\n' "$url" "$code"
        FAILED=1
    fi
done

if curl -sS -m 20 -L "https://$DOMAIN/" 2>/dev/null | grep -q "RojaFume"; then
    ok "the page served is the RojaFume page"
else
    printf '    \033[0;31m✗\033[0m the page served does not look like the RojaFume page\n'
    FAILED=1
fi

if [[ "$FAILED" != "0" ]]; then
    die "the site is not serving correctly yet. Nothing above was rolled back —
       re-run this script once you have fixed the cause. Useful checks:
         nginx -T | grep -n 'server_name .*$DOMAIN'
         tail -50 /var/log/nginx/error.log
         systemctl status nginx --no-pager"
fi

say "Done — the site is live"
echo "    https://$DOMAIN"
echo "    https://www.$DOMAIN  -> redirects to the apex"
echo
echo "    Next: submit a real signup and confirm it reaches the sheet and the inbox."

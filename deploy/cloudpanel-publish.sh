#!/usr/bin/env bash
#
# Publish the page into a CloudPanel-managed site, and get out of CloudPanel's
# way while doing it.
#
#   sudo DOMAIN=rojafume.com SITE_USER=rojafume bash deploy/cloudpanel-publish.sh
#
# Use this INSTEAD of setup-vps.sh when the server runs CloudPanel (or Plesk,
# cPanel, ISPConfig). Those panels own nginx: they write the vhost, obtain the
# certificate and renew it. A hand-written vhost fights them and, as happened
# here, silently wins — serving from the wrong directory, so the panel's ACME
# challenge file is never found and SSL cannot be issued.
#
# This script only copies files and removes the conflicting vhost. It never
# writes an nginx config of its own.

set -euo pipefail

DOMAIN="${DOMAIN:-rojafume.com}"
SITE_USER="${SITE_USER:-${DOMAIN%%.*}}"
WEBROOT="${WEBROOT:-/home/$SITE_USER/htdocs/$DOMAIN}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[0;32m✓\033[0m %s\n' "$1"; }
bad() { printf '    \033[0;31m✗\033[0m %s\n' "$1"; }
die() { printf '\n\033[0;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run this with sudo"
[[ -f "$REPO_DIR/public/index.html" ]] || die "public/index.html not found under $REPO_DIR"
[[ -d "$WEBROOT" ]] || die "$WEBROOT does not exist.

       Create the site in CloudPanel first: Sites -> Add Site -> Create a
       Static Site, with domain '$DOMAIN' and site user '$SITE_USER'.
       If the site exists under a different user, pass it:
         sudo DOMAIN=$DOMAIN SITE_USER=<the site user> bash \$0"

say "Publishing to $WEBROOT"
# Keep .well-known: the panel puts its ACME challenge tokens there, and deleting
# them mid-issuance is exactly how a certificate request fails.
rsync -a --delete --exclude '.well-known' "$REPO_DIR/public/" "$WEBROOT/"
chown -R "$SITE_USER:$SITE_USER" "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} +
find "$WEBROOT" -type f -exec chmod 644 {} +
ok "$(find "$WEBROOT" -type f -not -path '*/.well-known/*' | wc -l) file(s) published"

# ─── Remove the hand-written vhost, so CloudPanel's own site takes over ──────
say "Removing any hand-written vhost for $DOMAIN"
REMOVED=0
for f in "/etc/nginx/sites-enabled/${DOMAIN%%.*}.conf" "/etc/nginx/sites-available/${DOMAIN%%.*}.conf" \
         "/etc/nginx/sites-enabled/${DOMAIN%%.*}"      "/etc/nginx/sites-available/${DOMAIN%%.*}" \
         "/etc/nginx/conf.d/${DOMAIN%%.*}.conf"; do
    if [[ -e "$f" || -L "$f" ]]; then
        # Only ever touch a file this project wrote. CloudPanel's own vhosts are
        # named after the full domain and are not matched above, but check the
        # webroot too so we can never delete a panel-managed site.
        if grep -qs '/var/www/' "$f" || [[ -L "$f" ]]; then
            rm -f "$f"; REMOVED=1
            ok "removed $f"
        else
            bad "left $f alone — it does not look like one of ours, inspect it by hand"
        fi
    fi
done
[[ "$REMOVED" == "1" ]] || ok "none found, nothing to remove"

nginx -t || die "nginx config test failed — nothing was reloaded, the other sites are still up"
systemctl reload nginx
ok "nginx reloaded"

# ─── Prove the ACME path behaves ─────────────────────────────────────────────
# The symptom that brought us here: every URL returned index.html, so Let's
# Encrypt got HTML where it expected a token. Verify that is fixed.
say "Checking the ACME challenge path"
mkdir -p "$WEBROOT/.well-known/acme-challenge"
TOKEN="cp-selftest-$$"
echo "$TOKEN" > "$WEBROOT/.well-known/acme-challenge/$TOKEN"
chown -R "$SITE_USER:$SITE_USER" "$WEBROOT/.well-known"

GOT="$(curl -sS --max-time 15 --resolve "$DOMAIN:80:127.0.0.1" \
      "http://$DOMAIN/.well-known/acme-challenge/$TOKEN" 2>/dev/null || true)"
MISS="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:80:127.0.0.1" \
      "http://$DOMAIN/.well-known/acme-challenge/definitely-absent" 2>/dev/null || true)"
rm -f "$WEBROOT/.well-known/acme-challenge/$TOKEN"

if [[ "$GOT" != "$TOKEN" ]]; then
    die "the challenge file is still not served from $WEBROOT.
       Something else is answering for $DOMAIN. Find it with:
         nginx -T | grep -n 'server_name .*$DOMAIN'
         nginx -T | grep -n 'root '"
fi
ok "challenge file served correctly"

if [[ "$MISS" == "200" ]]; then
    bad "a MISSING challenge path still returns 200 — a catch-all is rewriting
      every URL to index.html. Let's Encrypt will read that HTML as a wrong
      answer and refuse the certificate. In CloudPanel: Sites -> $DOMAIN ->
      Vhost, and make sure there is no 'try_files ... /index.html' fallback
      applying to /.well-known/."
else
    ok "a missing challenge path correctly returns $MISS, not the page"
fi

say "Done"
echo "    http://$DOMAIN is serving the page."
echo
echo "    Now issue the certificate in CloudPanel:"
echo "      Sites -> $DOMAIN -> SSL/TLS -> New Let's Encrypt Certificate"
echo "      with $DOMAIN and www.$DOMAIN, then Create and Install."

#!/usr/bin/env bash
#
# Publish the current checkout to the live webroot. Run on the VPS:
#
#   sudo DOMAIN=rojafume.com bash deploy/deploy.sh
#
# Use this when you deploy by hand (or from a cron job). If you set up the
# GitHub Actions workflow in .github/workflows/deploy.yml, that publishes on
# every push to main and you never need to run this.
#
# It pulls the latest commit, copies public/ into the webroot, and reloads nginx
# only if the site config itself changed.

set -euo pipefail

DOMAIN="${DOMAIN:-rojafume.com}"
WEBROOT="/var/www/${DOMAIN%%.*}"
SITE_NAME="${DOMAIN%%.*}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[0;32m✓\033[0m %s\n' "$1"; }
die() { printf '\n\033[0;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

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


[[ $EUID -eq 0 ]] || die "run this with sudo"
[[ -d "$WEBROOT" ]] || die "$WEBROOT does not exist — run deploy/setup-vps.sh first"

# ─── Pull ────────────────────────────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
    say "Fetching the latest commit"
    git -C "$REPO_DIR" fetch --quiet origin
    BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
    # Refuse to clobber uncommitted edits made directly on the server.
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
        die "the checkout has local changes — commit, stash or discard them first:
       git -C $REPO_DIR status"
    fi
    git -C "$REPO_DIR" reset --hard --quiet "origin/$BRANCH"
    ok "at $(git -C "$REPO_DIR" log -1 --format='%h %s')"
else
    ok "not a git checkout, publishing the files as they are"
fi

[[ -f "$REPO_DIR/public/index.html" ]] || die "public/index.html is missing"

# ─── Publish ─────────────────────────────────────────────────────────────────
# --delete so a file removed from the repo also disappears from the live site.
# Only public/ is copied: Code.gs and the design canvas must never be reachable
# over HTTP.
say "Publishing public/ to $WEBROOT"
rsync -a --delete --itemize-changes "$REPO_DIR/public/" "$WEBROOT/"
chown -R www-data:www-data "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} +
find "$WEBROOT" -type f -exec chmod 644 {} +
ok "$(find "$WEBROOT" -type f | wc -l) file(s) live"

# ─── Reload only if the site config changed ──────────────────────────────────
EXPECTED="$(mktemp)"
trap 'rm -f "$EXPECTED"' EXIT
render_site_config "$EXPECTED"

if ! cmp -s "$EXPECTED" "/etc/nginx/sites-available/$SITE_NAME"; then
    say "The nginx config changed — installing it"
    cp "$EXPECTED" "/etc/nginx/sites-available/$SITE_NAME"
    # nginx -t before reload: a bad config would otherwise take the site down.
    nginx -t || die "nginx rejected the new config; the running config is untouched and the site is still up"
    systemctl reload nginx
    ok "nginx reloaded"
else
    ok "nginx config unchanged, no reload needed"
fi

say "Live: https://$DOMAIN"

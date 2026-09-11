#!/usr/bin/env bash
#
# Read-only. Prints how this server's nginx is wired, so a vhost that will not
# load can be diagnosed without guessing. Changes nothing.
#
#   sudo bash deploy/diagnose.sh [domain]

DOMAIN="${1:-${DOMAIN:-rojafume.com}}"
hdr() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }

hdr "nginx version and status"
nginx -v 2>&1
systemctl is-active nginx 2>/dev/null || true
systemctl is-enabled nginx 2>/dev/null || true

hdr "include directives in nginx.conf"
grep -n 'include' /etc/nginx/nginx.conf || echo "  (none found)"

hdr "directories nginx ACTUALLY loads config from"
# nginx -T dumps the effective config, prefixing each file it read. This is the
# ground truth: whatever is not listed here was never parsed.
nginx -T 2>/dev/null \
  | sed -n 's/^# configuration file \(.*\):$/\1/p' \
  | xargs -r -n1 dirname | sort | uniq -c | sort -rn

hdr "files nginx loaded"
nginx -T 2>/dev/null | sed -n 's/^# configuration file \(.*\):$/\1/p' | sort

hdr "contents of /etc/nginx/sites-enabled/"
ls -la /etc/nginx/sites-enabled/ 2>/dev/null || echo "  (no such directory)"

hdr "contents of /etc/nginx/conf.d/"
ls -la /etc/nginx/conf.d/ 2>/dev/null || echo "  (no such directory)"

hdr "every server_name in the EFFECTIVE config"
nginx -T 2>/dev/null | grep -nE '^\s*(server_name|listen)\s' | sed 's/^/  /'

hdr "does anything mention $DOMAIN?"
nginx -T 2>/dev/null | grep -n "$DOMAIN" | sed 's/^/  effective: /' || true
grep -rn "$DOMAIN" /etc/nginx/ 2>/dev/null | sed 's/^/  on-disk:   /' || echo "  (nothing on disk)"

hdr "who is listening on 80 and 443"
ss -tlnp 2>/dev/null | grep -E ':80 |:443 ' || echo "  (nothing, or ss unavailable)"

hdr "local fetch with the real Host header"
curl -sS -o /dev/null -m 10 -w '  http  -> %{http_code}\n' \
     --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/" 2>&1 | tail -2

hdr "firewall"
(ufw status 2>/dev/null || echo "  ufw not installed") | head -12
(iptables -L INPUT -n 2>/dev/null | head -12) || true

hdr "done — paste everything above"

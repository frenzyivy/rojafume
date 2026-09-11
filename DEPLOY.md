# Deployment

**The site is live at <https://rojafume.com>.** This describes how it is set up
and how to change it.

## How it is wired

| | |
| --- | --- |
| Domain | `rojafume.com` + `www.rojafume.com`, DNS at GoDaddy (`ns25`/`ns26.domaincontrol.com`) |
| Server | `187.127.171.219` — Hostinger VPS, Ubuntu 24.04, running **CloudPanel** |
| Site | a CloudPanel **Static Site**, site user `rojafumee` |
| Webroot | `/home/rojafumee/htdocs/rojafume.com` |
| Certificate | Let's Encrypt, both names, issued 11 Sep 2026, auto-renewed by CloudPanel |
| Repo checkout on the server | `/opt/rojafume` |

**CloudPanel owns nginx and the certificate.** Do not hand-write nginx vhosts on
this server — see *Lessons* at the bottom for what happens when you do. Anything
that needs changing in nginx is changed in CloudPanel's **Vhost** tab.

This VPS also hosts unrelated production sites (`allianzabiz.com`,
`crm.allianzabiz.com`, `lead.allianzabiz.com`, `track.allianzatech.com`). Nothing
in this repo touches them, and nothing here should.

---

## Changing the page

Edit `public/index.html`, then:

```bash
git add -A
git commit -m "..."
git push
```

Once the GitHub Actions deploy is switched on (below), that is the whole job.
Until then, publish by hand from the server:

```bash
cd /opt/rojafume && git pull && \
  rsync -a --delete --exclude '.well-known' public/ /home/rojafumee/htdocs/rojafume.com/ && \
  chown -R rojafumee:rojafumee /home/rojafumee/htdocs/rojafume.com
```

> `--exclude '.well-known'` is not optional. Let's Encrypt writes its renewal
> tokens there. Delete that directory and the certificate quietly fails to renew,
> and the site goes insecure about 90 days later with no warning.

---

## Switching on deploy-on-push

### 1. Make a key for GitHub to use

On the VPS:

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/gh_deploy -N ""
cat ~/.ssh/gh_deploy.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo "----- copy everything below into the VPS_SSH_KEY secret -----"
cat ~/.ssh/gh_deploy
echo "----- copy everything above, BEGIN and END lines included -----"

echo "----- and this into VPS_SSH_KNOWN_HOSTS -----"
ssh-keyscan -H 187.127.171.219 2>/dev/null
```

A key of its own, rather than your personal one, means GitHub's access can be
revoked by deleting one line from `authorized_keys`.

### 2. Add the secrets

GitHub → the repo → **Settings → Secrets and variables → Actions**.

**Secrets** tab:

| Secret | Value |
| --- | --- |
| `VPS_HOST` | `187.127.171.219` |
| `VPS_USER` | `root` |
| `VPS_SSH_KEY` | the private key printed above, in full |
| `VPS_PATH` | `/home/rojafumee/htdocs/rojafume.com` |

Optional but worth setting:

| Secret | Value |
| --- | --- |
| `VPS_SSH_KNOWN_HOSTS` | the `ssh-keyscan` output — pins the server's identity |
| `VPS_PORT` | only if SSH is not on 22 |

**Variables** tab:

| Variable | Value |
| --- | --- |
| `SITE_URL` | `https://rojafume.com` |

That last one switches on the post-deploy check, which fetches the live page and
fails the run if the site did not actually update.

### 3. Test it

GitHub → **Actions** → **Deploy to VPS** → **Run workflow**. It should end with
`Live and verified: https://rojafume.com`.

The workflow reads the webroot's current owner before copying and restores it
afterwards, so files stay owned by `rojafumee` and CloudPanel keeps working.

---

## Checks

```bash
# the page, the logo, and the redirects
curl -sSI https://rojafume.com | head -5
curl -sSI https://www.rojafume.com | head -5      # -> 301 to the apex
curl -sSI http://rojafume.com | head -5           # -> 301 to https

# the certificate
echo | openssl s_client -connect rojafume.com:443 -servername rojafume.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

---

## Troubleshooting

**The page did not change after a deploy.** Check the Actions run first. If it
was green, check CloudPanel's **Varnish Cache** tab for the site — if Varnish is
on, it caches in front of nginx and will keep serving the old page.

**The certificate did not renew.** Almost always something deleted
`/home/rojafumee/htdocs/rojafume.com/.well-known/`. Re-issue from CloudPanel →
**SSL/TLS → New Let's Encrypt Certificate**, and find whatever deleted it.

**Let's Encrypt says `unauthorized` with `Invalid response … <!DOCTYPE html>`.**
The challenge path is returning the page instead of the token. Something is
applying a catch-all (`try_files … /index.html` or `/index.php`) to
`/.well-known/`. The static-site template does not do this; a PHP or
reverse-proxy template does.

**`dig` shows the wrong IP.** Your resolver is caching. Ask an authoritative
server directly: `nslookup rojafume.com ns25.domaincontrol.com`.

**Diagnosing nginx on this box.** `deploy/diagnose.sh` is read-only and prints
which directories nginx actually loads config from, every `server_name` in the
effective config, and what is listening on 80/443:

```bash
sudo bash /opt/rojafume/deploy/diagnose.sh rojafume.com
```

---

## Lessons from setting this up

Kept because they cost real time, and the next person will hit them.

**On a panel-managed server, let the panel own nginx.** `deploy/setup-vps.sh`
writes its own vhost and is the right tool on a *bare* server. Here it produced a
second vhost claiming `rojafume.com`, which shadowed CloudPanel's, served from a
different directory, and made the certificate impossible to issue — the ACME
token was written to one root and read from another.
`deploy/cloudpanel-publish.sh` exists to undo exactly that.

**"No web server responding" is not the same as "no web server".** nginx answers
unknown hostnames with `444` — connection closed, no reply — which from outside
looks identical to nothing listening. That misread is why this box was treated as
bare for the first two attempts.

**A vhost nginx never parses still passes `nginx -t`.** CloudPanel includes
`sites-enabled/*.conf`; Debian includes `sites-enabled/*`. A file without the
extension is silently ignored, and the config test reports success because it
never read the file.

**`http2 on;` needs nginx 1.25.1.** Ubuntu 24.04 ships 1.24.0, where it is an
unknown directive and `nginx -t` fails outright.

**Pick the right site type.** The first CloudPanel attempt used the PHP template,
which routes every unmatched URL to `/index.php` and proxies through port 8080.
The static template serves files straight off disk, which is what a single HTML
page needs — and what lets the ACME challenge work.

**Verify, never assume.** Every failure here was a step that had reported
success. The scripts now prove the challenge path serves a token *before* calling
certbot — Let's Encrypt rate-limits failed validations to 5 per hostname per hour
— and fetch the real page afterwards instead of printing "Done".

---

## What is deployed, and what is not

Only `public/` ever reaches the server.

| Path | Deployed? |
| --- | --- |
| `public/index.html` | yes — the page |
| `public/rojafume-logo.png` | yes — the logo |
| `apps-script/Code.gs` | no — it runs on Google's servers |
| `design/rojafume.html` | no — design reference |
| `brand/` | no — logo source files |
| `deploy/`, `.github/` | no — they *do* the deploying |

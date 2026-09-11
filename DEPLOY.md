# Going live

Domain → VPS → automatic deploys from GitHub. Follow the steps in order; each
one ends with a check, so you know it worked before moving on.

## What you need to hand

Everything is known now except your SSH login.

| | Value |
| --- | --- |
| Domain | `rojafume.com` |
| VPS | `187.127.171.219` — Hostinger, Ubuntu 24.04, reverse DNS `srv1693456.hstgr.cloud` |
| SSH | `root@187.127.171.219` (or your sudo user) |
| Let's Encrypt contact | `rojaperfumes0405@gmail.com` |

### This VPS is not a bare box — read this before running anything

Corrected 11 Sep 2026. The server already runs **CloudPanel** and hosts several
live sites, among them `allianzabiz.com`, `crm.allianzabiz.com`,
`lead.allianzabiz.com` and `track.allianzatech.com`. My first probe reported
"no web server" because nginx answers unknown hostnames with `444` (close the
connection, send nothing), which from outside is indistinguishable from nothing
listening. It is in fact a busy nginx.

Two consequences:

1. **The setup script must not disturb the other sites.** It only ever adds its
   own vhost file and reloads nginx after `nginx -t` passes, so a bad config
   cannot take the others down. All four sites above were verified still serving
   after the first run.
2. **The vhost filename must end in `.conf`.** CloudPanel's `nginx.conf` uses
   `include /etc/nginx/sites-enabled/*.conf;`, unlike Debian's stock
   `include /etc/nginx/sites-enabled/*;`. A file without the extension is
   silently ignored — `nginx -t` still passes, because the file is never parsed —
   and the site behaves as an unknown host. This is exactly what made the first
   certificate attempt fail.

To see what the box is running:

```bash
sudo ss -tlnp | grep -E ':80|:443'
grep -rn 'include.*sites-enabled' /etc/nginx/nginx.conf
ls -l /etc/nginx/sites-enabled/
```

---

## Step 1 — Point the domain at the VPS

DNS for `rojafume.com` is at GoDaddy (`ns25`/`ns26.domaincontrol.com`). Edit it
in whichever panel you already use.

### What is there now

The domain is currently attached to Shopify. Checked 10 Sep 2026:

```
rojafume.com       -> 23.227.38.32        Shopify (SHOPIFY-NET), serves the storefront
www.rojafume.com   -> shops.myshopify.com 301 -> https://rojaperfume.in/
```

`23.227.38.32` is **Shopify's** shared IP, not a server of yours. Your live
store is `rojaperfume.in`; `rojafume.com` is a second domain pointed at the same
Shopify store. Detaching it **does not affect `rojaperfume.in`**.

### Change exactly two records

| | Type | Name | Data | Action |
| --- | --- | --- | --- | --- |
| 1 | `A` | `@` | `23.227.38.32` → **`187.127.171.219`** | **edit** |
| 2 | `CNAME` | `www` | `shops.myshopify.com.` | **delete** |
| 3 | `A` | `www` | **`187.127.171.219`** | **add** |

Rows 2 and 3 are one change in two moves. **DNS does not allow a `CNAME` and an
`A` record on the same name**, so the `CNAME` for `www` has to go before the `A`
record for `www` can be added. Doing it the other way round makes the panel throw
an error that looks like a bug.

### Leave these alone

| Type | Name | Why |
| --- | --- | --- |
| `NS` ×2 | `@` | GoDaddy's nameservers. Changing these takes DNS away from this panel entirely. |
| `SOA` | `@` | Managed by the nameservers, not editable in any useful way. |
| `CNAME` | `_domainconnect` | GoDaddy Domain Connect. Harmless. |
| `CNAME` | `1576a42a-…` | Shopify's domain-ownership proof. Harmless to keep, and keeping it means re-attaching the domain to Shopify later needs no re-verification. |
| `TXT` | `_dmarc` | Email authentication (`p=reject`). Nothing to do with the website. Deleting it would weaken your email security. |

### Two things to expect

**Up to an hour of mixed results.** The existing records have a 1-hour TTL, so
resolvers that already cached `23.227.38.32` keep using it until that expires.
Some visitors will see the Shopify page and some the new page during the
changeover. This cannot be shortened after the fact — the *old* record's TTL is
what governs. If you want a fast rollback path, set both records' TTL to the
minimum (10 minutes) first, wait an hour, and then change the values.

**Tidy up Shopify afterwards.** Once the new page is live, remove
`rojafume.com` from Shopify (**Settings → Domains**). Nothing breaks if you skip
this — Shopify simply stops receiving the traffic — but leaving it attached means
Shopify keeps trying to renew a certificate for a domain it no longer serves.

### If you ever move DNS to Cloudflare

Does not apply today — you are on GoDaddy's nameservers. Noted in case that
changes, because it is an easy half-hour to lose.

Set both records to **DNS only** (grey cloud) until HTTPS is working — the
orange-cloud proxy interferes with Let's Encrypt's domain check. Afterwards you
can turn the proxy on, and if you do, set **SSL/TLS → Overview → Full (strict)**.
Any other mode ("Flexible" especially) causes a redirect loop with the config in
this repo.

### Check it

```bash
dig +short rojafume.com
dig +short www.rojafume.com
```

Both must print `187.127.171.219` and nothing else. While the old records are still
cached you may see `23.227.38.32` — that is the Shopify address, so wait for the
TTL to expire rather than assuming the edit failed. On Windows use
`nslookup rojafume.com 8.8.8.8` (asking Google's resolver sidesteps your own
machine's cache; `ipconfig /flushdns` clears it).

**Do not continue until they do.** Step 3 issues the certificate, and Let's
Encrypt proves you own the domain by fetching a file *over* that domain. Wrong
DNS means a failed certificate, and it rate-limits repeated failures.

---

## Step 2 — Push the code to GitHub  ✅ done

Already pushed: commit `f0a619b` is on `main` at
<https://github.com/frenzyivy/rojafume>. Nothing to do here.

For later changes, the loop is just:

```bash
cd "C:/Users/DELL/Downloads/RojaFume Prelaunch"
git add -A
git commit -m "..."
git push
```

> **The repo is public.** Everything in it is fine to publish, but it does mean
> anyone can read `public/index.html` and see the Apps Script endpoint URL. That
> URL only accepts writes and returns nothing about existing signups, so there is
> no secret in it — see the last note in `README.md`. The diagnostics token that
> used to sit in `apps-script/Code.gs` now lives in a Script Property, precisely
> so it is not in this repo.

---

## Step 3 — First deploy on the VPS

SSH in, clone the repo, run the bootstrap script:

```bash
ssh root@187.127.171.219

apt-get update && apt-get install -y git
git clone https://github.com/frenzyivy/rojafume.git /opt/rojafume
cd /opt/rojafume

sudo DOMAIN=rojafume.com EMAIL=rojaperfumes0405@gmail.com bash deploy/setup-vps.sh
```

That script installs nginx and certbot, publishes `public/` to
`/var/www/rojafume`, serves it over plain HTTP, requests a Let's Encrypt
certificate, then switches to the full HTTPS config. It is safe to re-run: every
step checks before it changes anything, so if the certificate step fails on DNS
you can fix DNS and run the whole thing again.

### Check it

```bash
curl -sSI https://rojafume.com | head -20
```

You want `HTTP/2 200` and a `strict-transport-security` header. Then open
<https://rojafume.com> in a browser and confirm the padlock, the logo, and that
the layout matches what you saw on localhost.

---

## Step 4 — Automatic deploys on every push

The site is live now, but updating it means SSHing in. This step makes
`git push` publish it.

### 4a. Make a key for GitHub to use

**On the VPS:**

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/gh_deploy -N ""
cat ~/.ssh/gh_deploy.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo "----- copy everything below into the VPS_SSH_KEY secret -----"
cat ~/.ssh/gh_deploy
echo "----- copy everything above, BEGIN and END lines included -----"

echo "----- and this into VPS_SSH_KNOWN_HOSTS -----"
ssh-keyscan -H "$(curl -s ifconfig.me)" 2>/dev/null
```

Give GitHub a key of its own rather than reusing your personal one. Then you can
revoke its access by deleting one line from `authorized_keys`, without locking
yourself out.

### 4b. Add the secrets

GitHub → the repo → **Settings → Secrets and variables → Actions**.

On the **Secrets** tab, **New repository secret**, four times:

| Secret | Value |
| --- | --- |
| `VPS_HOST` | `187.127.171.219` |
| `VPS_USER` | `root` (or your deploy user) |
| `VPS_SSH_KEY` | the private key printed above, in full |
| `VPS_PATH` | `/var/www/rojafume` |

Optional, both worth setting:

| Secret | Value |
| --- | --- |
| `VPS_SSH_KNOWN_HOSTS` | the `ssh-keyscan` output above — pins the server's identity so the deploy cannot be redirected to another machine |
| `VPS_PORT` | only if your SSH port is not 22 |

Then on the **Variables** tab (next to Secrets), **New repository variable**:

| Variable | Value |
| --- | --- |
| `SITE_URL` | `https://rojafume.com` |

That one switches on the workflow's last step, which fetches the live page after
deploying and fails the run if the site did not actually update. Without it the
deploy still works, just unverified.

### Check it

GitHub → **Actions** → **Deploy to VPS** → **Run workflow**. It should finish
green in about a minute, ending with `Live and verified: https://rojafume.com`.

From then on, editing `public/index.html` and pushing to `main` puts it live by
itself. Editing `README.md` or `apps-script/Code.gs` does *not* trigger a deploy
— they are not part of the site.

---

## Step 5 — The one test that matters

On the live site, submit a real signup with your own name, email and phone.

Confirm all three:

1. the page swaps to the confirmation panel
2. a row appears in the `Signups` sheet
3. the notification arrives at `rojaperfumes0405@gmail.com`

**If the page says "we could not save your details":** that is the Apps Script
backend, not the deploy — the page and the server are fine. `README.md` →
*Troubleshooting* covers it. The short version is to fill in `SPREADSHEET_ID` at
the top of `apps-script/Code.gs` and redeploy the web app with
**Manage deployments → ✏ → Version: New version**.

While you are in the sheet, delete the test rows — mine are named `DELETE ME …`
or have `@example.com` addresses.

---

## Changing the page later

```bash
# edit public/index.html
git add -A
git commit -m "Copy change: ..."
git push
```

Live about forty seconds later. Watch it in the **Actions** tab.

To roll back, revert and push — the workflow deploys whatever `main` points at:

```bash
git revert HEAD
git push
```

---

## Troubleshooting

**`dig` prints the wrong IP, or nothing.** DNS has not propagated, or the record
is wrong. Check the registrar panel again, and remember your own machine caches:
`ipconfig /flushdns` on Windows. <https://dnschecker.org> shows what the rest of
the world currently sees.

**certbot: "Timeout during connect" or "unauthorized".** Let's Encrypt could not
reach `http://rojafume.com/.well-known/acme-challenge/…`. Either DNS is not
pointing here yet, or port 80 is closed. Test all three:

```bash
dig +short rojafume.com                       # must be this server's IP
curl -sS http://rojafume.com/ | head -5       # must return the page over plain HTTP
ufw status                                    # 80 and 443 must be allowed
```

Also check your provider's own firewall. Oracle Cloud, AWS and Azure block
80/443 in a security group *outside* the machine, so `ufw` looking fine is not
enough.

**certbot: "too many failed authorizations".** Let's Encrypt rate-limits repeated
failures for the same domain, for an hour. Fix DNS, verify with `dig`, *then*
retry. Adding `--dry-run` to the certbot command tests without spending an
attempt.

**The site shows nginx's default "Welcome" page.** Another config is matching
first. `setup-vps.sh` removes the packaged default, so this means a second config
in `sites-enabled` also claims your domain:

```bash
ls -l /etc/nginx/sites-enabled/
grep -rn server_name /etc/nginx/sites-enabled/
```

**The site works but the logo is a broken image.** `rojafume-logo.png` did not
reach the webroot. `ls -l /var/www/rojafume/` should list both files; if only
`index.html` is there, re-run `sudo bash deploy/deploy.sh`.

**HTTPS works, HTTP hangs.** Port 80 is closed. Leave it open: certbot renews
through it every 60 days, and anyone typing the bare domain arrives on 80 first.

**A redirect loop.** You are behind Cloudflare with SSL mode "Flexible". Set it
to **Full (strict)**.

**The workflow fails at "Publish public/ to the webroot"** with
`Permission denied (publickey)`. The `VPS_SSH_KEY` secret does not match the
public key in `authorized_keys`. Re-copy it whole, including the
`-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END …-----` lines.

**The workflow is green but the site did not change.** Something is caching in
front of nginx, or your browser kept the HTML. The nginx config sends
`must-revalidate` for `index.html`, so it is almost certainly Cloudflare — purge
the cache there.

---

## What gets deployed, and what does not

Only `public/` is ever copied to the server. That is deliberate:
`apps-script/Code.gs` and `design/rojafume.html` stay in the repo for reference
and are never reachable over HTTP.

| Path | Deployed? |
| --- | --- |
| `public/index.html` | yes — the page |
| `public/rojafume-logo.png` | yes — the logo |
| `apps-script/Code.gs` | no — it runs on Google's servers |
| `design/rojafume.html` | no — design reference |
| `brand/` | no — logo source files |
| `deploy/`, `.github/` | no — they *do* the deploying |

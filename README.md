# RojaFume — Pre-launch page

Implementation of artboards **1a** (desktop, 1440×900) and **1b** (mobile, 390×844)
from the *RojaFume Coming Soon* design canvas, as one responsive page.

| Path | What it is |
| --- | --- |
| `public/index.html` | The page. Self-contained — no build step, no dependencies. |
| `public/rojafume-logo.png` | The logo, extracted from the design canvas. |
| `apps-script/Code.gs` | Google Apps Script backend: saves each signup to a Sheet and emails `rojaperfumes0405@gmail.com`. |
| `deploy/` | nginx config and the VPS setup/deploy scripts. |
| `.github/workflows/deploy.yml` | Publishes `public/` to the VPS on every push to `main`. |
| `design/rojafume.html` | The exported design canvas (reference only, never deployed). |
| `brand/` | Original brand logo source files (not used by the page). |

**Everything under `public/` is the website; nothing else is.** The deploy only
ever copies that one directory, so `Code.gs` and the design canvas cannot be
served over HTTP.

**Going live — domain, VPS and automatic deploys — is in [DEPLOY.md](DEPLOY.md).**
This file covers the form backend.

**The page is live at <https://rojafume.com>** over HTTPS. Deployment is
described in [DEPLOY.md](DEPLOY.md).

**The form is not saving yet.** Every request path answers correctly *except*
the one that writes to the sheet — a valid signup still comes back
`Server error`, so submissions are lost. The cause is isolated to reaching the
spreadsheet; the fix is
[Troubleshooting → fill in `SPREADSHEET_ID`](#the-reliable-fix-fill-in-spreadsheet_id).
Steps 1–4 below are the full backend setup from scratch.

---

## 1. Create the spreadsheet

1. Go to <https://sheets.new> while signed in as **rojaperfumes0405@gmail.com**.
2. Name it something like `RojaFume — Pre-launch signups`.

Signing in as that account matters: the script sends mail *as* whoever owns it,
and Gmail may filter a notification that arrives from a different address.

## 2. Add the script

1. In the sheet: **Extensions → Apps Script**.
2. Delete the placeholder `myFunction` code.
3. Paste the whole of `apps-script/Code.gs`.
4. Save (Ctrl+S).

## 3. Authorise it

1. In the function dropdown pick **`setup`**, then click **Run**.
2. Google will ask for permission — **Review permissions → choose the account →
   Advanced → Go to (project name) → Allow**. The "unverified app" warning is
   expected for your own script.
3. `setup` creates the `Signups` tab with its header row and sends one test
   email. Check that it arrived.

## 4. Deploy it as a web app

1. **Deploy → New deployment → ⚙ → Web app**.
2. Set:
   - **Execute as:** *Me*
   - **Who has access:** *Anyone* ← required; *Anyone with Google account* will block the form.
3. **Deploy**, then copy the **Web app URL** (ends in `/exec`).
4. Paste it into `public/index.html`, in the line near the bottom:

   ```js
   var ENDPOINT = '';
   ```
   becomes
   ```js
   var ENDPOINT = 'https://script.google.com/macros/s/AKfy....../exec';
   ```

To check the URL is live, open it in a browser — it should print
`{"ok":true,"service":"rojafume-signup"}`.

> Re-deploying after a code change: **Deploy → Manage deployments → ✏ → Version:
> New version → Deploy**. This keeps the same URL. Creating a *new deployment*
> gives you a different URL and you'd have to update `public/index.html` again.

## Troubleshooting

**"Sorry, we could not save your details"** while the URL itself works.

Open the `/exec` URL in a browser. If it prints `{"ok":true,...}` the deployment
is fine and the script is throwing inside `doPost`. Check **Executions** in the
Apps Script editor — the failing run logs the reason.

The usual cause is `SpreadsheetApp.getActiveSpreadsheet()` returning `null`.
It works in the editor but **not** inside an anonymous web-app request, so
`setup()` can succeed while every real signup fails. The script now handles this
by caching the spreadsheet id in Script Properties when `setup()` runs, and
reading it back via `openById()`. If you hit it:

1. Re-paste `apps-script/Code.gs`.
2. Run **`setup`** again (this caches the id).
3. **Deploy → Manage deployments → ✏ → Version: New version → Deploy.**

Editing the code alone changes nothing on the live URL — a deployed web app
keeps serving the version it was deployed at until you publish a new version.

There's also a **`diagnose`** function: run it from the editor and it pushes a
test signup through the exact `doPost` path, printing the result and the cached
spreadsheet id.

### The reliable fix: fill in `SPREADSHEET_ID`

Open the spreadsheet and copy the id out of its own URL:

```
https://docs.google.com/spreadsheets/d/THIS_LONG_PART/edit#gid=0
```

Paste it into the top of `Code.gs`:

```js
var SPREADSHEET_ID = 'THIS_LONG_PART';
```

Then redeploy (**Manage deployments → ✏ → Version: New version**). This removes
every dependence on `getActiveSpreadsheet()`, on `setup()` having run, and on
deployment ordering — the whole class of failure above disappears.

### Seeing the actual error

`doPost` deliberately answers `{"ok":false,"error":"Server error"}` so a stranger
learns nothing. To see the real reason, switch the diagnostics on:

1. Apps Script editor → **Project Settings** → **Script Properties** → **Add**
   - Property: `DEBUG_TOKEN`
   - Value: any random string, say `let-me-see-1234`
2. Send that value with a request:

   ```bash
   curl -sS -X POST "<YOUR /exec URL>"      -H "Content-Type: text/plain;charset=utf-8"      -d '{"name":"Test User","email":"test@example.com","phone":"9876543210","debug":"let-me-see-1234"}'
   ```

3. Delete the property when you are done.

The reply then carries `detail` and a `stack` excerpt (the underlying exception)
plus `configuredSpreadsheetId` and `cachedSpreadsheetId`, which together say
exactly why the sheet could not be reached. Only a request carrying that exact
value gets any of it; everyone else still sees the generic message.

Two things worth knowing:

- **No property set means the diagnostics cannot be unlocked at all**, whatever a
  caller sends. That is the normal, safe state.
- **The property is read on every request, so adding or deleting it takes effect
  immediately — no redeploy.** This is also why the token is *not* a constant in
  `Code.gs`: that file is in a public GitHub repo, and a token committed there
  would be no gate at all.

## 5. Publish the page

See **[DEPLOY.md](DEPLOY.md)** — domain DNS, the VPS, HTTPS, and deploy-on-push
from GitHub, in order with a check after each step.

The page is static, so if you ever want to host it somewhere else instead, any
static host works (Netlify drop, Vercel, GitHub Pages, cPanel). Upload the two
files in `public/` side by side, keeping them in the same folder — the logo is
referenced as a relative path. Nothing needs installing on the server.

Either way, test the live page once: submit a real signup and confirm it appears
in the sheet **and** lands in the inbox.

---

## What happens on submit

1. The browser validates name, email and phone, and shows an inline message if
   something is off.
2. It POSTs JSON to the Apps Script URL.
3. The script re-validates (client-side checks are never trusted), appends a row
   to `Signups`, and emails `rojaperfumes0405@gmail.com` with the details.
4. The form is replaced by an on-brand confirmation panel.

**Duplicates.** The copy promises "offer valid once per person", so the script
matches on email address, case-insensitively. A repeat signup gets a friendly
"you're already on the list" confirmation and does not create a second row or a
second email.

**Spam.** There's a hidden honeypot field. Bots that fill it get a normal-looking
success response but nothing is written or emailed.

**Reply-to.** Notification emails are addressed from you but reply to the person
who signed up, so you can answer straight from the inbox.

---

## Notes

- **Design fidelity.** Every element's vertical position matches the artboards
  exactly at 1440×900 and 390×844, verified by measuring rendered positions
  against the design canvas. Two deliberate departures:
  - Letter-spaced lines (`LAUNCHING SOON`, `CRAFTING SCENTED STORIES`) are
    *optically* centred. CSS letter-spacing adds a trailing gap after the last
    letter, which pulls centred text a few px left; `text-indent` cancels it.
  - The mobile artboard's rounded corners are the canvas's phone-frame mockup,
    not part of the design, so the real page is square-cornered.
- **Between the two artboards** (roughly 860–1440px, i.e. tablets and small
  laptops) the layout uses the desktop composition with fluid type. The
  breakpoint to the mobile stack is 860px.
- **No scroll**, as specified — confirmed at both artboard sizes. On unusually
  short windows the page will scroll rather than clip content.
- **The logo** is `public/rojafume-logo.png`, extracted from the design canvas at its
  native 729×528 with a transparent background. The artboards size it to 340px
  wide on desktop and 220px on mobile; the page carries the intrinsic dimensions
  on the `<img>` so nothing shifts while it loads. If you replace it, keep the
  same aspect ratio (or update the `width`/`height` attributes to match).
- **Placeholder contrast.** Placeholder text is white at 40% opacity, taken from
  the design — roughly 3.4:1 against the background, short of the WCAG 4.5:1
  guideline for body text. Every field also has a screen-reader label, so nothing
  is unreachable, but ~55% opacity would clear the bar if you want it to.
- **The endpoint URL is public.** That's inherent to this approach and fine — it
  only accepts writes and returns nothing about existing signups. It carries no
  password, so there's no secret to leak. Apps Script's own quotas cap abuse; if
  the form ever gets hammered, add a CAPTCHA or move to a host with rate limiting.
- **Font** — Poppins (300/400/500) loads from Google Fonts, matching the design.
  To remove that third-party request, self-host the `.woff2` files and swap the
  `<link>` for local `@font-face` rules.

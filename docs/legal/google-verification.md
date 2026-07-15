# Google OAuth verification — runbook

Goal: move the Watchtower OAuth app from **Testing (External)** to **In production,
verified**, so corporate (whitebit) Google accounts stop being blocked and refresh
tokens stop expiring every 7 days.

- **OAuth Client ID:** `334226468569-5kopsqbc27esmmjbsc0loe2fanoffk78.apps.googleusercontent.com`
- **Project number:** `334226468569`
- **Scopes (sensitive, not restricted):**
  - `https://www.googleapis.com/auth/calendar.readonly`

> Historical note: the app originally requested `calendar.events.readonly` +
> `calendar.calendarlist.readonly`. It now requests the single broader
> read-only scope instead — Google shows its granular-consent checkbox screen
> only for multi-scope requests, and users who left the (default-off)
> checkboxes unticked ended up "connected" without working access. One scope =
> plain Continue screen. Still sensitive, not restricted, so the verification
> class is unchanged.

Because these are **sensitive** (not *restricted*), verification needs the OAuth
consent screen + a demo video, but **not** a paid third-party security
assessment.

---

## Step 0 — Prerequisite: publish homepage + privacy policy (the real blocker)

Verification requires a homepage and a privacy-policy URL on a domain you own,
verified in Google Search Console as an *authorized domain*.

Host: **GitHub Pages on `aiwatchtowers/watchtower`**, served on the custom apex
domain **`aiwatchtowers.com`** (CNAME set via the Pages API; DNS A/AAAA records at
GoDaddy point the apex at GitHub Pages):
- Homepage: `https://aiwatchtowers.com/`
- Privacy:  `https://aiwatchtowers.com/privacy-policy.html`
- Authorized domain for the consent screen: `aiwatchtowers.com`
- Verify the domain in Search Console via a **Domain property** (DNS TXT) — covers
  all subdomains.

> **Do NOT enable Pages on the `docs/` folder.** Pages publishes the *entire*
> folder, which would expose all internal docs (plans, review-lessons, inventory)
> publicly. Use a dedicated **orphan `gh-pages` branch** with only the two pages.

> **Repo must be Pages-eligible.** GitHub Pages on a *private* repo needs a paid
> plan (Pro/Team/Enterprise). If `aiwatchtowers/watchtower` is private and not on a
> paid plan, either make a small **separate public repo** just for the site, or
> use any static host. The Google forms only need a public HTTPS URL.

### Publish via orphan `gh-pages` branch

The ready-to-serve files are `docs/legal/index.html` and
`docs/legal/privacy-policy.html`. From a clean working tree:

```sh
# stash the two HTML files somewhere outside the tree first, e.g.:
cp docs/legal/index.html docs/legal/privacy-policy.html /tmp/wt-site/

git checkout --orphan gh-pages
git rm -rf .                      # empty the branch
cp /tmp/wt-site/index.html /tmp/wt-site/privacy-policy.html .
git add index.html privacy-policy.html
git commit -m "chore(site): GitHub Pages legal pages for OAuth verification"
git push -u origin gh-pages       # push account: vadimtrunov (see project memory)
git checkout feature/task-ai-agent
```

Then: repo **Settings → Pages → Build from branch → `gh-pages` / root**.

Resulting URLs:
- Homepage: `https://aiwatchtowers.github.io/watchtower/`
- Privacy:  `https://aiwatchtowers.github.io/watchtower/privacy-policy.html`

### Verify the domain in Search Console

In [Google Search Console](https://search.google.com/search-console) add a
**URL-prefix** property for `https://aiwatchtowers.github.io/watchtower/` and
verify via the HTML-file method: download Google's
`google<hash>.html`, drop it next to the pages on the `gh-pages` branch, push,
then click Verify.

- **Authorized domain** in the consent screen: `github.io`.

---

## Step 1 — Complete the OAuth consent screen

Google Cloud Console → **APIs & Services → OAuth consent screen** (project
`334226468569`):

- **User type:** External
- **App name:** Watchtower
- **User support email:** tv88dn@gmail.com
- **App logo:** optional (adding a logo triggers extra brand verification — skip
  unless needed)
- **App domain:**
  - Application home page: `https://aiwatchtowers.com/`
  - Privacy policy link: `https://aiwatchtowers.com/privacy-policy.html`
  - Terms of service: optional
- **Authorized domains:** `aiwatchtowers.com`
- **Developer contact:** tv88dn@gmail.com

---

## Step 2 — Confirm scopes

On the **Scopes** step, ensure exactly this one is present (add via "Add or
remove scopes" if missing):

- `.../auth/calendar.readonly`

Do **not** add further scopes — fewer scopes = faster review, and a single
scope keeps the consent screen checkbox-free.

---

## Step 3 — Scope justifications (paste into the verification form)

**`calendar.readonly`**
> Watchtower reads the signed-in user's own calendars — the calendar list
> (names, primary flag, color) and calendar events (title, time, description,
> attendees) — to generate local meeting preparation and daily briefings, e.g.
> talking points and open items before each meeting. Access is strictly
> read-only; the app never creates, edits, deletes, or shares events or
> calendars. Calendar data is stored only in a local database on the user's own
> machine and is used solely to produce the user-requested
> briefing/meeting-prep output.

**Why this scope / why not narrower:** the app's core feature is summarizing
the user's upcoming meetings; it needs to read event details and know which
calendars exist. The narrower pair (`calendar.events.readonly` +
`calendar.calendarlist.readonly`) covers the same data but forces Google's
granular-consent checkbox screen (multi-scope requests only), which let users
"connect" while leaving the default-off checkboxes unticked and end up with a
broken integration. No write access is requested because the app never
modifies Google data.

---

## Step 4 — Publish to production & submit for verification

1. OAuth consent screen → **Publish app** → confirm "Push to production".
   - This alone removes the 7-day refresh-token expiry, even before verification
     completes.
2. Click **Prepare for verification** / **Submit for verification**, fill in:
   - The scope justifications above.
   - The demo video link (Step 5).
3. Submit. Google emails back; expect follow-up questions. Sensitive-scope
   review typically takes days to a few weeks.

> Note: until verification completes, whitebit's admin policy will likely keep
> blocking the app (it blocks *unverified* apps). Verification is what unblocks
> corporate accounts on this route.

---

## Step 5 — Demo video (required for sensitive scopes)

Record an unlisted YouTube video (2–4 min) showing:

1. The OAuth consent screen URL in the address bar (shows the Client ID / app
   name being reviewed).
2. Signing in and granting the two calendar scopes on Google's consent screen.
3. The app **using** each scope:
   - calendar list → the calendar picker populated from the user's calendars.
   - events.readonly → a generated meeting-prep / briefing built from real
     events.
4. Narrate that access is read-only and data stays local.

Paste the video URL into the verification form.

---

## Checklist

- [ ] Pages site live: homepage + privacy-policy reachable over HTTPS
- [ ] `github.io` (or custom domain) verified in Search Console
- [ ] Consent screen filled (name, emails, home page, privacy URL, authorized domain)
- [ ] Exactly the two read-only calendar scopes present
- [ ] Scope justifications pasted
- [ ] App pushed to **production**
- [ ] Demo video recorded and linked
- [ ] Submitted for verification

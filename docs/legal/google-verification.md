# Google OAuth verification — runbook

Goal: move the Watchtower OAuth app from **Testing (External)** to **In production,
verified**, so corporate (whitebit) Google accounts stop being blocked and refresh
tokens stop expiring every 7 days.

- **OAuth Client ID:** `334226468569-5kopsqbc27esmmjbsc0loe2fanoffk78.apps.googleusercontent.com`
- **Project number:** `334226468569`
- **Scopes (sensitive, not restricted):**
  - `https://www.googleapis.com/auth/calendar.events.readonly`
  - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`

Because these are **sensitive** (not *restricted*), verification needs the OAuth
consent screen + a demo video, but **not** a paid third-party security
assessment.

---

## Step 0 — Prerequisite: publish homepage + privacy policy (the real blocker)

Verification requires a homepage and a privacy-policy URL on a domain you own,
verified in Google Search Console as an *authorized domain*.

Host (since 2026-07): **Cloudflare Pages**, deployed from the separate private
repo **`aiwatchtowers/lending`** (`public/` dir, `wrangler.jsonc`) — a full
marketing landing, not the minimal legal pages:
- Homepage: `https://aiwatchtowers.com/`
- Privacy:  `https://aiwatchtowers.com/privacy/`
- Authorized domain for the consent screen: `aiwatchtowers.com`
- Verify the domain in Search Console via a **Domain property** (DNS TXT) — covers
  all subdomains.

> **History / gotchas:**
> - The original minimal pages (`docs/legal/index.html`,
>   `docs/legal/privacy-policy.html`) were served via GitHub Pages from an orphan
>   `gh-pages` branch of `aiwatchtowers/watchtower`. They are **superseded** by
>   the `lending` site; keep them only as reference copy.
> - That legacy GitHub Pages site must stay **disabled** (`gh api -X DELETE
>   repos/aiwatchtowers/watchtower/pages`) — its `gh-pages` branch contains a
>   `CNAME` for `aiwatchtowers.com`, so a legacy Pages rebuild re-claims the
>   apex domain and fights Cloudflare for it.
> - The old privacy URL `https://aiwatchtowers.com/privacy-policy.html` is a
>   **404** on the new site. Anything still pointing at it (consent screen,
>   docs, email templates) must use `https://aiwatchtowers.com/privacy/`.

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
  - Privacy policy link: `https://aiwatchtowers.com/privacy/`
  - Terms of service: optional
- **Authorized domains:** `aiwatchtowers.com`
- **Developer contact:** tv88dn@gmail.com

---

## Step 2 — Confirm scopes

On the **Scopes** step, ensure exactly these two are present (add via "Add or
remove scopes" if missing):

- `.../auth/calendar.events.readonly`
- `.../auth/calendar.calendarlist.readonly`

Do **not** add broader scopes — narrower scope = faster review.

---

## Step 3 — Scope justifications (paste into the verification form)

**`calendar.events.readonly`**
> Watchtower reads the signed-in user's own calendar events (title, time,
> description, attendees) to generate local meeting preparation and daily
> briefings — e.g. talking points and open items before each meeting. Access is
> strictly read-only; the app never creates, edits, deletes, or shares events.
> Event data is stored only in a local database on the user's own machine and is
> used solely to produce the user-requested briefing/meeting-prep output.

**`calendar.calendarlist.readonly`**
> Watchtower reads the list of the user's calendars (names, primary flag, color)
> so the user can choose which calendars to include in their briefings. It is
> read-only and used only to present the calendar picker and label events
> correctly.

**Why these scopes / why not narrower:** the app's core feature is summarizing
the user's upcoming meetings; it needs to read event details and know which
calendars exist. No write access is requested because the app never modifies
Google data.

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

- [ ] Site live: `https://aiwatchtowers.com/` + `https://aiwatchtowers.com/privacy/` reachable over HTTPS
- [ ] `aiwatchtowers.com` verified in Search Console (Domain property)
- [ ] Legacy GitHub Pages on `aiwatchtowers/watchtower` disabled (no CNAME conflict)
- [ ] Consent screen filled (name, emails, home page, privacy URL, authorized domain)
- [ ] Exactly the two read-only calendar scopes present
- [ ] Scope justifications pasted
- [ ] App pushed to **production**
- [ ] Demo video recorded and linked
- [ ] Submitted for verification

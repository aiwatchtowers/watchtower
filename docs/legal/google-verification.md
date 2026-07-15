# Google OAuth verification — runbook

Goal: move the Watchtower OAuth app from **Testing (External)** to **In production,
verified**, so corporate (whitebit) Google accounts stop being blocked and refresh
tokens stop expiring every 7 days.

- **OAuth Client ID:** `334226468569-5kopsqbc27esmmjbsc0loe2fanoffk78.apps.googleusercontent.com`
- **Project number:** `334226468569` (same client is shared by Calendar and Gmail —
  see `cmd/gmail.go`'s `resolveGoogleOAuthConfig`)
- **Scopes (sensitive, not restricted):**
  - `https://www.googleapis.com/auth/calendar.readonly`
- **Scope (restricted) — added 2026-07-09 for the Gmail source:**
  - `https://www.googleapis.com/auth/gmail.readonly`

> Historical note: the app originally requested `calendar.events.readonly` +
> `calendar.calendarlist.readonly`. It now requests the single broader
> read-only calendar scope instead — Google shows its granular-consent
> checkbox screen for multi-scope requests, and users who left the
> (default-off) checkboxes unticked ended up "connected" without working
> access. The combined Google connect flow (Calendar + Gmail in one consent)
> pre-selects services in the app UI and requests only the chosen scopes, and
> the app honors partial grants. Calendar remains sensitive, not restricted,
> so its verification class is unchanged.

Because the calendar scopes are **sensitive** (not *restricted*), verification needs
the OAuth consent screen + a demo video, but **not** a paid third-party security
assessment.

`gmail.readonly` **is** a *restricted* scope, which normally also requires an annual
CASA security assessment through a Google-approved third-party assessor **if the app
accesses or transmits the data through a server**. Watchtower's Gmail source sends
message bodies to the `claude`/`codex` CLI subprocess for AI processing (situation
cards, triage), which in turn calls Anthropic's/OpenAI's API — this plausibly counts
as "through a third-party server" and could still trigger the assessment requirement;
Google's own docs don't draw a bright line here. `gmail.modify` was deliberately
avoided (see `docs/superpowers/specs/2026-07-09-gmail-source-design.md`) — the Gmail
package (`internal/gmail/client.go`) only calls `users.messages.list`/`.get` (GET,
read-only), so `.readonly` is the least-privilege scope that matches actual behavior.
**Plan 3 (write-back to Gmail — clearing `UNREAD`/`INBOX` labels) will need
`gmail.modify` and will require re-authorizing every connected user plus
re-verification** — budget for that when Plan 3 is scheduled.

---

## Step 0 — Prerequisite: publish homepage + privacy policy (the real blocker)

Verification requires a homepage and a privacy-policy URL on a domain you own,
verified in Google Search Console as an *authorized domain*.

**Superseded 2026-07-10:** the site moved off the `gh-pages` branch of this repo
onto a real marketing site — separate local repo
**`wt-lending`** (a local clone of `github.com/aiwatchtowers/lending`,
`main` branch), deployed via Cloudflare Pages/Workers (see its `wrangler.jsonc`).
The `gh-pages` branch here and `docs/legal/*.html` are **stale leftovers** — do
not edit them expecting them to go live; `aiwatchtowers.com` is served entirely
from `wt-lending`.

- Homepage: `https://aiwatchtowers.com/` → `wt-lending/public/index.html`
- Privacy:  `https://aiwatchtowers.com/privacy/` (note: `/privacy/`, not
  `/privacy-policy.html`) → `wt-lending/public/privacy/index.html`
- Authorized domain for the consent screen: `aiwatchtowers.com`
- Domain verification in Search Console was already done as part of the earlier
  Calendar verification pass; re-check it's still valid before submitting if it's
  been a while.

To ship a change: edit inside `wt-lending`, commit, push to `main` — Cloudflare
Pages auto-deploys from there. `git pull` that repo first if it's been a while
(it tracks `origin/main`, independent of this repo's git history).

---

## Step 1 — Complete the OAuth consent screen

Google Cloud Console → **APIs & Services → OAuth consent screen** (project
`334226468569`):

- **User type:** External
- **App name:** Watchtower
- **User support email:** tv88dn@gmail.com
- **App logo:** skip it (adding a logo triggers extra brand verification scrutiny).
  Tried removing an already-uploaded logo mid-review on 2026-07-11 to see if it
  unblocked anything — it didn't move the needle on its own, but leave it off
  regardless since Step 1 already recommended against it.
- **App domain:**
  - Application home page: `https://aiwatchtowers.com/`
  - Privacy policy link: `https://aiwatchtowers.com/privacy/` (confirmed this is
    what's actually configured as of 2026-07-11 — not the old `/privacy-policy.html`)
  - Terms of service: optional
- **Authorized domains:** `aiwatchtowers.com`
- **Developer contact:** tv88dn@gmail.com

---

## Step 2 — Confirm scopes

On the **Scopes** step, ensure exactly these two are present (add via "Add or
remove scopes" if missing):

- `.../auth/calendar.readonly` (sensitive)
- `.../auth/gmail.readonly` (restricted)

Do **not** add further scopes — fewer/narrower scopes = faster review. In
particular, do not add `gmail.modify` until Plan 3 (write-back) actually
ships.

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

**`gmail.readonly`**
> Watchtower reads the signed-in user's own Gmail inbox (subject, sender, body,
> labels) to surface important emails alongside Slack/Jira/Calendar signals in a
> unified work inbox, and to generate AI summaries ("situations") clustering
> related messages. Access is strictly read-only; the app never sends, modifies,
> labels, archives, or deletes email. Message data is stored in a local database
> on the user's own machine. Message content may be passed to an AI model (via a
> `claude` or `codex` CLI subprocess) solely to produce the user-requested
> summary/triage output — it is not used for any other purpose, not sold, and not
> used for advertising.

**Why this scope / why not narrower:** the app needs full message content (not
just metadata) to generate accurate summaries, so `gmail.metadata` is
insufficient. `gmail.modify`/`mail.google.com` are not requested because the app
has no write, send, or delete functionality today.

**Data access tab layout (confirmed 2026-07-11):** the two calendar scopes live
under **"Your sensitive scopes"**; `gmail.readonly` lives in a separate
**"Your restricted scopes" → "Gmail scopes"** section further down the same
page — it did not disappear, it just wasn't visible in an earlier screenshot
that only scrolled to the sensitive-scopes table. The Gmail section also asks
**"What features will you use?"** (a multi-select, not free text) — selected
**"Email productivity"** + **"Email reporting and monitoring"**, and left
**"Email backup/takeout"** and **"Email client"** unchecked (Watchtower doesn't
export/back up mail and isn't a replacement mail client — it only surfaces and
summarizes).

---

## Step 3.5 — If Google flags the restricted scope for a security assessment

`gmail.readonly` is a *restricted* scope. If the verification form still requires
a CASA security assessment (because message content is relayed to an AI
provider), that is a separate, potentially paid, multi-week process through a
Google-approved third-party assessor — see [Google's restricted scope
verification docs](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification).
Decide at that point whether to pursue it, or fall back to Testing mode with a
capped list of test users (works immediately, no assessment, but refresh tokens
expire every 7 days and corporate Workspace accounts stay blocked).

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

## Step 5 — Demo video (required for sensitive/restricted scopes)

Record an **unlisted** YouTube video, ~3-5 min (longer than the old 2-4 min
Calendar-only version since Gmail adds a third scope to demonstrate). **No
voice narration — burned-in/on-screen text captions instead**, since the
required claims (read-only, local storage, AI pass-through) need to be stated
precisely and captions make that easier to get exactly right than ad-libbed
narration.

Shot list:

1. **OAuth consent screen with the address bar visible** — shows the Client ID
   / app name being reviewed
   (`334226468569-5kopsqbc27esmmjbsc0loe2fanoffk78.apps.googleusercontent.com`).
2. **Signing in and granting all three scopes** on Google's consent screen
   (calendar events, calendar list, Gmail readonly).
3. **The app using each scope**, one beat per scope:
   - calendarlist.readonly → the calendar picker populated from the user's
     real calendars.
   - calendar.events.readonly → a generated meeting-prep / briefing built from
     real events.
   - gmail.readonly → connecting Gmail in the Desktop app, then a real inbox
     situation/card built from a real email.
4. **The GitHub repo** (`https://github.com/aiwatchtowers/watchtower`) —
   scroll through the README/source briefly. Being open source is a real
   trust signal for a reviewer deciding whether to believe the read-only/
   local-storage claims — anyone can verify them in the code, not just take
   the video's word for it.
5. **Caption text to burn in** (verbatim claims the reviewer needs to see,
   timed to whichever beat they apply to):
   - "Access is read-only — Watchtower never sends, modifies, or deletes data
     in Calendar or Gmail."
   - "All data is stored locally in a SQLite database on the user's own Mac."
   - "Message/event content may be passed to an AI model (via a local `claude`
     or `codex` CLI subprocess) solely to generate the summary/briefing the
     user requested — not used for any other purpose, not sold, not used for
     advertising."
   - "Watchtower is open source — anyone can verify these claims in the code."

Paste the video URL into the verification form.

---

## Note (2026-07-10): Branding verification blocks Data access verification

Discovered while going through this for real: the new "Google Auth Platform" UI
splits verification into two sequential stages, not parallel ones —
**Verification Centre → Data access status** shows *"You need to verify and
publish your branding before you can request verification"* and its
"Prepare for verification" button is disabled until Branding clears. So the
scope-justification/demo-video submission (Steps 3-5) literally cannot start
until the Branding step below is done.

**Branding** (App name, logo, homepage, privacy policy, authorized domain) has
its own separate mini-flow on the **Branding** page → "Verification status" card
→ "View issues". Two false leads before finding the real explanation, logged in
case this recurs:
- Not a Cloudflare Bot Fight Mode block (checked Security → Events, zero
  blocked requests).
- Not the Cloudflare-injected `robots.txt` `Disallow` block for
  AI-crawler user-agents like `Google-Extended` (disabled AI Crawl Control,
  confirmed clean `robots.txt` live, issue persisted).

The real answer: selecting either radio button ("I have fixed the issues" or
"I believe that the issues found are incorrect") triggers the same message —
**"The third-party data safety team will review your verification request.
This process may take two to three working days."** — confirmed externally
too (community reports cite 2-3 business days, sometimes weeks, for this
exact flow). It is a real review, not something we can shortcut.

Confirmed via the Cloudflare GraphQL Analytics API (`firewallEventsAdaptive` /
`httpRequestsAdaptiveGroups` — see the zone's Security Events, or query
directly with the `wt-lending` project's `wrangler`-stored API token) that a
`userAgent: "Google"` crawler **does** fetch `/` and `/privacy/` live and gets
200 — so this isn't a reachability/blocking problem. Whatever runs
immediately after clicking Proceed is some shallow accept-the-resubmission
check, not the actual semantic "explains purpose" judgment; the panel keeps
showing the stale pre-rewrite issue text throughout the real (multi-day)
review, with no visible "pending" state in the Console UI — that's just a gap
in Google's own tool, not a sign the request didn't go through.

Content-wise, went through Google's documented 10-point homepage checklist
(support.google.com/cloud/answer/13807376) point by point and fixed the one
real gap found: scope justification requires "transparency for *why* you
request user data," and the homepage/privacy policy only ever said generic
"calendar" for a scope that's specifically the Google Calendar API, and never
mentioned Gmail at all despite requesting `gmail.readonly`. Fixed in
`wt-lending`: Gmail + explicit "Google Calendar" wording added to title, meta
tags, hero line, and privacy policy; a dedicated read-only data-access
disclosure sentence added to the homepage's existing privacy callout block.
All other 9 checklist items were already satisfied (own verified domain, no
redirects, full URL, privacy link present and matching, no login wall, etc).

**Practical upshot: content is now as good as it can get; budget 2-3 working
days (possibly more) for the Branding review to actually complete before Data
access (scopes) verification even unlocks, which then has its own review
timeline on top. Nothing left to do here but wait for Google's actual reply.**

---

## Checklist

- [x] Pages site live: homepage + privacy-policy reachable over HTTPS (`wt-lending`
      main @ 8e43d79, deployed 2026-07-10)
- [x] `aiwatchtowers.com` still verified in Search Console
- [x] Consent screen filled (name, emails, home page, privacy URL, authorized domain)
- [x] Privacy policy text mentions Gmail data access/use, not just Calendar
- [x] Exactly the two calendar scopes + `gmail.readonly` present (not `gmail.modify`)
- [x] Branding re-verification requested ("I believe issues are incorrect",
      2026-07-10) — **blocking**: Data access verification can't start until
      this clears (2-3 working days per Google)
- [x] Branding verification cleared (2026-07-11: Data access summary panel now
      reachable — it was gated behind Branding clearing, so this confirms it passed)
- [x] `gmail.readonly` confirmed present (under "Your restricted scopes" →
      "Gmail scopes", separate section from the two sensitive calendar scopes)
- [x] Gmail "What features will you use?" selected: Email productivity +
      Email reporting and monitoring
- [ ] Scope justifications pasted — text ready in Step 3 for all three scopes;
      confirm all three are actually saved in the Data access tab
- [ ] Confirmed whether Google requires a CASA security assessment for
      `gmail.readonly` given the AI-subprocess pass-through; decided go/no-go
- [ ] App pushed to **production**
- [ ] Demo video recorded (unlisted YouTube, captions not voice, shot list in
      Step 5 — includes a GitHub repo beat) and linked in the verification form
- [ ] Submitted for verification

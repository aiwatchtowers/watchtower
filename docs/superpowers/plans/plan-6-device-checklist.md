# Watchtower Mobile — Device Checklist (owner-run, closes Plan 6)

The end-to-end pass on real hardware: one Mac with a signed desktop build, one
iPhone with the TestFlight build, same Apple ID. Every step names its expected
observable outcome — if you see something else, that step is the finding.

## Prerequisites (user gates from Tasks 1 and 7)

- **Signing (Task 1 gate):** `WatchtowerMobile/Signing.xcconfig` filled with
  your `DEVELOPMENT_TEAM`; project opened once in Xcode with automatic signing
  so the portal has the iCloud container + provisioning profiles.
- **TestFlight (Task 7 gate):** ASC app record for
  `com.aiwatchtowers.watchtower.mobile`, `make mobile-archive` run, build
  1.0 (1) uploaded (Organizer or Transporter) and enabled for internal
  testing. Exact steps: `.superpowers/sdd/task-7-report.md`, section 5.
- **Desktop identity:** a Developer ID Application certificate in the
  keychain AND a Developer ID provisioning profile that includes the iCloud
  container `iCloud.com.aiwatchtowers.watchtower` (portal → Profiles →
  Developer ID), exported to a file. Without the embedded profile, macOS
  kills a Developer ID app that carries CloudKit entitlements at launch.
- **Accounts:** Mac and iPhone signed in to the **same Apple ID**, iCloud
  Drive enabled.
- **BYOK key at hand** for steps 7–9: an `sk-ant-…` Anthropic API key.

**Live-API smoke status: PENDING — never run green as of 2026-07-07.** The
frozen BYOK wire format has not yet met the real server (the Kit suite shows
it as "2 tests skipped"). Run it once, ideally before this pass:

```
ANTHROPIC_LIVE_KEY=sk-ant-... make smoke-live
```

Expect: `Executed 2 tests, with 0 failures` (costs a few cents on haiku; the
key is read from the environment only, never persisted). If it fails, STOP —
that is a wire-format finding, not a device problem.

## The pass

### 1. Desktop signed build

Do:
```
WATCHTOWER_PROVISION_PROFILE=/path/to/profile.provisionprofile \
CODESIGN_IDENTITY="Developer ID Application: <you>" make app
```

Expect: the log shows real-identity signing (NOT "Ad-hoc code signing (dev
mode)") and NO warning about a missing provisioning profile. The app
launches. **No macOS permission (TCC) dialog appears at any point** — any TCC
prompt from Watchtower.app is a P0, stop and report it.

### 2. Enable Mobile sync

Do: Watchtower (Mac) → Settings → Mobile → toggle **Enable Mobile Sync**.

Expect: Status flips "Starting…" → **"Running"** (green) within seconds.
The hub now publishes slices and writes a heartbeat to your private zone
every ~5 minutes — the heartbeat's observable proof is negative: the phone's
"Mac unreachable" banner must NOT appear while the Mac is awake (step 6).
If Status shows "Unavailable — <reason>" instead, the reason must name the
actual problem (no iCloud account / entitlement missing); it re-probes every
10 minutes and starts by itself once fixed.

### 3. Phone install

Do: iPhone → TestFlight app (same Apple ID) → install Watchtower 1.0 (1).

Expect: install completes; the flat navy watchtower icon is on the home
screen.

### 4. First launch — zero-config hydration

Do: launch the app; sit on the Today tab for a moment.

Expect, all four at once:
- Real rows appear (your briefing / inbox items / tasks — recognizably your
  data, not the demo set) with no configuration step of any kind.
- Settings tab shows **Sync: iCloud** (a signed build that shows "Demo" means
  the entitlement probe failed — signing finding).
- **NO notification storm**: zero notifications fire during first sync, even
  though historical urgent items are being hydrated (the alert watermark arms
  at first hydrate).
- **NO permission prompt**: nothing is asked on cold launch; Settings
  Notifications row reads "Not requested".

### 5. Swipe action lands on the Mac

Do: phone Inbox tab → swipe an item → Resolve.

Expect: the row immediately shows the pending (queued) overlay on the phone.
Within ~5–10 s (desktop relay poll) the SAME item flips to resolved on the
Mac's Inbox tab. On the phone, the overlay clears on the next hydrate cycle
(≤ 30 s) as the resolved state syncs back.

### 6. Chat via relay

Do: phone Chat tab → new chat → ask e.g. "What happened today?".

Expect: the answer streams in chunk by chunk, produced by the desktop AI
(the Mac is doing the work). No banner, no chip — plain relay chat.

### 7. Mac asleep → unreachable banner + BYOK offer

Do first: iOS Settings → Offline agent → paste the `sk-ant-…` key, pick a
model (Sonnet recommended). Then put the Mac to sleep (or quit Watchtower).
Send another chat message. Wait ~45 seconds.

Expect: after ~45 s with no chunk, an inline "Mac unreachable" banner appears
at the pending reply, offering **"Answer directly"** (it offers "Set up
offline agent…" instead only when no key is saved). The typed message and
draft are never lost.

### 8. Direct answer streams

Do: tap "Answer directly" → confirm for this conversation.

Expect: the answer streams straight from the Anthropic API. The thread
toolbar now shows the **Direct API** chip (with a "Back to Mac relay"
action), and the sessions list marks the conversation with the bolt glyph.
The switch never happens silently — only via this explicit confirm.

### 9. Create a task via the chat tool (still direct)

Do: in the same direct conversation, ask "Create a task to review the
quarterly report tomorrow".

Expect: the agent confirms the creation in chat; the phone's Tasks tab shows
the new task with a **pending** overlay — queued for the Mac, which is still
asleep.

### 10. Mac wakes — queue drains

Do: wake the Mac, let Watchtower run (Settings → Mobile: "Running").

Expect: the created task appears on the Mac's Tasks tab within the relay poll
interval; on the phone the pending overlay clears on the next hydrate. The
chat can be switched back via "Back to Mac relay".

### 11. Urgent inbox item → local notification (the contextual ask)

Do: on the desktop, get a genuinely NEW high-priority pending inbox item
published (wait for a real one, or set an existing pending item's priority to
high — the next publish cycle tags it "urgent"). **Keep the app FOREGROUNDED
for this first pass**: the one-time permission dialog cannot present to a
backgrounded app, and the storm-safe watermark advances regardless — a
backgrounded first pass would silently skip this item's alert (the prompt
would only surface on the next foreground). Background the phone only for
re-runs AFTER "Allowed".

Expect: at the FIRST genuinely-new alertable row since install, the phone
asks for notification permission **once** — this contextual moment is the
only time it ever asks. Allow → a local notification **"Urgent inbox item"**
with the message snippet appears (silent-push wake; allow up to a minute
backgrounded, or ≤ 30 s foreground via the fallback poll). Settings
Notifications row flips to "Allowed". A re-publish of the SAME item must NOT
alert again.

### 12. Briefing notification (next morning, passive)

Expect: the first publish of the day's briefing raises **"Your briefing is
ready"** exactly once; later re-publishes of the same briefing stay silent.

### 13. Optional — failure visibility (quota/no-account paths)

Do: sign out of iCloud on the Mac (or toggle iCloud Drive off) briefly.

Expect: Settings → Mobile Status shows "Unavailable — <reason>" naming the
account problem, never a silent stall; after signing back in it returns to
"Running" on its own (≤ 10 min re-probe). The phone meanwhile shows the
stale-Mac behavior from step 7, not an error crash.

## Where to report

Findings go to the Plan 6 residual ledger
(`docs/superpowers/plans/2026-07-07-mobile-app-plan-6-notes.md`) or straight
to a fix branch if load-bearing. Known soft spots to keep in mind while
running: `build/` is shared between `make app-dev` and `make mobile-archive`
(a dev desktop build wipes the archive), and cadence numbers (5 s relay /
30 s hydrate / 5 min heartbeat / 45 s banner) are v1 defaults awaiting
exactly this device observation.

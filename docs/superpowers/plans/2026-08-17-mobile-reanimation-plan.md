# Mobile Reanimation Plan — 2026-08-17

> **Status 2026-08-17 (same day):** Workstreams 1–4 and item 14 SHIPPED —
> PRs #121 (recording), #123 (accounts), #122 (feature satellite),
> #120 (digests + stream_digest), #119 (payload guard), all merged into
> `mobile-app`. Remaining: item 15 (TestFlight/device gate) and the
> deferred list below. Per-workstream residual notes live in the PR bodies
> and specs.

Branch `mobile-app` is caught up with main as of 2026-08-17 (merge `70b4d3b2`;
the WatchtowerKit-vs-WatchtowerCore model split is resolved — shared models
live in WatchtowerKit, Core depends on Kit). This plan covers the remaining
gap between the phone and main's crystallized feature set, in priority order.

Owner decisions already made (2026-08-17):

- **Accounts on the phone are read-only.** No OAuth connect, no manage —
  those cannot work from the phone; only deep links open the relevant app.
  The phone just shows what is connected and its health.
- **Feature Manager: the phone is a satellite.** It mirrors the desktop's
  enabled/disabled state; no toggling from the phone.
- **Phone recording is MUST-HAVE.** Record audio on the phone; on sync the
  file moves to the Mac, which transcribes it with the existing pipeline.
  No on-phone transcription.

## Workstream 1 — Phone recording → Mac transcription (must-have)

The phone records meeting/voice audio; the file lands in the Mac's existing
recordings pipeline as if it had been recorded locally, and the transcript
comes back to the phone as the existing `meeting_transcript` slice.

1. **Kit: recording transfer envelope.** New RelayZone record type
   `recording_upload` carrying a `CKAsset` (audio file) + metadata JSON
   (client id, started/ended timestamps, duration, title hint, sample
   format). CKAsset handles large payloads — this bypasses the 1 MB record
   limit that slices have. Wire format frozen by a literal test fixture,
   like every other relay type.
2. **Phone: capture.** AVAudioSession + AVAudioRecorder (AAC ~64 kbps mono);
   `audio` background mode so recording survives lock/background; interruption
   handling (calls). Files persisted locally first (survive app kill), with
   an explicit list of not-yet-uploaded recordings.
3. **Phone: upload.** Enqueue `recording_upload` into RelayZone when the
   file is final; retry on push failure; delete the local copy only after
   the hub acknowledges (existing relay ack pattern). Show upload state per
   recording (waiting / uploading / delivered / failed).
4. **Hub: ingest.** MobileHubService downloads the asset and drops
   `<file>.m4a` + `.meta` sidecar into `MeetingRecorderCenter`'s recordings
   directory, then lets the existing orphan-recovery path enqueue batch
   transcription (transcriber dual paths: batch, not live). Verify the
   sidecar fields orphan recovery needs; do NOT invent a second ingestion
   path.
5. **Round trip.** Once transcription completes, the transcript reaches the
   phone via the existing `meeting_transcript` slice — no new sync work.
   Recordings screen shows the phone-originated recording's state:
   recorded → uploaded → transcribing (best-effort) → transcript ready.
6. **Tests.** Kit envelope fixtures; hub ingest test (asset → recordings dir
   → recovery picks it up — TestDatabase level); phone upload state machine
   incl. the degenerate branches (zero-length recording, upload retry after
   kill, ack after local delete). Near-midnight date fields: seed from
   time.Now()/Date(), no hardcoded dates.

OPEN (owner): recording UX on the phone — dedicated Record button on the
Recordings tab (voice-memo style) vs also a quick action from Today. Default
until decided: Record button on Recordings tab only.

## Workstream 2 — Accounts status in Settings (read-only)

7. **Publisher: accounts slices.** Publish `slack_accounts`,
   `google_accounts`, `jira_accounts` as new slice kinds (desktop-writes-only
   DataZone, `SELECT` projection: label/team or email/site, status, error,
   enabled; NO tokens, NO secrets — projection test asserts the column set).
8. **Phone: Settings section.** "Connected accounts" list grouped by service
   with status badges (green/orange/red + error tooltip-equivalent), mirroring
   the desktop's Connections tab semantics. No actions except deep links
   (e.g. open Slack app). Hidden when the hub has no account slices yet
   (older desktop).
9. **Account-scoped correctness.** With account context finally on the
   phone, wire the namespaced-vs-bare id rule (`SlackID` mirror): inbox
   per-account scoping (#110) badges where the phone shows Slack-derived
   rows with 2+ workspaces connected.

## Workstream 3 — Feature visibility satellite

10. **Publisher: feature state slice.** Publish the feature registry's
    effective enabled/disabled map (id → enabled) as a `feature_state` slice
    on change (Feature Manager, PR #114).
11. **Phone: honor it.** Hide/show tabs and sections by feature id (targets,
    tracks, briefing, day-plan, secretary-inbox, digests, recordings ↔
    meetings). Default when the slice is absent: everything visible
    (backward compatible). Navigation fallback mirrors the desktop's
    (selected tab disappears → fall back to Today).

## Workstream 4 — Digests on the phone

12. **Stream digests publishing.** `digest`/`digest_topic` slices already
    sync; stream digests do not — add the `stream_digest` slice kind (same
    projection discipline).
13. **Phone: Digests reading UI.** A Digests surface (list → digest detail
    with topics/decisions). Read-only; `read_at` marking relayed with the
    existing action pattern. Where it lives in the tab structure is gated by
    Workstream 3 (digests can be off).

## Workstream 5 — Ship gates & tech debt

14. **Payload size guard in the publisher.** Pre-check the encoded record
    size; oversized → skip + mark (so the diff does not believe it
    published) + log with the row identity. Kills the `.limitExceeded`
    retry-forever hole. `notes_md`/`chapters_json` stay unbounded otherwise.
15. **TestFlight.** plan-6-device-checklist.md path: signing, iCloud
    entitlements on a device build, `ANTHROPIC_LIVE_KEY=… make smoke-live`
    (MUST before any user-facing ship), first TestFlight build.

## Deferred (unchanged from the gap review)

People-cards UI, Ideas & Notes, Catch-up ack, Meeting Prep card,
desktop-authored chat turns syncing down, Slack markup rendering in
snippets, remote push from the Mac. Not in this wave.

## Ordering & PR shape

One PR per workstream into `mobile-app` (merge commits, never squash).
Workstream 1 may split into two PRs (Kit+hub / phone UI) if it grows.
Suggested order: 1 → 2 → 3 → 4 → 5, with 14 allowed to ride along with
whichever PR touches the publisher first (7 or 10 — likely 7).

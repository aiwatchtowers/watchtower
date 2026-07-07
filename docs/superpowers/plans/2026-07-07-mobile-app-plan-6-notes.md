# Plan 6 (Packaging) — Residual Ledger

The mobile feature is functionally complete after Plan 6 (branch
`feature/mobile-app-plan-6`): real CloudKit on both halves behind the
entitlement probe, desktop `notifyLevel` tagging + phone local notifications,
the key-gated live-API smoke, and the TestFlight archive lane. This file is
the surviving to-do surface: everything consciously deferred, plus small
code-level items from the Plan 6 task reviews. The end-to-end device pass is
scripted separately in `plan-6-device-checklist.md`.

## Verification debt (do these first)

1. **Live-API smoke has NEVER run green** — the frozen BYOK wire format has
   still not met the real Anthropic server. Skip-path is proven (Kit suite:
   `Executed 228 tests, with 2 tests skipped`); the live pass waits on the
   owner's key:
   `ANTHROPIC_LIVE_KEY=sk-ant-... make smoke-live`
   (expect `Executed 2 tests, ... 0 failures`, ~a few cents on haiku).
   MUST be green once before any user-facing ship. Accepted deviation inside
   the suite: `DirectAPIAgent` has no maxTokens knob, so the tool-round test
   rides the 8192 ceiling — billing is actual output tokens, not the ceiling.
2. **Device pass** — `plan-6-device-checklist.md`, owner-run (needs the T1
   signing gate + T7 TestFlight upload gate done first).
3. **Dev-sim key volatility (Plan 5 carry)** — signed dev builds should now
   get a real Keychain thanks to the T1 entitlements. Verify on a signed
   device build that the BYOK key survives relaunch, then delete the DEBUG
   in-memory `APIKeyStore` fallback if possible.

## Deferred by plan decision (out of v1 scope)

4. **Calendar-conflict `notifyLevel`** — a third level for calendar conflicts
   needs the day-plan conflict engine; the wire field is optional and open
   for new raw values (Decision 3).
5. **Cadence tuning** — RelayFeed 5 s poll + hydrator 30 s loop stay as the
   fallback cadence on device v1. Tune ONLY after real-device observation
   (battery / push latency), per Decision 6. Silent pushes already do the
   fast path.
6. **ASC upload automation** — the archive lane stops at the .ipa; upload is
   a user gate (Xcode Organizer / Transporter). ASC API-key automation and
   the manual `CURRENT_PROJECT_VERSION` bump per upload (agvtool/CI
   candidate) are both out of v1 (Decision 9).
7. **"⚠️ " error-prefix removal** — the desktop still prefixes error chat
   turns for pre-flag mobile builds (Plan 4 carry). Remove once a mobile
   version floor exists (i.e. old TestFlight builds are gone).
8. **Frozen-token dead-relay mitigation** — relay-zone sweep floors at the
   mobile consumer token; the unbounded-growth mode is reachable only via a
   dead relay processor with a live publisher (a P0 in itself). If it ever
   matters: a desktop-side liveness alarm on the relay loop. Documented at
   `sweepEvents`.

## Code-level ledger (from Plan 6 task reviews)

9. **T2 — signed-sim-without-entitlements-section falls to demo**: the
   Mach-O `getsectiondata` probe treats a signed simulator binary with no
   entitlements section as unentitled → demo path. Safe direction, dev-only;
   noted in case a future dev workflow signs sim builds and wonders why demo.
10. **T4 — snippet scan is O(all items)**: `NotificationCoordinator` resolves
    the urgent-item snippet by scanning the full inbox slice per alert batch.
    Fine at replica scale; index if slices ever grow order-of-magnitude.
11. **T4 — `didReceiveRemoteNotification` returns `.newData`
    unconditionally** instead of reflecting whether the hydrate applied
    anything; iOS may deprioritize background wakes if that ever matters.
12. **T4 — demo→cloudKit watermark inheritance**: switching the SAME on-disk
    replica from demo to cloudKit transport inherits the alert watermark
    (dev-sim only scenario; TestFlight installs start clean).
13. **T6 — refusal copy is stored in history**: the "model returned no
    answer" substitute copy persists as the turn's durable record
    (adjudicated acceptable — it IS what the user saw).
14. **T7 — `build/` dir is shared between `app-dev` and `mobile-archive`
    lanes**: a `make app-dev` rerun silently wipes
    `build/WatchtowerMobile.xcarchive` + the export. Re-archive before
    uploading if desktop builds happened in between; separate output dirs if
    it bites twice.
15. **T7 — desktop restricted entitlements need an embedded provisioning
    profile**: entitlements alone get a Developer ID .app killed by amfid;
    `scripts/build-app.sh` embeds `$WATCHTOWER_PROVISION_PROFILE` and warns
    loudly when unset. Profile creation (portal → Profiles → Developer ID,
    with the iCloud container) is part of the user gate.
16. **T7 — icon is a CoreGraphics render, not sips compositing**: sips
    cannot composite; the master render follows the repo's own
    `generate-icon.swift` precedent, deterministic (SHA-verified) and
    alpha-free. Documented deviation from the plan's literal wording.
17. **God-file drift**: the sentrux god-file count moved 62→63 over Plan 6
    (baseline bump is the controller's pre-PR step, established flow). The
    plan's largest additions are `NotificationTests.swift` (364 lines) and
    `NotificationCoordinator.swift` (263); `ChatView.swift` is now 720 lines
    and remains the standing split candidate (banner/backend-affordance
    sub-views) before the next chat feature lands.

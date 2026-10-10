# Mobile POC — handoff (2026-10-10)

The state of the mobile POC (iOS companion + Mac hub) for continuing on another Mac. Read this first, then the specs and plans it names.

## Sources of truth

- Business spec: `docs/superpowers/specs/2026-10-07-mobile-poc-business.md`; technical spec: `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` (now carries the relay `done_seq` re-echo rule and the 720 s heartbeat clamp).
- Plans: `docs/superpowers/plans/2026-10-08-mobile-poc-a-skeleton.md` (A), `…-b-workbench-remote.md` (B), `…-c-calendar-recording.md` (C). Every task lists its dependencies.
- Feature note: `docs/features/mobile-companion.md` (hub, Kit, phone, CloudKit environments, build and test).
- Inventory: `docs/inventory/workbench.md` changelog entry for the mobile writers (PROJ-05/06/12 unchanged).

## Branches

| Branch | What | State |
|---|---|---|
| `feature/mobile-poc` | Shared integration branch = `main` after the revert PR #183 + the four "Reapply" commits (#177 docs, #179 B11, #180 C3/B8 part, #181 B17). | Base for every mobile PR. |
| `feature/mobile-poc-a` | All mobile work so far (Kit, hub, phone, CI, docs) after the final whole-branch review and fix wave. | PR #184 into `feature/mobile-poc`. |
| `spike/cloudkit-share` | Throwaway S0 harness (`spikes/cloudkit-share/`: `spike.sh`, `sim.sh`, `RESULTS.md`, README). | Never merged anywhere. |

Merge rules (owner, 2026-10-09): every lane goes into `feature/mobile-poc` through a PR with main-level rules (independent review, full gate, green CI), merged on green. `feature/mobile-poc` reaches `main` in ONE PR, merged only with the owner's explicit approval. The board marks a target done only when its code is in `main`; until then `in_review`.

## Status by plan

- **A (skeleton):** A1 spike harness done. A3 Kit split, A4 private/shared scopes, A5 QR codec, A6 hub skeleton, A7 heartbeat + single-hub rule, A10 cloud signing in `build-app.sh` (now with `WATCHTOWER_CLOUDKIT_ENV`), A11 phone app shell: implemented and reviewed. Open: **A2** S0 on devices (owner), **A8** MobileLinkCenter, **A9** Settings → Mobile, **A12** phone onboarding + QR link, **A13** notifications, **A14** live-iCloud smoke (owner).
- **B (Workbench Remote):** B1 mirrors, B2 projections, B3 terminal_session + fast lane, B4 owner_ask/ask_alert slices, B5 Workbench/Now tabs, B6 report/timeline slices, B7 session screen, B8 structured answers, B9 ask answers (hub + phone), B11 `workbench target add`, B12 owner writes + board handlers, B13 board edits from the phone, B14 background session start (in `main`), B15 start/stop from the phone (hub + phone), B17 SessionLineDelivery: implemented and reviewed. Open: **B10** reply from a push (needs A13), **B16** device check (owner), **B18** session input from the phone (PROJ-16; needs A9 Allow/Revoke), **B19** device check (owner).
- **C (calendar + recording):** C1 mirrors, C2 calendar_event, C3 phone-recording ingest, C4 upload receive + recording_job, C5 meeting_transcript + segments asset, C6 recorder + uploader, C7 phone calendar, C8 recordings list/recap/transcript, C10 Go FK fix for a deleted event: implemented and reviewed. Open: **C9** device check (owner).
- **D (targets on the phone):** paused by the owner (targets model rework).
- **E (old tabs redesigned):** after A–D.

## S0 spike status (`spikes/cloudkit-share/RESULTS.md`)

- Signing: Apple Development identity exists; the Mac side builds and runs in the CloudKit **Development** environment (`./spike.sh mac`; the spike uses the real Mac App ID `com.watchtower.desktop` — a separate spike App ID without the container assigned fails with CKError 10 "Invalid bundle ID for container").
- Owner setup done: container `iCloud.com.aiwatchtowers.watchtower`; App IDs `com.watchtower.desktop` (CloudKit + Push), `com.aiwatchtowers.watchtower.mobile` (+ `.notify-service`, `.notify-content`), App Group `group.com.aiwatchtowers.watchtower.mobile`; Queryable index on `WatchtowerRecord.kind` (Development).
- Simulator run: (d) same Apple ID PASS; (e) DataZone alert PASS (~1.5 s), AlertZone alert delivered (~1 s; tapped).
- Still needed on a **real iPhone** (data cable) **plus a second Apple ID**: (a), (b), (c), (d) different Apple IDs, (e) lock screen / background delivery. A8 needs (c)/(d); A13 needs (b)/(e).

## CloudKit environments (important)

A Developer ID–signed Mac runs in CloudKit **Production**; a Debug phone build runs in **Development**. They see different databases. Dev pairing: sign the Mac with Apple Development (`WATCHTOWER_CLOUDKIT_ENV=Development`), or use a Production phone build (TestFlight/archive) with the Developer ID Mac — and deploy the schema (CloudKit Console → Deploy Schema Changes) before the first Production run.

## Setting up another Mac

1. Clone the repo; `make hooks` (pre-push leak check).
2. Xcode 16+ / Swift 6+, xcodegen. Sign Xcode into the Apple ID of the team (Settings → Apple Accounts).
3. For the Mac hub with iCloud: a Developer ID profile for `com.watchtower.desktop` with the container, kept OUTSIDE the repo; set `WATCHTOWER_PROVISION_PROFILE` to its path (or use `WATCHTOWER_CLOUDKIT_ENV=Development` with Apple Development signing).
4. Phone: copy the `Signing.xcconfig` template in `WatchtowerMobile/` and fill in your team (the file is gitignored). Inner loop: `make mobile-build`, `make mobile-test MOBILE_FILTER=<Class>`, `make kit-test FILTER=<Class>`.
5. iPhone: connect with a data cable, Trust, enable Developer Mode (Settings → Privacy & Security). A managed Mac with endpoint device control may block USB data entirely (the phone only charges).
6. Simulator note (Xcode 27): DeviceHub's embedded view ignores clicks; open the simulator in its own window. Text entry: copy on the Mac, then `pbpaste | xcrun simctl pbcopy booted` and Paste.

## Next steps, in order

1. Merge PR #184 into `feature/mobile-poc` on green.
2. S0 on devices (A2): build the spike for the iPhone (`spikes/cloudkit-share`, see README), run (a)–(e) with two Apple IDs, record in `RESULTS.md`.
3. Then A8 → A9 → A12 → A13 → B10 → B18; then the owner device checks A14, B16, B19, C9.
4. Final PR `feature/mobile-poc` → `main` with the owner's approval.

## Deferred to device checks or owner calls

- Persist the phone's link (part of A12); wire `resendInFlightAfterWipe` (A12/S0).
- Kit batch asset memory on very large hydrations; capture continuing across an audio-route change (product call).
- Per-tick read costs on the hub (B2/B3/B6), sidecar/segment fallbacks (B-T9, C-T5), a few doc minors from the re-reviews.
- Take-over and relay rules are verified on stubs only — check on two Macs and a device.
- The new CI Mobile job: if it is red only on suite time, cut it to build + lint.
- Split the five mobile files acknowledged as hub files (fan-out > 30) in `.sentrux/god-files-source.txt` by PR #184: `MeetingTranscriptSlice.swift`, `TerminalSessionSlice.swift` (hub), `AskFormModel.swift`, `AgendaModel.swift`, `BoardTargetDetailModel.swift` (phone).

## Working rules used so far (keep them)

- Subagent-driven development: one implementer per worktree, an independent reviewer per task, fix rounds until approved; reviewers read-only and time-boxed; one Desktop (ML-linking) build at a time.
- Inner-loop tests only per task; the full gate (`make test`, `make test-swift`, `make lint-all`, `make mobile-test`, `make kit-test`) once per phase and before each PR.
- TDD, bounded waits in concurrency tests (a regression must fail, not hang), mutation checks after the commit.
- The repo is public: no real ids, names, emails, team ids, certificate serials or local paths in commits, docs or PRs. Everything in the repo is English.

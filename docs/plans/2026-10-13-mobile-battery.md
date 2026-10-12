# Mobile battery drain — plan (board #724)

**Symptom (owner, 2026-10-12):** the iPhone app used ~10% battery over a day with ~10 min of screen time; iOS Settings → Battery shows 0 min background, and the owner doubts that.

**Goal:** cut the phone's energy use without losing anything the owner relies on today: asks arrive at once, the board, sessions and calendar stay current while the app is open, and the Mac shows as online.

## What the code does today (read-only audit, 2026-10-13)

Phone (`WatchtowerMobile`, `WatchtowerKit/WatchtowerSync`):

1. **Foreground fetch loop every 5 s** on Now/Workbench (30 s on Calendar) — `RootTabView.fetchInterval`, `AppEnvironment.restartLoop`. Each cycle is a CKSyncEngine fetch **plus** a forced `recordZoneChanges` poll of both zones **plus** a relay poll: 2–3 CloudKit round-trips every 5 s even when nothing changed. The radio never idles while the screen is on. It pauses on `.background` but not on `.inactive`.
2. **Every silent push runs a full `refresh()`** (`AppDelegate.didReceiveRemoteNotification`): engine fetch + forced zone poll + relay poll + heartbeat check, on top of CKSyncEngine's own automatic fetch for the same push (`automaticallySync` is left on), so the fetch runs twice. A cold background launch also runs the whole `bootstrap()`.
3. **Every replica write re-decodes everything**: the `slice_records` observations (workbench snapshot, calendar with meeting transcripts, recordings) track the whole table and keep running in the background, so even a heartbeat write decodes every board, session, ask, comment and transcript payload.
4. **Upload retry on every launch**: `RecordingUploader.uploadPending()` re-saves the audio asset (up to ~90 MB) of every recording still `uploading` on each process start, background launches included. One recording stuck there costs a full upload per wake.
5. **A paused capture keeps the audio session active** (and the 100 ms ticker running) with no time limit; with the `audio` background mode the app can then stay alive in the background.

Mac (`MobileHubService`, the push source — every DataZone/RelayZone write the Mac makes becomes a silent push to the phone):

6. **Heartbeat every 300 s** → ~288 pushes a day, whether or not anything changed.
7. **Fast lane**: a session state change, an ask, a comment or a target write publishes within 1–2 s and asks CloudKit to send at once (`sendNow`). While agents work on the Mac, session and timeline records change every few seconds, so the phone gets a steady stream of pushes all day.
8. **Mac CPU** (measured: WatchtowerDesktop averaged ~19% CPU over 1 h 40 min, the hub's readers busy in every sample): the 10 s tick rebuilds and hashes every slice; `CalendarEventSlice` sorts with a comparator that parses ISO-8601 dates on every comparison; `WorkbenchGitRefresher` runs the full `switcherSummaries` every 5 s just to list workbench ids.

**Why Battery may say "0 min background":** the CloudKit and push work largely runs in the system daemons (`cloudd`, `apsd`), which iOS charges to the system, and each push wake lasts only seconds. So the app's own background line can read 0 while it really costs energy — hence measuring first.

## Plan

### Task 1 — Measure on the phone (first, before tuning)
- Subscribe to MetricKit (`MXMetricManager`): store the daily payloads (foreground/background CPU time, cellular/Wi-Fi bytes, background audio time, launch counts) in the app group.
- Count per day: silent pushes received, fetch cycles, CloudKit requests, cold background launches, upload retries.
- Show both in Settings → Your Mac → Diagnostics (a "Battery" section: today / yesterday).
- Done when: one day on the owner's phone gives real numbers before and after the fixes.

### Task 2 — Phone: fetch only when something changed
- The foreground loop relies on pushes; the timed poll becomes a safety net (cadence per question Q1), and it pauses on `.inactive` as well.
- A push runs a light fetch: the engine fetch only, without the forced zone poll (the forced poll stays in the safety-net loop); pushes landing within a few seconds coalesce into one fetch; turn off the duplicate (CKSyncEngine's automatic fetch, or the manual one — one path, not both).
- Done when: no CloudKit request is made on an idle screen between pushes except the safety poll; Kit tests for the cadence and the coalescing.

### Task 3 — Phone: cheaper replica updates
- Observations track per-kind regions (or skip the decode when only the heartbeat changed) and are suspended in the background, then refreshed once on return to the foreground.
- Done when: a heartbeat-only write decodes nothing but the heartbeat; tests.

### Task 4 — Phone: bounded upload retry and audio teardown
- `uploadPending` retries with a backoff and a cap per recording (not on every launch), and never on a push-triggered background launch; a recording past the cap shows "Upload stuck — retry" in Recordings.
- Pausing a capture deactivates the audio session and stops the ticker; a capture paused for longer than a limit (Q4) is finished and saved automatically.

### Task 5 — Mac: fewer pushes (cadence per Q2/Q3)
- Heartbeat interval and the phone's "offline" threshold move together (Q2).
- Fast lane: an immediate send only for what the owner needs at once (asks, ask alerts, answers' echoes); session state / timeline / report changes ride a slower coalesced send (Q3).
- No publishing at all while no phone is linked.

### Task 6 — Mac: hub CPU (scope per Q5 — this PR or a separate Mac-energy target)
A wider Desktop audit (2026-10-13) also found non-hub background pollers: `CalendarViewModel`/`IdeasViewModel`/`WorkbenchNotificationCenter` 30 s polls on the main actor, the FILES FSEvents stream never stopped, three hub CLI runners on 5 s wakes. Those belong to a separate Mac target; here only the hub's own cost:
- `MeetingTranscriptSlice`: the 10 s tick reads and SHA-256s the full JSON of up to 200 transcripts; gate it on a cheap SQL fingerprint (`updated_at` + length).
- `CalendarEventSlice`: parse each date once before sorting.
- `WorkbenchGitRefresher`: list workbench ids with a light query, not `switcherSummaries`, and only when due.
- The 10 s tick skips a kind whose source tables did not change since the last tick (cheap `data_version`/max-`updated_at` check) instead of rebuilding and hashing it.
- Done when: the Desktop's idle CPU with the hub on drops to a low single-digit percent (measured with `sample`/`top` before and after).

### Docs and contracts
- `docs/features/mobile-companion.md` (fetch loop, heartbeat, fast lane) and the mobile POC spec §3/§4 are amended to the new cadences.

## Order and verification
Task 1 ships first (alone or with Task 2) so the owner gets a baseline day. Then Tasks 2–6 in one PR (`fix/724-mobile-battery`), Kit/Swift tests per task, `make kit-test`, `make mobile-test`, `make test-swift` filters, the gate before the PR. Final check by the owner: a day of normal use, the Diagnostics numbers and iOS Battery compared with the baseline.

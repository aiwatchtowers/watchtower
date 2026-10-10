# Mobile POC: technical design (sub-projects A–C)

**Date:** 2026-10-07
**Board:** umbrella #420. A skeleton #423, B Workbench Remote #424, C calendar + recording #425.
**Owner page:** `docs/superpowers/specs/2026-10-07-mobile-poc-business.md`
**UI canvas (owner-approved for A–C):** https://claude.ai/artifact/Upy7STMTaizvSR75Z4Z2Qd
**Older design this one replaces:** `docs/superpowers/specs/2026-07-05-mobile-app-design.md` on branch `mobile-app` (not on main).
**Status:** proposed. Owner decisions OD-1..OD-3 were decided on 2026-10-07 (§17), and so was linking (§2.3). Spike S0 (§13) may still change what the linking and the shared-scope pushes rely on; its fallbacks are named here.

The spec covers decisions and contracts only. File:line references were re-verified at main `b21f2c44`. Values marked *(default — owner may change)* were chosen by this spec because no one had given them.

---

## 1. Scope

**In scope:**

- **A:** the CloudKit sharing spike (S0), the transport and replica core (private and shared database scopes), the Mac hub skeleton, linking the phone to the Mac with one QR flow (§2.3), the phone shell (onboarding, tabs, Settings), notifications plumbing, and the real-device smoke.
- **B:** Workbench Remote, which has read and write parts:
  - **Read:** workbenches, sessions, board, asks, session report, timeline.
  - **Write:** ask answers, board status and priority, comments, new board target, start session, Stop, session input (gated).
- **C:** calendar agenda and event detail, phone recording, upload and Mac transcription, recordings list, recap and transcript view.

**Out of scope:**

- **D, targets (#426):** paused. Personal targets (`project_id IS NULL`) are not published and not editable. The branch's `target_done`, `target_snooze` and `task_create` action kinds stay in the enum, and the hub refuses them with `unsupported_in_poc`.
- **E, old tabs (#427):** gets its own spec after A–C.
- **#428, chat without the Mac:** a separate brainstorm.
- **Phone chat of any kind:** CHAT-* in `docs/inventory/chat.md` is untouched, and the branch's chat relay and BYOK agent are parked (§12).

---

## 2. Architecture

```
Go daemon ──SQLite──► Desktop app (Watchtower.app) ── MobileHub (opt-in) ──CKSyncEngine──┐
                        TerminalCenter, OwnerAsksViewModel,                               │
                        WorkbenchesViewModel, MeetingRecorderCenter                       ▼
                                                     Mac user's CloudKit private DB, container
                                                     iCloud.com.aiwatchtowers.watchtower
                                                     ├─ DataZone  (Mac writes, phone reads; zone share: read-only)
                                                     └─ RelayZone (phone writes requests, Mac echoes; zone share: read-write)
                                                                                          ▲
iPhone app (WatchtowerMobile) ── ReplicaStore (GRDB, app group) ── CKSyncEngine ─────────┘
  on the private DB (same Apple ID) or the shared DB (other Apple ID), chosen at the QR scan (§2.3)
  + Notification Service Extension + Notification Content Extension
```

Five rules hold everywhere:

- **The hub lives in the Desktop process.** The Go daemon never touches CloudKit, because the CloudKit frameworks are Apple-only. Every phone action needs the Desktop app running, because the PTY (`TerminalCenter`), the asks view model and the recorder all live there.
- **DataZone has one writer, the hub.** Single-hub rule: §8, I-1.
- **Each RelayZone record except the hub's own has one creator, the phone.** The Mac only rewrites a record's status (the echo). This is the branch's ack pattern.
- **Every phone write goes through the Mac's existing code paths** (§6). There is no third mutation path.
- **The phone never re-derives Mac logic.** That covers session state, colours, captions, the quick-answer eligibility and the alert decision. The Mac publishes the resolved values.

### 2.1 Packages

- `WatchtowerKit/` sits at the repo root as an SPM package: swift-tools 5.10, GRDB `from: "7.0.0"`, platforms macOS 14 and iOS 17. iOS 17 is the floor because `CKSyncEngine` needs it. The package has two library products:
  - `WatchtowerSync`: Sync, CloudKitTransport, the Relay payloads and coder, ReplicaStore and ReplicaHydrator. It contains no Watchtower models.
  - `WatchtowerKit`: the phone-only decode mirrors (§3) and UI-facing helpers. It depends on `WatchtowerSync`.
- The Desktop executable target `WatchtowerDesktop` depends on `WatchtowerSync` only. `WatchtowerCore` keeps no Kit dependency, so the Core test bundle is unchanged. The package needs no `@_exported import` and no `CoreTypeAliases.swift`.
- The phone app is `WatchtowerMobile/`, an xcodegen project (`project.yml`, regenerated with `make mobile-gen`, never edited by hand). Its identifiers:
  - App bundle id: `com.aiwatchtowers.watchtower.mobile`.
  - Extensions: `com.aiwatchtowers.watchtower.mobile.notify-service` (Notification Service Extension) and `com.aiwatchtowers.watchtower.mobile.notify-content` (Notification Content Extension).
  - App group: `group.com.aiwatchtowers.watchtower.mobile` *(default — owner may change)*. The replica and outbox live in this group container so the extensions can read them.

### 2.2 Wire

These are the branch's frozen choices and are kept as they are:

- **Record type:** `WatchtowerRecord`.
- **Fields:**
  - `kind`: plain String, also used by the subscription predicate.
  - `modifiedAt`: plain Date.
  - `encryptedValues["payload"]`: JSON Data.
  - `encryptedValues["notifyLevel"]`: String, optional.
  - `asset`: CKAsset, optional.
- **Record name:** `<kind>-<id>`.
- **Encoding:**
  - DataZone payloads: RowPayloadCoder JSON for row-shaped slices, and the same JSON conventions for computed slices (snake_case keys, sorted keys).
  - RelayZone payloads: `RelayCoder` (snake_case, Unix-second dates, sorted keys).
- **Optional keys:** a nil optional is encoded as an *absent* key (the branch's `isError` discipline).
- **Fixtures:** every new kind and every new payload field gets a frozen fixture test on both sides (Kit decode and hub encode).

### 2.3 Linking the phone to the Mac

The owner decided on one QR flow for everyone, built in A. Linking states which Mac the phone works with and is the device-consent step. The Mac's separate **Allow…** for typing (§10) stays an additional step.

**Database scope.** The phone runs in one of two scopes, chosen at the scan:

- **`private`, same Apple ID on both devices.** The phone syncs the same private database the Mac writes, as specified in the rest of this document.
- **`shared`, different Apple ID on the phone.** This is the common case of a work Mac and a personal phone. The Mac hub owns two zone-wide shares, `CKShare(recordZoneID:)`:
  - **DataZone:** the participant has read-only permission.
  - **RelayZone:** the participant has read-write permission.

  The phone accepts both shares and runs its sync engine on its **shared** database. The data stays in the Mac's Apple ID iCloud quota, phone uploads included. There is still no vendor server.

**Kit interface.** The Kit sync layer takes `CloudDatabaseScope { private, shared(ownerName) }` behind the one `CloudSyncTransport` interface from A1. `CloudKitTransport` uses the private or the shared database accordingly. In `shared` scope it never saves or deletes zones (a participant cannot), and a zone-deleted or zone-not-found event moves the phone to "unlinked" (§9). The scope and owner name are stored in the phone's `TransportStore`.

**User flow.**

1. On the Mac: Settings → Mobile, with the hub on, then **Use Watchtower on iPhone**. The Mac shows a QR code with a 10-minute countdown and a **New code** button.
2. The phone on first run shows Welcome, then "Scan the code on your Mac" (camera). The system Camera app can also open the app, because the QR is a `watchtower://link` URL.
3. The phone shows "Linked to <Mac name>", then asks for notification permission, then opens the Now tab.

**QR payload, v1.** The QR encodes the string `watchtower://link?d=<base64url(JSON)>`, with no padding. The JSON uses sorted keys:

| Key | Value |
|---|---|
| `v` | `1`. A phone that sees a higher `v` shows "Update Watchtower on this iPhone" |
| `container` | `iCloud.com.aiwatchtowers.watchtower` |
| `hub_id` | the hub's UUID (§4.1) |
| `mac_name` | ≤ 60 characters |
| `owner_user` | the Mac's `CKContainer.userRecordID().recordName` |
| `nonce` | 32 random bytes, base64url, 43 characters. Single use |
| `iat`, `exp` | Unix seconds; `exp = iat + 600` *(default — owner may change)* |
| `data_share`, `relay_share` | `CKShare.url` strings of the two zone shares. Present only when the Mac could create the shares; absent otherwise |

The payload stays under 700 bytes, which fits a QR at error-correction level M. The Mac keeps `link_codes(nonce PRIMARY KEY, issued_at, exp, used_by_device, used_at)` in `hubstate.db`. It is pruned to the newest 50 rows, and an expired unused code is never reusable *(default)*.

**What the phone does on a scan:**

1. It decodes the payload and checks `v` and `container`. If `exp < now`, it shows "This code expired — Show a new code on the Mac".
2. It checks `CKContainer.accountStatus()`. If the status is not `.available`, it shows "Sign in to iCloud on this iPhone to use Watchtower".
3. It reads its own `userRecordID().recordName`.
   - **Equal to `owner_user`:** `private` scope. Any share URLs are ignored, since an owner cannot accept their own share.
   - **Different:** `shared` scope. It runs `CKFetchShareMetadataOperation` on both URLs, then `CKAcceptSharesOperation`. If either URL is absent or fails, it shows "This Mac can't share with another Apple ID right now — Show a new code on the Mac".
4. It writes its `device` record (§5.1) with `link_nonce = nonce`, `scope` and `user_record_name` into RelayZone, in its scope's database.
5. It waits up to 60 s for `device_grant-<device_id>` with `linked: true` and `hub_id` equal to the payload's. If it does not come, it shows "Your Mac didn't answer — keep Settings → Mobile open on the Mac and scan again". A grant with `link_refused` shows that reason's message.
6. A phone already linked to another hub first asks "Switch from <old Mac> to <new Mac>?". On yes it unlinks the old link (below) and then links the new one.

**What the Mac does on a `device` record carrying a `link_nonce`:**

- **Valid code.** The nonce is known, unused and `exp ≥ now`. In `shared` scope the record's `creatorUserRecordID.recordName` must also equal `user_record_name`, and the creator must be an accepted participant of both shares. Then the Mac marks the code used by this device, adds the device to the sidecar `devices` table (§10) with `scope` and `user_record_name`, and publishes `device_grant` with `linked: true`.
- **Same nonce, same device again.** This is idempotent: the grant is already `linked`.
- **Refusals:** a nonce used by *another* device gives `link_refused: used_code`; an expired code gives `expired_code`; an unknown code gives `unknown_code`. The phone shows "Show a new code on the Mac" for all three.

**The share's public link, the bearer secret.**

- The Mac creates the two zone shares the first time it shows a QR, and reuses them after that.
- It opens the public link (`publicPermission = .readOnly` on DataZone, `.readWrite` on RelayZone) only while a QR is on screen.
- It closes the link (`publicPermission = .none`) as soon as the code is used, expires, or the sheet closes.
- On closing, the Mac removes every participant that is not bound to a used nonce. A stranger who opened the URL within the window therefore loses access at once and never gets a grant.
- Spike S0(c) decides how a closed link keeps the accepted phone. The outcome is recorded in the S0 PR:
  - **Primary:** closing the public link keeps accepted participants.
  - **Fallback F2**, if closing drops them or makes them read-only:
    1. Before closing, the Mac adds each newly linked phone as a **named participant**: `CKFetchShareParticipantsOperation` with `CKUserIdentity.LookupInfo(userRecordID:)` built from the device record's `user_record_name`, with the zone's permission.
    2. It closes the link.
    3. The phone, which keeps the share URLs from the scan, re-runs metadata fetch and accept as the now-invited participant.
    4. The grant is published only after the re-accept.
  - **Fallback F3**, if F2 also fails: the link stays open, and the URL is treated as a long-lived bearer secret. Remove then deletes and recreates the shares, and every other phone must scan again. F3 ships only with the owner's written OK in the S0 PR.

**Same-Apple-ID detection** compares `owner_user` with the phone's own `userRecordID.recordName` (spike S0(d)). If S0(d) shows the values differ across platforms for one Apple ID, the fallback is this: the phone, before accepting, lists `CKContainer.privateCloudDatabase` zones and looks for `DataZone` holding `heartbeat` with the payload's `hub_id`. A match means `private` scope.

**Unlink and revoke.**

- **From the Mac,** in Settings → Mobile, the phone list shows each phone's name, Apple ID scope ("Same Apple ID" / "Shared"), link date and typing state, with **Allow…** / **Revoke** and **Remove**. Remove:
  - deletes the device from `devices`;
  - deletes its `device_grant` record;
  - in `shared` scope, removes the participant from both shares.

  From then on, relay records from that device or creator fail `device_not_linked`. A same-Apple-ID phone can still read the private database, because it is the same account. The Mac then ignores its actions, and Settings says so plainly ("Removed. It is signed into your Apple ID, so it can still read synced data until you sign it out of iCloud").
- **From the phone,** Settings → **Unlink this Mac**:
  - writes its `device` record with `unlinked: true` (best effort);
  - in `shared` scope, leaves the shares by deleting the accepted share records from its shared database;
  - stops the sync engine, wipes the replica and outbox (pending items are reported "Not sent"), and returns to Welcome.

**Failure states the UI shows:**

| Situation | Where | Text |
|---|---|---|
| Phone not signed into iCloud | phone, at the scan | "Sign in to iCloud on this iPhone to use Watchtower" |
| Mac's Mobile off, or Mac asleep (no QR can be shown) | phone, "The Mac doesn't show up" screen | A checklist: Watchtower is open on the Mac, Settings → Mobile is on, the Mac is awake, it is a signed build, iCloud is on |
| Mac iCloud off (`.noAccount`) | Mac, Settings → Mobile | "Mobile isn't available on this Mac: iCloud is off." No QR is shown |
| Mac iCloud restricted or MDM-blocked (`.restricted`) | Mac, Settings → Mobile | "Mobile isn't available on this Mac: iCloud is restricted by your organization." No QR is shown |
| Expired or used code | phone | "This code can't be used — Show a new code on the Mac" |

**Single hub when the hub owns shares.**

- I-1 (§8) still holds. Take over (same Apple ID, another Mac) issues a new `hub_id`. The new hub deletes both zone shares (which removes all participants), clears `devices` in its own sidecar, and creates new shares at its first QR.
- Every phone whose linked `hub_id` differs from the heartbeat's shows "Watchtower moved to <mac_name> — scan the code on that Mac". A `shared` phone instead loses the zones and shows "This Mac removed this phone — scan a new code".
- A Mac on a *different* Apple ID cannot see the first hub. It is simply another hub, and a phone links to exactly one hub at a time.

---

## 3. Pinned values

| What | Value |
|---|---|
| CloudKit container (all build flavors) | `iCloud.com.aiwatchtowers.watchtower` |
| Zones | `DataZone`, `RelayZone` (custom zones in the Mac user's private DB; reached by a different-Apple-ID phone through zone-wide shares in its shared DB) |
| Database scopes (Kit) | `private`, `shared(ownerName)` |
| Link QR | `watchtower://link?d=<base64url(JSON)>`, payload v1 (§2.3), valid 600 s, single-use nonce of 32 bytes *(expiry: default — owner may change)* |
| Share public link | open only while a QR is on screen, at most 600 s |
| Link grant wait on the phone | 60 s |
| Record type | `WatchtowerRecord` |
| Payload guard (hub, per record) | `maxPayloadBytes = 900_000`. Oversized records are skipped and not hashed, with a throttled warning (existing) |
| Hub full diff tick | 10 s *(default — owner may change; was 60 s on the branch)* |
| Fast lane coalescing window | 1 s; at least 2 s between two fast sends *(default)* |
| Relay poll on the Mac | 3 s while a phone action was seen in the last 300 s, otherwise 30 s (branch values), plus CKSyncEngine pushes |
| Heartbeat | written every 300 s. Phone shows the Mac "online" while `heartbeat.updated_at` is less than 720 s old (branch values) |
| Phone foreground fetch | every 5 s while Now or Workbench is on screen, 30 s otherwise; silent push plus `BGAppRefreshTask` in the background *(default)* |
| Latency target | 2–15 s from a Mac DB write to the phone screen; measured in A3 |
| Relay action max age | 7 days, then `failed`/`expired` (branch) |
| Session input and finish request expiry | 24 h after `created_at` *(default — owner may change)* |
| Session start request expiry | 24 h after `created_at` *(default — owner may change)* |
| Recording format | AAC, mono, 64 kbps, `.m4a`, `sample_format = "aac-64k-mono"` (branch) |
| Recording length cap | auto-stop at 3 h with a notice 5 min before; asset ≤ 90 MB *(default)* |
| Ask alert subscription id | `ask-alerts-v1` (private scope); `shared-db-v1` (shared scope, silent database subscription) |
| Shared-scope background refresh | `BGAppRefreshTask` requested every 15 min (`earliestBeginDate`) *(default)* |
| Notification categories | `ASK` (Open the ask), `ASK_QUICK` (content extension with options) |
| Hub sidecar dir | `~/Library/Application Support/Watchtower/MobileHub/` with `transport.db` and `hubstate.db` (branch names) |

---

## 4. DataZone slice kinds and projections

Every slice is a projection, never `SELECT *`. These columns are never published: `projects.folder_path` (raw), `terminal_sessions.claude_session_id`, `terminal_sessions.folder_path`, `agent_turn_end`, `agent_tool_run`, `meeting_transcripts.audio_path`, `speakers_json` (voice embeddings), `calendar_events.raw_json`, and any token.

**Clipping rule.** A capped text field is cut at a grapheme boundary and ends in `…`. The record then carries `<field>_clipped: true`, and a capped list carries `<list>_more: <n not shown>`.

**Record lifecycle.** The hash diff creates, updates and deletes records. A row that leaves a projection's window is deleted from the zone. Hash state lives in the sidecar `slice_state`.

The new `SliceKind` raw values are wire format and are never renamed. The branch's old cases stay in the enum, unpublished.

### 4.1 A: `heartbeat` (DataZone, Mac-written, payload extended)

`HeartbeatPayload` moves out of the dropped `ChatPayloads.swift` into its own file. Its record name stays `heartbeat`, and it **moves from RelayZone to DataZone**, so a share participant with read-write permission on RelayZone cannot rewrite it. Fields:

| Field | Notes |
|---|---|
| `updated_at` | |
| `app_version` | |
| `hub_id` | UUID, one per hub install |
| `mac_name` | `Host.current().localizedName`, ≤ 60 |
| `flavor` | `default` or `corp` |
| `last_publish_at` | |
| `last_relay_at` | |
| `relay_backlog` | unprocessed relay records seen |
| `accounts[]` | `{kind: slack\|google\|jira, label ≤ 80, status}`, ≤ 20; read-only and never a token |
| `enabled_at` | when the hub was turned on |
| `owner_user` | the Mac's `userRecordID.recordName` (§2.3) |
| `sharing` | `available` (zone shares exist), `unavailable`, or `none` (no QR shown yet) |

### 4.2 B: `workbench` (id = `projects.id`, all workbenches, ≤ 100 by latest session activity)

| Field | Source / rule | Cap |
|---|---|---|
| `id`, `name`, `description` | `projects` | name 200, description 1000 |
| `folder_display` | `folder_path` with the home prefix replaced by `~` | 300 |
| `branch`, `detached`, `changes` | `watchtower workbench git status --workbench N --json` (`WorkbenchCLI.swift:437`, PROJ-10's git). Refreshed every 120 s per workbench and on a state change of one of its sessions, at most once per 30 s per workbench. A failed run keeps the last value | branch 120 |
| `open_asks`, `open_targets`, `in_progress_targets`, `blocked_targets` | `WorkbenchQueries.switcherSummaries` (`WorkbenchQueries.swift:115`) | — |
| `done_targets` | done targets with `workbench_target_archive.archived = 0` | — |
| `session_counts` | `{working, waiting, needs_approval, finished, failed, stopped, not_running}` over the published `terminal_session` records of the workbench | — |
| `last_session_activity`, `archive_after_days` | `switcherSummaries`, `projects` | — |

Board progress on the phone is `done_targets / (open_targets + done_targets)`.

### 4.3 B: `workbench_target` (id = `targets.id`, `project_id IS NOT NULL` only, PROJ-01)

Source: `WorkbenchQueries.board` (`WorkbenchQueries.swift:309`), which gives the tree, `openComments`, `unreadForOwner` and `archived` from the `workbench_target_archive` view (PROJ-15).

**Window per workbench:**

- Every non-archived target, ≤ 2000, newest `updated_at` first.
- Archived targets whose last close is in the last 90 days, ≤ 500 *(default)*.

Archived records carry `archived: true`. The phone hides them except under the Archive filter, so they are hidden, never lost.

**Fields and caps:**

| Field | Notes | Cap |
|---|---|---|
| `id`, `workbench_id`, `parent_id`, `text` | | text 300 |
| `intent` | | 4000 |
| `status` | | |
| `priority`, `progress` | | |
| `branch`, `pr` | | 120 each |
| `archived` | | |
| `children_count` | | |
| `open_comments`, `unread_for_owner` | | |
| `open_asks` | open `owner_asks` with this `target_id` | |
| `session_ids` | sessions with this `target_id` or linked through `terminal_session_targets` | ≤ 20 |
| `last_status_at`, `last_status_actor` | the newest `target_status_history` row | |
| `work_on_prompt` | `TerminalLaunch.workOnTargetPrompt` (`TerminalLaunch.swift:88`) rendered for this target. It prefills the start sheet | 1000 |
| `created_at`, `updated_at` | | |

### 4.4 B: `workbench_comment` (id = `project_comments.id`)

Only comments on published targets, the newest 200 per target. Fields: `id`, `workbench_id`, `target_id`, `parent_id`, `author`, `agent_label` (≤ 60), `body` (≤ 4000), `status`, `created_at`, `read` (`read_at != ''`).

The phone never marks comments read *(default — owner may change)*.

### 4.5 B: `terminal_session` (id = `terminal_sessions.id`, `project_id IS NOT NULL AND kind = 'claude'`)

Sources: `TerminalSessionQueries.fetchAllWorkbenchSessions` (`TerminalSessionQueries.swift:75`), `fetchAgentStates` (`:101`), and `TerminalCenter.liveIDs` (`TerminalCenter.swift:161`). Shell sessions are not published.

**Window per workbench:** every live session, plus the newest 50 by `last_active_at`.

The state fields are **the Mac's resolved presentation**: `SessionSwitcherPresentation.State` (`WatchtowerCore/Services/SessionSwitcherPresentation.swift:6`) rendered through `SessionStatePresentation` (`WatchtowerCore/Services/SessionStatePresentation.swift:7`). The phone draws them as given and has no state rules of its own (PROJ-11's "never a stale state" stays on the Mac).

| Field | Notes | Cap |
|---|---|---|
| `id`, `workbench_id`, `title`, `target_id` | | title 200 |
| `agent` | always `claude_code` in the POC | |
| `created_at`, `last_active_at`, `state_at` | | |
| `live` | | |
| `state_kind` | `working`, `running`, `waiting_on_ask`, `needs_approval`, `finished`, `stopped`, `failed` or `not_started` | |
| `state_caption` | `SessionStatePresentation.caption` | 120 |
| `state_tone` | `green`, `orange`, `blue`, `red` or `secondary` | |
| `state_glyph` | SF Symbol name or `""` | |
| `is_ring` | | |
| `open_asks`, `oldest_ask_id`, `closed_asks` | `closed_asks` drives "▸ N closed" | |
| `finish_summary` | | 2000 |
| `agent_error` | | 60 |
| `report_target_id`, `report_done`, `report_total`, `report_pr_line` | from `watchtower workbench session-report --workbench N --summary --json` (`SessionReportCenter.swift:263`; Go `internal/sessionreport/summary.go`). Run every 60 s per workbench with live sessions and on that workbench's state changes, coalesced | pr line 120 |

The phone renders the report line as `#<report_target_id> · <done>/<total> · <report_pr_line>`, for example "#415 · 1/2 · PR #175 open".

**Fast lane.** The publisher is nudged:

- from `SessionAgentStateCenter.onChange` (`Sources/Services/SessionAgentStateCenter.swift:56`), which fires after the 1 s poll sees a change;
- from GRDB `ValueObservation` over `owner_asks`, `terminal_sessions`, `project_comments` and `targets WHERE project_id IS NOT NULL`.

Nudges coalesce for 1 s, the diff runs over the fast-lane kinds only (`terminal_session`, `owner_ask`, `ask_alert`, `workbench`, `workbench_target`, `workbench_comment`, `recording_job`), and then the hub calls `CKSyncEngine.sendChanges()` at once. Two fast sends are at least 2 s apart.

The hook is `onChange` and `onRead` from the hub. `SessionAgentStateCenter` already exposes single-closure properties, which `initWorkbenches` assigns at `AppState.swift:1703-1778`. The hub therefore wraps them: it chains to the existing closure and does not replace it.

### 4.6 B: `owner_ask` (id = `owner_asks.id`)

**Window:**

- every `open` ask;
- answered, delivered and withdrawn asks with `created_at` in the last 7 days, ≤ 50 per workbench.

Sources: `OwnerAskQueries.openAsks` / `closedAsks` (`OwnerAskQueries.swift:56,67`).

| Field | Cap / rule |
|---|---|
| `id`, `workbench_id`, `workbench_name`, `session_id`, `target_id`, `kind`, `status`, `withdrawn_reason`, `previous_ask_id`, `created_at`, `answered_at`, `delivered_at` | — |
| `title` | 200 |
| `summary`, `changes` | 4000 each |
| `payload` | the stored JSON (focus, questions, checklist; Go `internal/asks/asks.go`) as an object, ≤ 64 KiB serialized. Over the cap: `payload_clipped: true`, the payload is dropped, and the phone offers only "Open the ask on the Mac" |
| `doc_path` | relative path, 300 |
| `doc_snapshot` | review asks, open only. ≤ 256 KiB UTF-8, cut at the last newline before the cap, plus `doc_clipped: true` and `doc_bytes` (full size). Go caps a snapshot at `asks.MaxSnapshotBytes` = 2 MiB, so a cap is required. Closed asks carry no snapshot |
| `answer` | closed asks only, the stored `OwnerAskAnswer` JSON object, ≤ 64 KiB |
| `quick` | computed on the Mac. `{question_id, options: [{label, recommended}]}` when the ask is `question`, has exactly one question, `multi` is false, at least one option is `recommended`, and it has 2–4 options. Otherwise absent |

The phone can comment only on text that is shown. The Mac re-validates every answer (§5.2).

### 4.7 B: `ask_alert` (id = ask id; the push trigger, see §7)

The hub writes this record **once**, when it first sees an ask `open` with `created_at ≥ heartbeat.enabled_at`. It keeps the sidecar set `alerted_asks`, so a re-hydrate, an epoch reset or a first enable never alerts on old asks. The record is deleted when the ask leaves `open`, or 7 days after it was written. The count is bounded by `asks.MaxOpenPerWorkbench` (30) open asks per workbench.

Payload: `ask_id`, `workbench_id`, `workbench_name` (≤ 60), `session_id`, `kind`, `title` (≤ 120), `quick` (bool).

### 4.8 B: `session_report` (id = session id)

**Window:** live sessions, plus sessions with `last_active_at` in the last 7 days.

**Payload:** the output of `watchtower workbench session-report --workbench N --session S --json` (`SessionReportCenter.swift:283`; Go `internal/sessionreport/report.go`: `session`, `progress`, `on_you`, `now`, `next`, `phases`, `prs`, `pr_note`).

**Caps:**

| List | Cap |
|---|---|
| `on_you` | 30 |
| `now` | 20 |
| `next` | 20 |
| `phases` | 30, with ≤ 50 `items` each |
| `prs` | 10 |

Every text field is capped at 500, and the whole payload at ≤ 128 KiB. Past that cap, phase items are dropped oldest first and `phases_clipped: true` is set.

**Cadence:**

- on the session's state-kind change, coalesced 5 s;
- every 120 s while the session is live, with `--no-network`;
- on `session_report_request` (§5), without `--no-network`, at most once per 60 s per session.

PROJ-14 holds because the CLI already scopes the report to the session's own work.

### 4.9 B: `session_timeline` (id = session id)

Milestones run newest first, ≤ 100 per session, each `{at, kind, text ≤ 200, ref}` where `ref` is a target or ask id. Sources:

| `kind` | Source |
|---|---|
| `state` | Hub-observed resolved state-kind transitions ("Started", "Working", "Needs approval", "Stopped", "Finished", "Error: …"). The hub stores them in the sidecar table `session_milestones(session_id, at, kind, text, ref)`, pruned to 100 per session and 14 days |
| `ask_opened`, `ask_answered`, `ask_withdrawn` | `owner_asks.created_at`, `answered_at`, and `withdrawn_reason` with the record's last change |
| `target_linked` | `terminal_session_targets.first_at` |
| `target_status` | `target_status_history` rows of the linked targets after the session's `created_at` (`from_status → to_status`, actor) |
| `phase` | the session report's `phases[].started_at` and `finished_at` |
| `pr` | the session report's `prs[]` (state and number) |
| `finished` | `finished_at` plus `finish_summary` |

Subagent events have no stored source today, so they are not in the POC timeline (OD-3, decided: later). The raw Claude Code transcript is never read for the phone.

### 4.10 C: `calendar_event` (id = `calendar_events.id`)

**Window:** `start_time` from local today 00:00 minus 1 day, to plus 14 days *(default)*. `event_status = 'cancelled'` is excluded. At most 500 events, earliest first *(default)*.

**De-duplication:** events with the same non-empty `ical_uid` and the same `start_time` are published once, as the row with a `conference_url`, or else the lowest `id`.

| Field | Cap / rule |
|---|---|
| `id`, `start_time`, `end_time`, `is_all_day`, `is_recurring`, `event_status`, `organizer_email`, `html_link`, `conference_url` | — |
| `title`, `location` | 300 each |
| `description` | plain text, 2000 |
| `attendees[]` | ≤ 100, each element reduced to its email, display name and response status keys as stored |
| `prep_bullets[]` | from `meeting_prep_cache.result_json` (Go `internal/meeting/pipeline.go`): `talking_points[].text`, then `suggested_prep[]`. First 8, each ≤ 300 |
| `prep_generated_at` | — |
| `linked_targets[]` | `{id, text ≤ 200, status}`, ≤ 20, read-only. These are targets created from the event's transcripts' action items (`chapters_json` `converted_target_id`), restricted to `project_id IS NULL` (PROJ-01 holds) |

### 4.11 C: `meeting_transcript` (id = `meeting_transcripts.id`)

**Window:** `created_at` in the last 30 days, or its event is in the calendar window. At most 200 transcripts, newest first *(default)*.

**Fields:** `id`, `event_id`, `title` (300), `duration_sec`, `created_at`, `updated_at`, `phone_recording_id` (from the sidecar map, §6.4), `speakers[]` (display names only, ≤ 20).

**Recap fields:** `summary`, `key_decisions[]`, `action_items[]` and `open_questions[]`, each list ≤ 50 entries of ≤ 500. The source:

- `meeting_recaps.recap_json`, joined `r.transcript_id = t.id OR (r.event_id IS NOT NULL AND r.event_id = t.event_id)`. This fixes the branch's event-only join (00056).
- Otherwise `summary_json` for ad-hoc recordings.

`chapters_json.overall_summary` is published as `overview` (2000).

**Transcript body:** always a CKAsset `segments.json` holding `[{start_sec, end_sec, speaker, text}]` for the non-deleted segments. A legacy row without `segments_json` becomes one segment holding `transcript_text`. The asset is ≤ 20 MB, else it is clipped with `segments_clipped: true`. The record hash covers the payload and the segment content.

`notes_md` and chapters other than the overview are not published *(default)*.

### 4.12 C: `recording_job` (id = the phone's recording upload id)

Fields:

- `status`: `received`, `queued`, `transcribing`, `diarizing`, `summarizing`, `done` or `failed`.
- `percent`: 0–100, from `ProcessingJob.Phase.transcribing(done:total:)` in `MeetingRecorderCenter.swift`, while `transcribing`.
- `transcript_id` once done, `error` (≤ 300), `updated_at`.

The record is kept 7 days after `done` or `failed`, at most 100 records. It is a fast-lane kind.

### 4.13 B: `device_grant` (id = device id)

The hub's view of each phone that wrote a `device` record (§5.1), at most 20 devices: `device_id`, `hub_id`, `name` (≤ 60), `scope` (`private` or `shared`), `linked`, `link_refused` (absent, `used_code`, `expired_code` or `unknown_code`), `linked_at`, `typing_allowed`, `start_sessions_allowed`, `decided_at`.

The phone's Settings reads it ("Waiting for your Mac to confirm" / "Allowed"). The link flow reads it too (§2.3). A removed device's record is deleted.

---

## 5. RelayZone records

### 5.1 Kinds

| `RelayRecordKind` | Record name | Creator | Notes |
|---|---|---|---|
| `action` (existing) | `action-<uuid>` | phone (or the content extension) | §5.2 |
| `recording_upload` (existing) | `recupload-<uuid>` | phone | §5.3 |
| `device` (new) | `device-<device_id>` | phone | `{device_id (UUID, Keychain-stored, survives reinstall), name ≤ 60, model, app_version, scope, user_record_name, link_nonce?, unlinked?, typing_requested, start_sessions, updated_at}`. The Mac never rewrites it and answers through the `device_grant` slice (§4.13). A new scan rewrites it with the new `link_nonce` |

`heartbeat` is no longer a relay kind; it is in DataZone (§4.1). The enum case stays for wire compatibility.

### 5.2 `action` payload and echoes

`ActionRequestPayload` keeps its branch fields: `id`, `kind`, `entity_id`, `params`, `created_at`, `status`, `error_message`. It gains three:

- `device_id`
- `reason`, a closed code on a failure, hold or expiry
- `result`, an object written by the Mac

`id` is a phone-generated UUIDv4. It is **the idempotency key**, and the record name carries it.

`ActionStatus` (wire, new cases added) is one of `pending`, `received`, `held`, `applied`, `failed`, `expired` or `cancelled`. Only the Mac moves a record out of `pending`. A phone build treats an unknown status as `pending`.

`reason` codes (wire):

```
not_found, not_on_board, ask_not_open, invalid_answer, invalid_params, conflict,
device_not_allowed, device_not_linked, session_not_running, agent_busy, needs_approval, prompt_has_text,
state_unknown, cannot_type, claude_not_found, expired, cancelled, outcome_unknown,
unsupported_in_poc, write_failed
```

New `ActionKind` raw values:

| Kind | `entity_id` | `params` | Mac path | Idempotent? | `result` on `applied` |
|---|---|---|---|---|---|
| `probe` | — | `{nonce}` | hub only | yes | `{nonce, hub_id}` |
| `ask_answer` | ask id | `{workbench_id, answer: {verdict, answers, checklist, comments, note}}` | §6.2 | yes (guarded `WHERE status='open'`) | `{delivery: submitted\|typed\|held\|queued\|copied\|no_session}` |
| `board_target_status` | target id | `{workbench_id, status ∈ WorkbenchBoardCard.editableStatuses, from_status}` | §6.3 | yes | `{status}` |
| `board_target_priority` | target id | `{workbench_id, priority ∈ editablePriorities, from_priority}` | §6.3 | yes | `{priority}` |
| `board_comment_add` | target id | `{workbench_id, body ≤ 4000}` | §6.3 | no | `{comment_id}` |
| `board_comment_reply` | root comment id | `{workbench_id, body ≤ 4000}` | §6.3 | no | `{comment_id}` |
| `board_target_create` | — | `{workbench_id, parent_id?, text ≤ 200, intent ≤ 4000, priority}` | §6.3 | no | `{target_id}` |
| `session_start` | target id | `{workbench_id, mode: new\|open_existing, plan_first, bring_forward, brief?}` | §6.5 | no | `{session_id, stage: starting}` |
| `session_input` | session id | `{text ≤ 4000}` | §6.6 | no | `{delivery}` |
| `session_input_cancel` | the original action id | `{}` | §6.6 | yes | `{}` |
| `session_finish_request` | session id | `{}` | §6.6 (fixed line) | no | `{delivery}` |
| `session_stop` | session id | `{}` | §6.5 | yes | `{}` |
| `session_report_request` | session id | `{}` | §4.8 | yes | `{}` |

**Processing rules:**

1. **Exactly-once handling.** The hub keeps `relay_processed(record_name, phase, outcome)` in `hubstate.db`; `outcome` holds the full echoed outcome (status, reason, result, message). A record already `done` is never dispatched again. The hub stores with `done` the relay buffer mark its pass read up to, and re-echoes the stored outcome only when the record's latest buffered change lies past that mark — a phone save made after the hub read it (the phone's copy still reads `pending` or `received` because the echo never reached it); the hub's own buffered copies are at or below the mark and are left alone, and a re-echo never counts against the per-pass batch limit. The same rule gates a `recording_upload`'s `received` re-echo and its failed-upload retry *(amended 2026-10-10, final review)*. For a **non-idempotent** kind, the hub commits `phase = begun` to the sidecar *before* the main-DB write or PTY write, and `done` after it. On hub start, a record found `begun` and not `done` is not re-applied. It is echoed `failed`/`outcome_unknown`, and the phone says "Your Mac restarted while applying this — check it on the Mac". Idempotent kinds simply re-run.
2. **Stale view guard.** A status or priority change whose `from_*` differs from the current value fails `conflict` with `result.current`. The phone then offers "Changed on the Mac to X — apply anyway?", which sends a new action with `from_*` set to the current value. A current value equal to the requested one is `applied` with no write.
3. **Board scope.** Every board kind re-checks that the target or comment belongs to `workbench_id` and is on a board (`project_id IS NOT NULL`). Otherwise it fails `not_on_board` or `not_found`.
4. **Device gate.** Every relay record must come from a linked device: its `device_id` is in the sidecar `devices` table (§10) and, in `shared` scope, the record's `creatorUserRecordID.recordName` equals that device's `user_record_name`. Anything else fails `device_not_linked` and is never applied. A linked device's own grant then decides typing (`typing_allowed`, default false) and starts (`start_sessions_allowed`, default true).
5. **Age.** Older than 7 days: `expired`. For `session_input`, `session_finish_request` and `session_start`, the cutoff is 24 h after `created_at`.
6. **Echo writes.** Echoes rewrite the same record. A `received` echo is written for `session_start`, `session_input` and `board_target_create` as soon as the hub dequeues the record, before any work. The start sheet's "Mac picked it up" stage reads it.

### 5.3 `recording_upload`

The branch's `RecordingUploadPayload` (`id`, `started_at`, `ended_at`, `duration_sec`, `title_hint?`, `sample_format`, `status: pending|received|failed`, `error_message?`) gains two fields:

- `event_id?`: absent when nil. Set when the recording was started from an event.
- `device_id`

The audio rides as the record's CKAsset. On `received`, the Mac rewrites the record without the asset, which frees the iCloud storage, and the phone deletes its local file. Transcription progress then lives in `recording_job` (§4.12). The phone keeps mark-moment offsets locally and shows them as jump points in the transcript view. They are not sent to the Mac *(default — owner may change)*.

---

## 6. Mac-side hook points

Verified at main `b21f2c44`. The analysis's numbers were taken at `c78edea4`; the ones that moved are corrected here.

### 6.1 Hub composition

- **`AppState.initMobileHub(dbPool:)`** (new), called at the end of `initWorkbenches` (`Sources/App/AppState.swift:1703-1778`). It needs:
  - `terminalCenter` (`:169`)
  - `workbenchesViewModel` (`:287`) and its `asks` (`OwnerAsksViewModel`, built at `Sources/ViewModels/WorkbenchesViewModel.swift:265`)
  - `sessionAgentStateCenter` (`:292`)
  - `sessionReportCenter` (`:295`)
  - `meetingRecorderCenter` (`:118`)
- **Teardown.** The hub is torn down and rebuilt wherever `initWorkbenches` re-runs, because it holds references to the centers that function replaces.
- **Main-actor dispatcher.** `MobileHubCommandDispatcher` is `@MainActor`, because `TerminalCenter`, `OwnerAsksViewModel` and `WorkbenchesViewModel` are main-actor `@Observable` objects. It owns every workbench handler. `RelayProcessor` stays a background type for decode, idempotency and echoes, and hops to the dispatcher for the handlers.
- **Owner writes.** Every board write the hub makes is reported through the same `onOwnerWrite` → `WorkbenchNotificationCenter.recordOwnerWrite` (`Sources/Services/WorkbenchNotificationCenter.swift:80`, wired at `AppState.swift:1752-1753`). Roll-up targets are reported too, as the board view model does, so the Mac never notifies the owner about their own phone edit.
- **Settings.** `SettingsTab` (`Sources/Views/Settings/SettingsView.swift:6-7`) gains `mobile`. The key `mobileSyncEnabled` goes in Core `Constants` (`WatchtowerCore/Utilities/Constants.swift`).

### 6.2 Ask answers

- **Entry point today:** `OwnerAsksViewModel.answer(_:verdict:)` (`Sources/ViewModels/OwnerAsksViewModel.swift:480`) is draft-driven.
- **Refactor.** Extract the part after the draft into one shared step: the `isAnswering` guard, `OwnerAskQueries.answer` (`WatchtowerCore/Database/Queries/OwnerAskQueries.swift:131`), `.notOpen` handling, the line from `OwnerAskPrompt` (`WatchtowerCore/Services/OwnerAskPrompt.swift:7`, the Go twin is `internal/asks/line.go`), `deliver` (`:575`), held answers, notices and hints. Add `answer(_ ask: OwnerAsk, with: OwnerAskAnswer) async -> AnswerOutcome`, which the hub calls. The draft-driven entry calls the same step. Delivery, holds and `deliverHeldAnswers` (`:525`) are therefore unchanged (**PROJ-12 untouched**).
- **Validation.** Before storing, the Mac checks the answer with the same rules as `OwnerAskDraft.isAnswerable`:
  - the verdict is set for a review;
  - every question has a label or an Other;
  - the labels exist in the ask's options;
  - the checklist ids exist;
  - comment bodies are non-empty.

  A failure is `invalid_answer`.
- **Ask already closed.** `.notOpen` fails `ask_not_open`.
- **Desktop draft.** A Desktop draft for the same ask is discarded on success, as a Desktop answer does.
- **Wire.** The answer JSON is `OwnerAskAnswer` (`WatchtowerCore/Services/OwnerAskAnswer.swift:7`, keys `verdict`, `answers`, `checklist`, `comments`, `note`). A fixture pins the phone encoder against `internal/asks/testdata/answers`.
- **Review anchors.** The phone builds review comment anchors (`quote`, `prefix`, `suffix`, `heading`) with a port of Core's `CommentAnchor`. A shared fixture of (document, selection) → anchor is run by both Core and Kit tests.

### 6.3 Board writes

- **Shared writer.** Extract `WorkbenchBoardViewModel`'s write bodies (`Sources/ViewModels/WorkbenchBoardViewModel.swift`) into a Core `WorkbenchOwnerWrites`, which returns the touched and rolled-up ids:
  - `setStatus(_:for:)` at `:469`, which computes rolled-up ancestors around `TargetQueries.updateStatus` (`TargetQueries.swift:286`, which writes `status_actor='owner'`, PROJ-06);
  - `setPriority` at `:516` (`TargetQueries.updatePriority` `:318`);
  - `addComment` at `:587` (`WorkbenchQueries.addOwnerComment` `:163`);
  - `reply` at `:599` (`WorkbenchQueries.reply` `:182`).

  The view model and the hub both call `WorkbenchOwnerWrites`.
- **Group status.** A group's status is never written. A status change on a target with children fails `invalid_params`, matching `WorkbenchBoardViewModel.setStatus` (`:451`) and PROJ-05 (`Views/Workbench/WorkbenchTargetPanel.swift:240`). The phone disables the picker for groups and shows "A group's status follows its sub-tasks".
- **New board target.** The Desktop has no owner path that creates a board target today; only the agent's `create_targets` does (`internal/tools/workbench_targets.go:192` → `db.CreateWorkbenchTargetsTx` `internal/db/workbench_targets.go:34`). The hub does not grow a Swift twin. Instead:
  - A new Go command, `watchtower workbench target add --workbench N --title T [--intent I] [--priority P] [--parent ID] --json`, prints `{"target_id":N}`.
  - `CreateWorkbenchTargetsTx` gains an actor argument: `create_targets` passes `agent`, the new command passes `owner`. Board defaults, parent checks (PROJ-09) and parent progress recompute stay in one implementation.
  - The hub runs the command through `CLIRunnerProtocol`.
  - This changes a cross-package contract. Run `go test ./internal/db ./internal/tools ./cmd -run 'Workbench|Proj0[569]'`.
- **Moves** (`WorkbenchQueries.moveTarget` `:281`) are not offered on the phone in the POC *(default)*.

### 6.4 Recording ingest (C)

`Sources/Services/MeetingRecorderCenter.swift` needs the branch's ~60-line delta re-applied by hand:

1. **The `.m4a` extension.** Accept `.m4a` next to `.caf` in four places:
   - `scanRecoverable` (`:1665`, filter at `:1675`);
   - `recoverySortKey` (`:1654`, `dropLast(".caf".count)` at `:1655` becomes `deletingPathExtension`);
   - `uniqueRecordingURL(in:date:)` (`:1791`, hard-coded at `:1793` and `:1797`), which gains a `fileExtension:` parameter;
   - the decode path (`decode(job.audioURL)` `:1367`), which must read `.m4a`.
2. **Ingest.** Add `ingestPhoneRecording(audioURL:eventID:title:config:)`. It writes `rec_<ts>.m4a` plus its `.meta` sidecar (`writeMetaSidecar` `:1624`, `metaURL` `:1615`) into `defaultRecordingsDirectory()` (`:1770`, the Go mirror is `internal/config/config.go:797`), then **enqueues a processing job directly**. It does not use the opt-in recoverable list (`addRecoverable` `:1261`), because a phone recording is transcribed automatically. The helpers the hub calls off the main actor become `nonisolated`.
3. **Event link.** Pass the upload's `event_id`. Attendee-scoped voice matching (`registryLoader`, `:177`) then applies.
4. **Job outcomes.** Add `onJobFinished(audioURL:transcriptID:)` and `onJobPhase(audioURL:phase:)` callbacks. They feed the sidecar `phone_recordings(upload_id, audio_path, transcript_id)` and the `recording_job` slice.
5. **Orphan sweep.** The Go orphan sweep keys on `rec_` only, so `.m4a` files are covered (`internal/daemon/daemon.go:957`).
6. **Phone-only audio.** A phone recording has only the mic channel, no system or activity channel. The role and diarization flow must accept that without failing the job (test in C2).

### 6.5 Start and stop a session (B)

- **Today's path.** `WorkbenchesViewModel.workOn(targetID:targetText:projectID:placement:)` (`Sources/ViewModels/WorkbenchesViewModel+Sessions.swift:198`) runs `createAndStart` (`:449`), then `activate` (`:470`), then `TerminalCenter.start(_:fresh:prompt:)` (`Sources/Services/TerminalCenter.swift:598`). `activate` calls `center.focus` (`TerminalCenter.swift:218`) and `setLayout` when the switch is the latest.
- **New placement `.background`** (`Placement` enum `:20`). `activate` with `.background`:
  - takes no `beginSwitch` ticket;
  - never calls `focus` or `setLayout`;
  - never refreshes the previous session's title;
  - still starts the process. `SwiftTermSession` builds an offscreen `LocalProcessTerminalView` (`TerminalCenter.swift:938`), so no visible pane is needed.
- **New entry `startForTarget(targetID:prompt:mode:placement:)`.** It shares `workOn`'s read and `createAndStart`:
  - `mode: open_existing` keeps `workOn`'s reuse of `TerminalSessionPolicy.sessionForTarget` (`WatchtowerCore/Services/TerminalSessionPolicy.swift:22`).
  - `mode: new` always creates a session.
- **Placement from the toggle.** "Bring the window forward" off gives `.background`. On gives `.keeping(.board)`, the same as Desktop Work on it, plus the workbench window brought to the front.
- **The brief.** It is `TerminalLaunch.workOnTargetPrompt` (`:88`), or the phone's edited `brief`, which is honoured only from a device with `typing_allowed` and is ignored otherwise. With `plan_first`, it is followed by the fixed sentence `TerminalLaunch.planFirstSuffix` = "Plan first: put the plan on the board, then ask me with ask_owner before you change any code." *(default — owner may change)*. The brief goes through the same `start` argv path as Work on it. A test pins a brief that starts with `-`.
- **Failures.** Exit 127 (`TerminalLaunch.swift:97`) → `failed`/`claude_not_found`. A target not on a board → `not_on_board`. A device with `start_sessions_allowed = false` → `device_not_allowed`.
- **Stop.** `session_stop` is `TerminalCenter.close(sessionID:)` (`:652`): SIGHUP, then SIGKILL after the grace period. The row and its Claude transcript stay, and the Desktop can resume it. The phone asks for confirmation.
- **Finish.** "Finish" never writes `finished_at` (**PROJ-14**: only the session says it finished). It is `session_finish_request`: the fixed line "Please wrap up: update the board, then call finish_session with a short summary.", delivered under §6.6's rules and gate. The menu item is hidden on a device without `typing_allowed`.

### 6.6 Session input (B, PROJ-16)

- **Today's paths.** `TerminalCenter.submitPrompt` (`:326`) and `sendPrompt` (`:264`) are the delivery. `OwnerAsksViewModel.deliver` (`:575`) is the guard pattern: `refreshStates`, the `needsApproval` hold, the `runs` check (`TerminalCenter.swift:128`), `promptDrafts` (`:89`) and `answerSubmitDelay` (`:288`).
- **Shared delivery.** Extract the private `deliver` and its held and queued bookkeeping into `SessionLineDelivery`, a main-actor service owned by `AppState`. It has one queue per session, so an answer and a phone line never share a prompt. Asks and the hub both use it, and PROJ-12's guard tests must run unchanged against it.
- **Rules for a phone line, on top of PROJ-12:**
  - the device has `typing_allowed`;
  - the session is live;
  - the agent is idle, meaning the resolved `state_kind` is `stopped`, `finished`, `waiting_on_ask` or `failed` for the current run, or the run is marked with no turn yet;
  - the session is not `needs_approval`;
  - the prompt holds no draft *before* the paste. If it does, the line is held (`prompt_has_text`) and not pasted.
- **Held lines.** A line that is not deliverable yet is echoed `held` with a `reason` (`agent_busy`, `needs_approval`, `prompt_has_text` or `state_unknown`). It is retried on every successful state read (`SessionAgentStateCenter.onRead`/`onChange`), never on a timer. It expires after 24 h.
- **Hub restart.** A `held` record is not `begun`. On hub start, held records are queued again.
- **Text handling.** The text is trimmed, its control characters and newlines become spaces (the `OwnerAskPrompt` sanitising rule), and it must be non-empty. It is sent with `keepingLineBreaks: false`.
- **Outcome.** `submitted` → `applied`. `typed` (Return withheld under PROJ-12) → `applied` with `delivery: typed`, and the phone says "Typed into the session — press Return on the Mac". `copied` (no bracketed paste) → `failed`/`cannot_type`. `noSession` → `failed`/`session_not_running`.
- **Cancel.** `session_input_cancel` drops a held line and echoes the original `cancelled`.
- **Permission prompts.** They are never answered: no phone input path writes while `needsApproval`, and the phone shows "Needs approval on the Mac".

---

## 7. Notifications

- **Silent sync pushes** come from CKSyncEngine's own database subscription: on the private database in `private` scope, and on the shared database in `shared` scope (`shared-db-v1`, spike S0(b)).
- **The visible push in `private` scope** fires only for a new owner ask:
  - It is a `CKQuerySubscription`: id `ask-alerts-v1`, record type `WatchtowerRecord`, predicate `kind == "ask_alert"`, zone `DataZone`, options `.firesOnRecordCreation`.
  - Its `notificationInfo` carries `alertLocalizationKey = "ASK_ALERT_GENERIC"` ("A session is waiting for you"), `soundName = "default"`, `shouldSendMutableContent = true` and `category = "ASK"`. It has no `desiredKeys`, because the content is encrypted.
  - **Fallback**, used only if A3 shows that query subscriptions do not fire in a custom zone: a third zone `AlertZone` holding only `ask_alert` records, with a `CKRecordZoneSubscription` carrying the same `notificationInfo`.
- **The ask alert in `shared` scope.** The shared database supports only database subscriptions, so a query subscription on `kind` is not possible there, and a visible database subscription would alert on every change.
  - The phone instead raises a **local** notification when a fetch (silent push, `BGAppRefreshTask` or foreground) applies a new `ask_alert` record. It is deduplicated by the branch's alert watermark (`ask_id`).
  - The local notification carries the same title, body, `ASK` / `ASK_QUICK` category and `userInfo` that the NSE would set.
  - A force-quit app gets no silent push, so its alert waits for the next fetch. Settings shows "On this iPhone, notifications can be late" in `shared` scope.
  - If S0(b) shows silent pushes on the shared database do not arrive, the phone relies on `BGAppRefreshTask` (every 15 min, iOS permitting) and the foreground fetch (§3), with the same Settings line.
- **Notification Service Extension** (private scope).
  - It fetches `ask_alert-<id>` by record ID within 25 s.
  - It sets the title to `workbench_name` and the body to `title`.
  - It sets the category to `ASK_QUICK` when `quick`, otherwise `ASK`, with `userInfo.ask_id`.
  - On any failure it leaves the generic text and `ASK`.
- **`ASK_QUICK` long-press** (Notification Content Extension):
  - It reads `owner_ask-<id>` from the app-group replica, or fetches it by ID from its scope's database.
  - It shows the question, the 2–4 options with the recommended one badged, and "Open the ask".
  - A tap enqueues `ask_answer` (`answers: [{id: question_id, labels: [label], other: ""}]`). The record is saved directly with a `CKModifyRecordsOperation` and also stored in the app-group outbox with state `sent_by_extension`. The app never resends it, and a resend would be harmless: same record name, processed once.
- **`ASK`** has one action, "Open the ask", which deep-links to the ask.
- **Settings toggle.** In `private` scope, "New asks" saves or deletes `ask-alerts-v1`. Subscriptions are per iCloud account, so the toggle applies to all of the user's devices, and the label says so *(default — owner may change)*. In `shared` scope the toggle turns this phone's local ask notifications on or off.
- **Nothing else pushes:** no session-state pushes, no meeting pushes.

---

## 8. Invariants

1. **I-1 Single hub.** One Mac per iCloud account publishes, and a phone is linked to exactly one hub (§2.3).
   - When enabled, a hub reads `heartbeat`. If its `hub_id` differs and `updated_at` is less than 720 s old, enabling is refused: "<mac_name> is your hub. Turn it off there, or Take over".
   - Take over writes a new heartbeat with this hub's id. A hub that sees a foreign `hub_id` in `heartbeat` stops publishing and shows "Another Mac took over".
   - A pull that failed or timed out is not a claim: without an explicit Take over the hub goes unavailable and re-probes. An explicit Take over on a failed pull proceeds; its heartbeat is stamped after the newest heartbeat it knows (`max(now, newest + 1 s)`; a newest heartbeat more than 720 s ahead of this Mac's clock is a broken clock and is not followed — the stamp is `now` and the skew is logged — so it cannot poison later hubs; against a hub still running with that clock the take over is lost as described next). Known POC limit *(amended 2026-10-10, final review)*: when the pull failed, a newer live heartbeat the hub has not read can still be newer than that stamp (clock skew between the Macs); the other hub then keeps its claim, and this hub stops with "Another Mac took over" on its next read, so the take over is lost, never split. Usually iCloud is down then and the heartbeat save fails too.
2. **I-2 Single path.** Every phone write runs through the code the Desktop UI uses for the same change: the asks, board writer, start, close and recorder paths of §6.
3. **I-3 Exactly-once.** Each `action` record is applied at most once (§5.2, rule 1). Its outcome is echoed into the same record.
4. **I-4 No transcript.** No session transcript, terminal buffer or screen text is published, ever (owner directive). `PalettedTerminalView.screenRows()` (`TerminalCenter.swift:881`) stays private.
5. **I-5 No permission answers.** No phone action writes to a PTY while its session's state is `needsApproval`.
6. **I-6 Resolved state only.** Phone state, colour, glyph and caption come from the `terminal_session` record. The phone has no state rules.
7. **I-7 Board only.** Every published or written target has `project_id IS NOT NULL` (PROJ-01), except the read-only `linked_targets`, which have `project_id IS NULL` and never reach a board view.
8. **I-8 Caps hold.** Every slice is capped (§4). A record never relies on the 900 KB guard. That guard is a safety net that hides a record, never a projection rule.
9. **I-9 Public repo.** Fixtures and tests use placeholders: `acme`, `example.com`, `~/Projects/acme`, "colleague A". No real ids, names or paths.
10. **I-10 Linked devices only.** The Mac applies a relay record only from a device linked by a used QR nonce (§2.3, §5.2 rule 4). A share participant not bound to a used nonce is removed when the public link closes.

---

## 9. Error handling

| Case | Behaviour |
|---|---|
| **Mac asleep or app quit** | The phone reads from its replica. Writes go to the outbox and the RelayZone, and each row shows "Waiting for your Mac" while the heartbeat is stale. The Mac applies the queue on launch or wake, subject to the expiries in §3. The start sheet stays on "Sent to your Mac". A recording upload stays `pending` and the Recordings list shows "Waiting for the Mac to wake" |
| **`.limitExceeded`** (batch too large) | The transport halves the batch (200 → 100 → … → 1) and retries. A single record that still fails is logged with its record name, and its `slice_state` hash is cleared, so it is not believed published. The publisher's projection caps make this a bug signal, not a steady state |
| **`.requestRateLimited` / `.zoneBusy`** | Honour `CKErrorRetryAfterKey`, defaulting to 5 s and doubling up to 120 s. Pause fast-lane sends until then; the 10 s tick keeps diffing. Settings shows "iCloud is slowing sync down" after 60 s of throttling |
| **`.quotaExceeded`** | Sync pauses and a Desktop banner opens Settings → Mobile. The phone shows its last replica with a "Mac sync paused (iCloud full)" row. Recording uploads stay on the phone |
| **Oversized payload** | Projection caps (§4). The 900 KB guard is the last resort: skip, no hash, throttled warning (existing). A test asserts that each slice's worst-case fixture stays under 900 KB |
| **Duplicate delivery** (push twice, re-fetch, extension plus app) | Same record name, so §5.2 rule 1 applies. Recording ingest keeps the accepted edge: a crash between the ack save and the processed mark re-copies the audio, which yields a duplicate transcript the owner may delete |
| **Stale state on the phone** | `from_*` conflict (§5.2, rule 2). An ask closed meanwhile → `ask_not_open`, and the phone shows the ask's current status. A session restarted meanwhile → input goes to the new run under the §6.6 rules |
| **`serverRecordChanged` / `unknownItem`** | Existing `fixSystemFieldsForFailedSaves`. In DataZone the Mac always wins. In RelayZone the phone never rewrites a record after the Mac moved it out of `pending` |
| **iCloud signed out or account changed** | Existing account-change reset. Both sides show "Sync off". The phone keeps its replica read-only until the same account returns, and wipes it on a different account |
| **Mac signs out of iCloud after linking** | The hub stops, and the heartbeat goes stale, so the phone shows "Your Mac is offline". If the Mac signs back in with the same Apple ID, everything resumes. With a different Apple ID the hub starts fresh in that account. Phones see no new heartbeat, and after 24 h stale they show "Your Mac hasn't synced for a day — if it changed iCloud account, link again" |
| **Participant removed or share deleted while the phone was offline** | On the next fetch, the shared zones are gone (zone-deleted event, `zoneNotFound`, or `changeTokenExpired` on a missing zone). The phone shows "This Mac removed this phone", wipes the replica, reports outbox items "Not sent", and returns to Welcome |
| **Linked hub changed** (take over) | The heartbeat's `hub_id` differs from the linked one, so the phone shows "Watchtower moved to <mac_name> — scan the code on that Mac". Its writes are not sent |
| **Mac iCloud off or restricted** | Settings → Mobile states it plainly, with no QR (§2.3 table) |
| **Entitlement missing** (ad-hoc build) | `CloudKitTransport.entitlementPresent()` is false. The Desktop's Settings → Mobile shows "Needs a signed build" and the toggle is disabled |

---

## 10. Security

- **Data.** All content goes through `encryptedValues`, so it is end-to-end encrypted when the user has Advanced Data Protection on. Only `kind` and `modifiedAt` are plaintext. The replica sits under iOS Data Protection in the app group.
- **Closed command set.** The relay runs only the closed `ActionKind` set. No SQL, shell or arbitrary argv travels from the phone. Free text reaches Claude Code only through §6.5's brief and §6.6's line, both gated.
- **Linking is the device consent.** Only a device that wrote the nonce of a QR shown on the Mac's screen is linked (§2.3). The QR is a bearer secret:
  - It is shown only on the Mac's screen, never logged, copied or sent.
  - It expires after 600 s and is single use.
  - In `shared` scope it carries the share URLs, whose public link is open only while the QR is shown. A participant not bound to a used nonce is removed when the link closes.
  - Someone who photographs the QR within its window can at most race the owner's phone. The first device to write the nonce wins, the owner sees the phone list and **Remove**s a stranger, and a stranger never gets `typing_allowed` without the separate Allow.
- **Device opt-in for typing** (additional to linking).
  - The phone sets `typing_requested` in its `device` record.
  - The Mac then shows a one-time confirmation in Settings → Mobile, "Allow "<name>" to type into Claude Code sessions?", plus a macOS notification if the app is in the background (OD-2, decided).
  - Only after **Allow** does the sidecar `devices(device_id, name, scope, user_record_name, linked_at, typing_allowed, start_sessions_allowed, decided_at)` grant it.
  - Revoking on either side (phone toggle off, or Mac **Revoke**) takes effect for the next action. Held lines from a revoked device are echoed `failed`/`device_not_allowed`.
- **Start-session gate.** `start_sessions_allowed` defaults to true and is turned off from the phone toggle.
- **Quota.** In `shared` scope everything, phone recording uploads included, counts against the Mac user's iCloud quota. An upload's asset is freed on `received`.
- **Opt-in hub.** The hub is opt-in in every flavor (Settings → Mobile, off by default). The corp flavor shows one line there: "Work data from this Mac will be stored in your personal iCloud account."
- **Signing.** The hub needs a Developer ID build with the iCloud entitlement for the container, `aps-environment`, and an embedded Developer ID provisioning profile (`WATCHTOWER_PROVISION_PROFILE` → `Contents/embedded.provisionprofile`). Re-apply the branch's cloud-signing branch next to `scripts/build-app.sh:416-418`. Ad-hoc signing (`:425-428`, `make app-dev`) keeps the base entitlements, because amfid kills an ad-hoc app that carries restricted entitlements. Both Mac flavors are signed by the same Developer team, so one container serves both.

**Development and test consequences of the signing requirement:**

- Hub logic is unit-tested on `InMemoryCloudTransport` in `WatchtowerDesktopTests` (`make test-swift FILTER=MobileHub`). This needs no signing.
- Any CloudKit run (A3 and every device acceptance test) needs `make app` with a profile on the owner's machine. `make app-dev` can never run the hub.
- The phone runs on a signed device build. A simulator build without the entitlements section falls back to Demo, which is the DemoSeed replica.
- Before `make mobile-test`, uninstall the simulator app (`xcrun simctl boot "<device>"`, then `xcrun simctl uninstall "<device>" com.aiwatchtowers.watchtower.mobile`). Otherwise a stale replica fails the wiring tests.

---

## 11. Inventory change: session input from the phone (decided: new PROJ-16)

House rule: no new contract number if an existing contract covers the principle.

PROJ-12 covers *how* a line reaches a session: stored first, hooks reported this run, never into a permission prompt, never over a draft, one delivery at a time. Phone input brings three principles PROJ-12 does not cover:

1. who may type (device authorization);
2. *when* a line may go (only while the agent is idle; an ask answer may be queued by Claude Code mid-turn);
3. the guarantee that the phone never answers a permission prompt even through a future path.

**Decided 2026-10-07 (OD-1): new PROJ-16.** It references PROJ-12 for delivery and duplicates none of it. It lands with its guards in B7, in one commit (inventory protocol).

> **PROJ-16 — a line from the owner's phone reaches a Claude Code session only from a device the owner allowed on the Mac, only while the agent is idle, and only through PROJ-12's delivery; nothing from the phone ever answers a permission prompt**
>
> **Observable:** A `session_input` or `session_finish_request` action from the phone is typed into a workbench session only when (0) the device is linked by a QR scan (§2.3); (1) the device's `typing_allowed` is set in the hub's `devices` table, which the owner granted with Allow in Settings → Mobile on the Mac; (2) the session is live and its resolved state for the current run is Stopped, Finished, Waiting for you, Error, or a marked run with no turn yet — never Working, Running or Needs approval; (3) the prompt held no draft before the paste. It is then delivered by the shared `SessionLineDelivery` under every PROJ-12 rule, as one sanitised line. Otherwise it is held (retried on each successful state read, never on a timer) and expires 24 h after the phone created it. A `session_start` brief edited on the phone is used only from such a device. No phone action writes to a session's terminal while its state is `needsApproval`.
>
> **Why locked:** Any device signed into the owner's Apple ID can write relay records. Without a Mac-side grant, that device could drive a Claude Code session that holds workbench write tools. A line typed while the agent works could be read as an answer to a dialog that appears meanwhile.
>
> **Test guards (to write):** `testProj16_AnUnallowedDeviceTypesNothing`, `testProj16_AWorkingSessionHoldsTheLineUntilItStops`, `testProj16_NeedsApprovalNeverGetsAPhoneLine`, `testProj16_ADraftHoldsTheLineAndNothingIsPasted`, `testProj16_AHeldLineExpiresAfter24h`, `testProj16_AnEditedBriefFromAnUnallowedDeviceIsIgnored`, `testProj16_RevokeFailsHeldLines`. The PROJ-12 guards run unchanged against `SessionLineDelivery`.

Amending PROJ-12 instead was rejected: it would mix authorization with delivery in one heading. The PROJ-12 changelog gains one line saying `deliver` moved into `SessionLineDelivery` with its guards unchanged.

---

## 12. Reuse map (branch `mobile-app` → main)

The branch shares no history with main (repo split 2026-09-26). Porting is file-level (`git show mobile-app:<path>`). Never merge the branch.

| Verdict | Components |
|---|---|
| **Port as-is** | Kit: `Sync/JSONValue`, `RowPayloadCoder`, `CloudSyncTransport`, `InMemoryCloudTransport`, `CloudRecordFactory` (plus overloads); `CloudKitTransport/CloudKitTransport`, `TransportStore`; `Relay/RelayCoder`, `ActionOutbox`; `Replica/ReplicaStore`, `+PendingActions`, `+PhoneRecordings`, `ReplicaHydrator`. Hub: `HubSyncState`, `SliceDiff`, `MobileHubService` (new collaborators through init). Phone: `PhoneRecorderController`, the `project.yml`/xcconfig/entitlements set, `ReplicaObserver`, `Components/*`. Build: Makefile `mobile-gen/build/test/run/archive`. Tests: the sync-core Kit suites, `HubSyncStateTests`, `SliceDiffTests`, `MobileHubServiceTests`, `RelayProcessorHygieneTests` |
| **Adapt** | `SliceRecord` (new kinds, old ones unpublished); `RelayRecordKind` (+ `device`); `ActionRequestPayload` (new kinds, statuses, `device_id`/`reason`/`result`); `RelayFeed` (new echo routes); `RecordingUploadPayload`/`RecordingUploader` (+ `event_id`, `device_id`); `HeartbeatPayload` (own file, new fields); `CloudKitTransport` (+ the `CloudDatabaseScope` private/shared parameter, no zone writes in shared scope, limitExceeded/rate-limit/quota handling, §9); `SlicePublisher` (new projections, non-SQL sources for CLI JSON, fast lane, asset-backed slices); `RelayProcessor` (keep idempotency, hygiene, `processRecordingUpload`/`ingestAsset`; add the begun/done phases and the main-actor dispatcher; refuse the D kinds); `MobileSettings` → `SettingsTab.mobile`; `AppEnvironment` (no chat/agent; workbench view models); `NotificationCoordinator` (re-keyed on `ask_alert`); `RootTabView` → Now, Workbench, Calendar, More; `TodayView` → Calendar agenda; `RecordingsView`/`RecordingDetailView`; `SettingsView`; `build-app.sh` cloud branch; Kit `CalendarEvent`/`MeetingTranscript` mirrors; tests `SlicePublisherTests`, `RelayProcessorRecordingUploadTests`, `FullLoopTests`, mobile `ReplicaWiringTests`, `RecordingsWiringTests`, `ActionsWiringTests`, `NotificationTests`, `BadgeTests` |
| **Rewrite** | AppState glue → `initMobileHub` (§6.1); `DemoSeed` (workbenches, sessions, asks, board, calendar, transcripts); `MeetingRecorderCenter` phone-ingest delta (§6.4); every workbench phone screen; new Kit mirrors `Workbench`, `WorkbenchTarget`, `WorkbenchComment`, `TerminalSessionState`, `OwnerAsk`, `SessionReport`, `SessionTimeline`, `RecordingJob`, `DeviceGrant` |
| **Drop / park** | `Agent/*` (BYOK; parked for #428); `ReplicaToolbox`; `ChatPayloads` (after moving `HeartbeatPayload`), `ChatAssembler`, `ReplicaStore+Chat`, `SituationChatRelay`; `KitReexport`, `CoreTypeAliases`; models Briefing, DayPlan, Decision, Digest*, InboxItem, PeopleCard, RunningSummary, Situation, StreamDigest, Track, ConnectedAccount, FeatureState, plus Target until D; phone Inbox/Digests/Tracks/DayPlan/Chat/Tasks views, `FeatureGate`, `APIKeyStore`; `smoke-live`; their tests |

The **"Rewrite"** row also covers changes on main itself, outside the ported files:

- `Placement.background` and `startForTarget`;
- `SessionLineDelivery`;
- `WorkbenchOwnerWrites`;
- the structured `answer(_:with:)` entry;
- `watchtower workbench target add` and the actor argument on `CreateWorkbenchTargetsTx`;
- linking (all new): the Mac's `MobileLinkCenter` (zone shares, public link window, QR and `link_codes`, the phone list), and the phone's onboarding, scanner, scope choice and unlink.

---

## 13. Sub-projects, milestones and acceptance tests

Order: **S0 (spike)** → A1 → A2 → **A3 (gate)** → A4 → B1 → B2 → B3 → B4 → B5 → B6 → C1 → C2 → C3 → B7. OD-1 is decided, so B7 is no longer blocked; it stays last because it depends on B4's delivery extraction. C may run in a lane parallel to B4–B6, since it touches different tables (`MeetingRecorderCenter` and calendar slices, not workbench code), but only one Swift lane links at a time (CLAUDE.md).

Each milestone runs the inner loop for what it touched: `go test ./internal/<pkg>`, `make test-swift FILTER=<Class>`, `make mobile-test` for the phone, and `make lint-diff`. The controller runs the full gate once per sub-project.

### A, skeleton (#423)

**S0 Spike: CloudKit sharing and scopes (first milestone, before the Kit port lands; owner-run on devices where needed).** A throwaway harness — one macOS and one iOS target signed for the real container, not merged. It is run with two Apple IDs: the owner's, and a test Apple ID on the phone. Each item is recorded pass/fail in the S0 PR, with logs.

- **(a) CKSyncEngine on the shared database.** A participant fetches DataZone and RelayZone changes, sends a RelayZone record, and uploads a CKAsset of at least 60 MB into RelayZone, which the owner downloads.
  - Fail: A stops. The owner decides between a hand-rolled fetch/modify loop on the shared database or dropping `shared` scope for the POC.
- **(b) Push on the shared database.** A silent `CKDatabaseSubscription` on the participant's shared database delivers a push for an owner write, with the app in the background.
  - Fail: the polling fallback (§7: `BGAppRefreshTask` every 15 min plus the 5 s / 30 s foreground fetch, Settings line "notifications can be late"), and ask alerts in `shared` scope become best effort.
- **(c) Closing the public link.** After the phone accepts, set `publicPermission = .none`. Does the accepted participant keep read access (DataZone) and read-write access (RelayZone)?
  - Fail: test F2 (named participant from `CKUserIdentity.LookupInfo(userRecordID:)`, then re-accept, §2.3) in the same run. If F2 fails too, F3 needs the owner's written OK.
- **(d) Same-Apple-ID detection.** `CKContainer.userRecordID().recordName` is equal on macOS and iOS for one Apple ID in this container, and different for two Apple IDs.
  - Fail: the zone lookup fallback in §2.3.
- **(e) Extras.** Record a query subscription in a private custom zone with a visible alert (the A3 item (e) question, answered early), and the latency of each path.

A1 adapts `CloudKitTransport` to whatever S0 proved; nothing after S0 assumes an unproven item.

**A1 Kit core.** Port the as-is files; split `WatchtowerSync`/`WatchtowerKit`; add `CloudDatabaseScope` (private / shared) behind `CloudSyncTransport`; drop the agent, chat and old models; move `HeartbeatPayload` into DataZone. Tests:

- (a) the frozen fixtures for every kept kind round-trip;
- (b) a `SliceKind` decodes every raw value, and an unknown kind is stored but not surfaced (forward compatibility);
- (c) `WatchtowerCore` builds with no Kit import, checked by a grep test in `PublicAPISurfaceTests`;
- (d) degenerate: an empty payload, a payload of exactly 900_000 bytes (published) and one of 900_001 bytes (skipped, not hashed);
- (e) in `shared` scope the transport never issues a zone save or delete, and a zone-deleted event surfaces as "unlinked";
- (f) the QR payload round-trips through a frozen fixture; `v: 2` is refused with "update"; a payload missing `nonce`, or with a bad base64url, is refused.

**A2 Hub skeleton and Mac-side linking.** `initMobileHub`, and `SettingsTab.mobile` with the opt-in toggle, hub status, the corp notice, **Use Watchtower on iPhone** (QR sheet with countdown and New code) and the phone list (Allow… / Revoke / Remove). Also: heartbeat with the new fields, the single-hub rule (with share teardown on take over), `MobileLinkCenter` (zone shares, public link window, `link_codes`, nonce check, grants), a `probe` handler, transport error handling (§9), and the signing branch in `build-app.sh`. Tests on `InMemoryCloudTransport` and a fake share service:

- (a) toggle off: no transport is created and nothing is written;
- (b) a foreign heartbeat younger than 720 s refuses enable, one of exactly 720 s allows it, and Take over makes the other hub stop;
- (c) `probe` echoes `applied` with the nonce exactly once when delivered twice;
- (d) `.limitExceeded` on a 200-record batch halves down to the failing record and clears only its hash;
- (e) `.requestRateLimited` with `retryAfter` 7 s waits 7 s, and without one waits 5 s, then 10 s;
- (f) an ad-hoc build shows "Needs a signed build";
- (g) a `begun` record found at start echoes `outcome_unknown` and is not re-applied;
- (h) a valid nonce links once; **the same QR scanned twice by the same phone** stays one link (idempotent); a second phone using a used code gets `used_code`; an expired code gets `expired_code`; an unknown one gets `unknown_code`;
- (i) **two phones** each with their own code are both linked and listed, and Remove of one leaves the other working;
- (j) in `shared` scope, a `device` record whose creator differs from `user_record_name` is refused; a relay action from an unlinked `device_id` fails `device_not_linked`;
- (k) closing the link removes a participant not bound to a used nonce and keeps the bound one; the link is closed at use, at 600 s and when the sheet closes;
- (l) iCloud `.noAccount` and `.restricted` each show their sentence and no QR;
- (m) take over deletes the shares, clears `devices`, and the next QR creates new shares.

**A3 Real-iCloud device smoke (gate; owner-run, checklist written into this milestone's PR).** One `make app` signed Mac and two signed iPhones: one on the Mac's Apple ID, and one on a second Apple ID for items (i)–(l). Pass criteria:

- (a) A `probe` slice reaches the phone in ≤ 15 s, measured 10 times; record the p50 and p90.
- (b) A `probe` action round-trips in ≤ 30 s with the Mac awake.
- (c) A 60 MB CKAsset uploads from the phone and is ingested on the Mac.
- (d) The silent push arrives with the app in the background.
- (e) A visible `ask_alert` push arrives on the lock screen from the query subscription. If it does not, retry with `AlertZone` and record which one is kept.
- (f) A record ≥ 800 KB saves.
- (g) Sign-out and sign-in reset cleanly on both sides.

Linking on real devices is part of A3:

- (h) a same-Apple-ID phone links in `private` scope;
- (i) a second-Apple-ID phone links in `shared` scope and reads a slice;
- (j) **a same-Apple-ID phone scanning a QR that carries share URLs** links in `private` scope and never calls accept;
- (k) the Mac signs out of iCloud after linking: the phone shows offline, and signing back in resumes;
- (l) a participant removed on the Mac while the phone is in airplane mode: the phone shows "This Mac removed this phone" at its next fetch and wipes the replica.

No B or C milestone starts until A3 passes, or until the owner accepts each failed item in writing.

**A4 Phone shell and onboarding.** Onboarding (Welcome, then Scan the code on your Mac, then Linked to <Mac name>, then the notifications permission, then Now), the "The Mac doesn't show up" screen, the switch-Mac confirmation, Unlink this Mac; tabs Now, Workbench, Calendar, More (More = Settings); the Settings screen (Your Mac status, Workbench toggles, Notifications, "Chat without the Mac — later" as a disabled row); a DemoSeed rewrite; the app icon from `WatchtowerDesktop/Sources/Resources/Assets.xcassets/AppIcon.appiconset`; the NSE and content extension targets wired to the app group; light and dark mode from the system; system blue accent. Tests:

- (a) heartbeat age 719 s shows online and 720 s shows offline;
- (b) no heartbeat at all shows "Your Mac has not connected yet";
- (c) the queued count equals the pending outbox rows;
- (d) `ReplicaWiringTests` counts match DemoSeed after an uninstall;
- (e) an expired QR (`exp` one second ago) shows the expired message and writes nothing;
- (f) phone iCloud `.noAccount` shows the sign-in message;
- (g) no grant within 60 s shows "Your Mac didn't answer";
- (h) Unlink this Mac wipes the replica and outbox and reports pending items "Not sent";
- (i) scanning another Mac's code while linked asks to switch, and No keeps the old link.

### B, Workbench Remote (#424)

**B1 Read slices.** `workbench`, `workbench_target`, `workbench_comment`, `terminal_session`, `owner_ask`, `ask_alert`, `device_grant`, and the fast lane. Tests:

- (a) no published record contains `folder_path`, `claude_session_id`, `agent_turn_end` or `agent_tool_run` (a key scan over the encoded payloads);
- (b) a personal target (`project_id IS NULL`) is never published;
- (c) an archived target is published with `archived: true`, and one archived 91 days ago is not;
- (d) a 2 MiB `doc_snapshot` publishes 256 KiB cut at a newline with `doc_clipped` and `doc_bytes`, and a snapshot with no newline before the cap is cut at the cap's grapheme boundary;
- (e) `quick` is set for one single-select question with a recommended option and 3 options, and absent for multi-select, for no recommended option, for 5 options and for 2 questions;
- (f) a state change to Needs approval reaches the published `state_kind` within one coalescing window plus one send (fake clock), not after the 10 s tick;
- (g) for each SessionStatePresentation kind, the published tone, caption and glyph equal `SessionStatePresentation`'s;
- (h) an ask open when the hub was enabled produces no `ask_alert`, a new one produces exactly one, and a re-hydrate produces none;
- (i) zero workbenches publish zero records and no error;
- (j) a workbench whose git status fails keeps the last branch.

**B2 Phone Workbench tab, read-only.**

- Level 1 list: name, folder, branch, waiting count, session-state counts, board progress.
- Level 2: switcher header with New session, Waiting for you stack (REVIEW, ASK and CHECK cards in orange), the SESSIONS list (dot and label from the record, report line, mini progress, open-ask count, "▸ N closed"), and the Sessions | Board segment.
- Board: the tree with status glyph, % progress, priority, ask and session indicators, and the filters Open, In progress, Blocked, Archive.
- Target detail: read-only.
- Now tab: Waiting for you across workbenches, next meeting, session summary chips.

Tests:

- (a) zero sessions shows "No sessions yet";
- (b) a 0-of-0 board shows no progress bar;
- (c) the Archive filter shows only `archived` records, and the other filters never show them;
- (d) a target with 0 children shows no disclosure;
- (e) the colour of every `state_tone` maps to the system colour named in §14;
- (f) orange appears only on waiting and ask elements (a snapshot test over the DemoSeed screens).

**B3 Session detail.** `session_report` and `session_timeline` slices; detail header, its open asks on top, report progress segments plus summary, timeline, `session_report_request` on open. Tests:

- (a) a report over 128 KiB drops the oldest phase items and sets `phases_clipped`;
- (b) the timeline keeps the newest 100;
- (c) a session with no report shows the header and timeline only;
- (d) a request twice within 60 s runs the CLI once;
- (e) no screen renders transcript text (I-4): the slice has no field for it.

**B4 Ask answers.** The structured `answer(_:with:)` entry, `ask_answer`, the phone forms (question with options, recommended badge, Other, multi-question paging; review with snapshot, select-to-comment, Approve and Request changes; check with ok/broken/skipped per step), the NSE and quick-answer extension. Tests:

- (a) a phone answer stores before typing and delivers like a Desktop answer, so every PROJ-12 guard still passes;
- (b) an ask withdrawn meanwhile → `ask_not_open`, nothing typed;
- (c) a label not among the options → `invalid_answer`, nothing written;
- (d) the same action delivered twice → one store, one line;
- (e) the phone encoder matches `internal/asks/testdata/answers` byte for byte;
- (f) a comment anchor from the phone equals Core's for the shared fixture, including a selection at document start and one spanning a heading;
- (g) quick answer from the content extension, then the app relaunching, sends nothing twice;
- (h) an NSE fetch timeout leaves the generic text.

**B5 Board writes.** `board_target_status`, `board_target_priority`, `board_comment_add`, `board_comment_reply`, `board_target_create` (Go `workbench target add`), and `WorkbenchOwnerWrites`. Tests:

- (a) a status change records history with actor `owner` (PROJ-06) and does not notify the Mac owner;
- (b) a status on a group → `invalid_params`;
- (c) a `from_status` mismatch → `conflict` with the current status, and an equal current status → `applied` with no write;
- (d) a reply to a resolved root reopens it (existing rule, through the shared writer);
- (e) create with a parent from another workbench → `not_on_board` (PROJ-09);
- (f) create with an empty or whitespace title → `invalid_params`, and one of 201 characters → `invalid_params`;
- (g) the Go command writes `status_actor='owner'` and `create_targets` still writes `agent`;
- (h) a crash between `begun` and the comment insert → `outcome_unknown` on restart, never a second comment.

**B6 Start and stop.** `Placement.background`, `startForTarget`, `session_start`, `session_stop`, and the start sheet's progress states. Tests:

- (a) a background start leaves `focusOrder`, the selected workbench and the layout unchanged, and the process runs;
- (b) `bring_forward` behaves like Work on it;
- (c) `open_existing` with an existing session opens it with no new row, and `new` creates a row;
- (d) `plan_first` appends exactly `planFirstSuffix`;
- (e) an edited brief from a device without typing is ignored and the base prompt is used;
- (f) a brief starting with `-` reaches Claude intact;
- (g) exit 127 → `claude_not_found`;
- (h) a request 24 h + 1 s old → `expired`, one 23 h old is applied;
- (i) Stop on a stopped session → `applied` with no signal;
- (j) the sheet stays at "Sent to your Mac" while the heartbeat is stale.

**B7 Session input (PROJ-16).** `SessionLineDelivery` extraction, `session_input`, `session_input_cancel`, `session_finish_request`, device grant UI on both sides, and the inventory entry with its guards in one commit (inventory protocol). Tests: the PROJ-16 guards in §11, plus:

- (a) empty or whitespace text → `invalid_params`;
- (b) text with newlines and control bytes arrives as one line;
- (c) 4001 characters → `invalid_params`;
- (d) cancel after delivery → `applied` stays and the cancel is a no-op;
- (e) a phone line and an ask answer to one session go one after the other, never in one prompt;
- (f) the device toggle off makes the phone hide the input and Finish.

### C, calendar and recording (#425)

**C1 Calendar.** `calendar_event` slice; agenda with the week day strip, event cards (recap ready, transcribing x%, now line), current or next meeting with Record and Prep; event detail (time, attendees, prep bullets, linked targets read-only, Join, Record this meeting). Tests:

- (a) `raw_json` is never published;
- (b) two accounts' copies of one meeting (same `ical_uid` and start) publish once;
- (c) a cancelled event is not published;
- (d) an all-day event has no Record button;
- (e) no prep cache shows "No prep yet — it is prepared on your Mac";
- (f) an event at the window's edge (now + 14 days exactly) is published and one past it is not;
- (g) "Make target" is not shown.

**C2 Phone recording → Mac.** The recorder (pause, mark moment, waveform, lock-screen recording), `recording_upload` with `event_id`, the §6.4 ingest, and the `recording_job` slice. Tests:

- (a) an `.m4a` is found by `scanRecoverable`, sorts by timestamp with `-N` suffixes, and decodes;
- (b) an ingest with `event_id` saves a transcript linked to the event, and one without it saves an ad-hoc transcript;
- (c) a phone recording with no system channel completes with roles skipped and no failed job;
- (d) a duplicate delivery after `received` ingests nothing;
- (e) a 0-second recording is refused on the phone ("Too short to save") and never uploaded;
- (f) auto-stop at 3 h;
- (g) an upload while the Mac is asleep stays `pending`, and the list shows "Waiting for the Mac to wake";
- (h) the `percent` from `transcribing(done: 3, total: 12)` is 25.

**C3 Recap and transcript view.** `meeting_transcript` slice with the segments asset; Recordings list (sending, transcribing on Mac, waiting for the Mac to wake, ready); recap with summary, action items, decisions, speaker transcript, and marks as jump points. Tests:

- (a) a recap linked only through `transcript_id` (event aged out) is found by the fixed join;
- (b) a legacy transcript without segments shows one block;
- (c) a transcript asset over 20 MB is clipped with `segments_clipped`;
- (d) deleted segments are not in the asset;
- (e) no `audio_path` or `speakers_json` key in any payload.

---

## 14. Visual language

- **Base look:** native iOS with SF Pro. Light and dark follow the system.
- **Accent:** `Color.accentColor`, which is system blue like the desktop's.
- **Session tones** map exactly to `SessionStatePresentation.Tone`: `green` → `.green` (working, running), `orange` → `.orange` (waiting for you, needs approval, finished with open asks), `blue` → `.blue` (finished), `red` → `.red` (failed), `secondary` → `.secondary` (stopped, not started). A session that is not live draws a ring.
- **Orange** is used only for "waiting for you", ask elements and the two orange states.
- **Red** is used for recording and failures.
- **Glyphs** are `SessionStatePresentation.glyph`.
- **App icon:** the desktop's `AppIcon`.

## 15. Risks

0. **Sharing behaviour is unproven** (S0): CKSyncEngine on the shared database, participant asset uploads, pushes on the shared database, closing a public link while keeping the participant, and cross-platform user ids. S0 runs first, and each item has a named fallback. The fallback for (a) — no shared scope — would make a different-Apple-ID phone unsupported in the POC, which is an owner call.
1. **CloudKit has never run on a device.** CKSyncEngine, assets, pushes, query subscriptions in a custom zone, and visible push through an NSE are all unproven. Mitigation: A3 gates everything, and the `AlertZone` fallback is pre-named.
2. **Latency.** iOS throttles silent pushes, and CloudKit rate-limits a chatty fast lane. The 2–15 s target is measured in A3, not assumed. The 5 s foreground fetch is the backstop while the user is looking.
3. **CKAsset size limits** for long recordings. Mitigation: the 3 h cap and A3's 60 MB test. If A3 fails at 60 MB, the cap drops to what passed.
4. **Refactors in contract-covered code.** `SessionLineDelivery`, `WorkbenchOwnerWrites`, `Placement.background` and the answer entry touch PROJ-05, 06, 11 and 12 code. Every existing guard must run unchanged, so each refactor lands in its own commit with the guard suite.
5. **The Desktop must be running.** With the app quit, nothing applies. The phone must say so plainly and never imply delivery. Echoes are the only proof.
6. **Single-hub rule and two Macs.** A take-over race could briefly mean two publishers. Mitigation: a hub stops at the first foreign heartbeat it reads, and DataZone conflicts resolve "Mac wins" per record.
7. **The simulator replica trap** and the Swift link cost. One Swift lane at a time.
8. **Corp data in personal iCloud.** Opt-in plus the notice. The owner accepted this with the single-container decision. In `shared` scope the data stays in the Mac user's iCloud, and the phone holds a replica.
9. **Late alerts for a different-Apple-ID phone.** Shared-scope ask alerts depend on silent pushes and background refresh, which iOS throttles. The Settings line says so.
10. **A photographed QR within its 600 s window.** The first device to write the nonce wins. Mitigation: the phone list on the Mac, Remove, and the separate typing Allow.

## 16. Non-goals

- The raw transcript, terminal screen or tool output.
- Answering permission prompts from the phone.
- Phone chat and BYOK.
- Personal targets (D).
- The old tabs (E).
- Moving board targets.
- Marking comments read.
- Meeting notes or chapters beyond the overview.
- Requesting meeting prep from the phone.
- Session-state pushes.
- iPad and landscape layouts, Apple Watch, widgets, Android.
- A vendor server or any non-iCloud transport.
- Running Claude Code or transcription without the Mac.

## 17. Owner decisions (decided 2026-10-07)

- **OD-1, session-input contract:** a new **PROJ-16** as drafted in §11. Amending PROJ-12 was rejected.
- **OD-2, granting a phone the right to type:** the phone toggle plus a one-time **Allow** on the Mac (§10). This is additional to linking.
- **OD-3, subagent milestones in the timeline:** not in the POC. Adding them later needs `SubagentStart`/`SubagentStop` hook entries, a migration, PROJ-04/PROJ-11 amendments and a setup re-run in every workbench.
- **Linking:** one QR flow for everyone, built in A. It works in private scope for the same Apple ID and through zone shares for a different Apple ID (§2.3).

No owner decision is open. Spike S0 can still force one: if S0(a) fails, the owner must choose between a hand-rolled shared-database sync and no different-Apple-ID support in the POC. If S0(c) and F2 both fail, F3 needs the owner's OK.

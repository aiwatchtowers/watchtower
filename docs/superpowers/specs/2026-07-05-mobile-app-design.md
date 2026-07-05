# Watchtower Mobile — Serverless iOS Companion (v1)

**Date:** 2026-07-05
**Status:** Design approved, pending implementation plan
**Branch:** `feature/mobile-app`

## Goal

An iOS companion app for Watchtower with **no vendor server**. All personal data stays on the customer's devices and in the customer's own iCloud private database. The desktop (macOS app + Go daemon) remains the single source of truth and the only component that talks to Slack/Jira/Calendar and runs the AI pipelines.

Mobile scenarios (all four are in scope):

1. **Read state** — briefings, inbox, tasks, tracks, calendar, people cards; works offline from a local replica.
2. **Quick actions** — done/dismiss/snooze/create task; queued offline, applied by the desktop.
3. **Push notifications** — urgent inbox items, briefing ready, calendar conflicts; delivered even when the Mac sleeps.
4. **Agent chat** — full-power chat relayed to the Mac's `claude` CLI when the Mac is awake; degraded direct-API fallback (user's own key) when it is not.

Product-oriented from day one: no grey-area reuse of the Claude subscription OAuth token on mobile, human onboarding, zero server cost (the customer's iCloud quota carries the data).

## Architecture Overview

```
Go daemon ──(SQLite, as today)──> macOS app (hub)
                                     │  CKSyncEngine
                                     ▼
                          CloudKit private DB (user's iCloud)
                          ├── DataZone   (product slice; desktop writes, mobile reads)
                          └── RelayZone  (commands + chat; both write)
                                     ▲
                                     │  CKSyncEngine
                                  iOS app ── GRDB replica ── DirectAPIBackend (BYOK fallback)
```

Key constraint driving the design: **the Go daemon cannot use CloudKit** (native API is Apple-frameworks-only; CloudKit Web Services has no private-DB-friendly auth and no sync engine). Therefore the **macOS Swift app is the hub**: it already reads the shared SQLite via GRDB and already invokes the `claude` CLI (`ClaudeService`). Consequence: the desktop app must run in the background (login item / menu bar) and be signed with CloudKit entitlements (Developer ID is sufficient; App Store not required for macOS).

## Repository Layout (monorepo)

```
watchtower/
├── internal/, cmd/          # Go backend (unchanged)
├── WatchtowerKit/           # NEW shared SPM package: models, CloudKit schema,
│                            #   sync engine, relay protocol, agent tool definitions
│                            #   platforms: macOS 14+, iOS 17+
├── WatchtowerDesktop/       # depends on WatchtowerKit (local path dependency)
└── WatchtowerMobile/        # NEW Xcode project (iOS app: signing, entitlements, CloudKit)
```

Shared models currently under `WatchtowerDesktop/Sources/.../Models` move to `WatchtowerKit`; the desktop switches to importing them. This mechanical refactor is the first implementation step. Rationale for monorepo: the synced slice mirrors the SQLite schema defined by goose migrations here — a schema change is one atomic PR across Go + Desktop + Mobile.

## Section 1: CloudKit Schema & Data Sync

**Container & zones.** One container `iCloud.<bundle-id>`, private database, two custom zones:

- `DataZone` — product slice. Desktop writes, mobile reads. Single writer ⇒ no conflicts by construction.
- `RelayZone` — commands and chat. Both sides write, but each record type has a single writer (see Section 2).

Separate zones give independent change tokens and a clean ownership rule.

**Record format: JSON blob, not field-per-column.** Each slice row (briefing, inbox item, target, track, digest, calendar event, person card) is one `CKRecord`, `recordName` = stable ID (e.g. `target-123`), fields:

- `payload` — the full row as JSON, stored in `encryptedValues` (E2E when the user enables Advanced Data Protection);
- `kind`, `modifiedAt` — plaintext service fields;
- payloads over ~500 KB (rare fat digests) go to a `CKAsset` instead of the inline field.

Rationale: CloudKit schema migration is painful and server-side queries are unnecessary — mobile pulls whole zones via change tokens. Schema evolution reduces to JSON evolution decoded by the shared Swift models.

**Synced slice (v1):** briefings, inbox items, targets, tracks, digests, calendar events, people cards — the same curated set the MCP server v1 spec exposes. Raw Slack messages are explicitly **not** synced (size, quota); questions requiring raw messages go through the relay to the Mac.

**Desktop side.** `CKSyncEngine` (Apple handles retries, batching, pushes, change tokens). Change source: GRDB `ValueObservation` on the slice tables (existing desktop pattern). "What was already pushed" state (recordName → updated_at/hash) lives in a **sidecar SQLite in the desktop app's Application Support** — deliberately not in the shared Go database, to avoid a goose migration + schema.sql churn for sync-internal bookkeeping. Deletions are detected by diffing sync state against live rows.

**Mobile side.** The same `CKSyncEngine` in the iOS app: zone changes → upsert into a local GRDB replica (tables of shape `id + payload JSON`, decoded into shared `WatchtowerKit` models). `CKDatabaseSubscription` → silent push → background refresh. Data waits in the cloud: a briefing pushed at 08:00 reaches the phone whenever, even if the Mac closed at 19:00.

**Pairing = zero config.** The private database is bound to the Apple ID. Signing into the same iCloud account on the phone is the entire pairing flow.

## Section 2: Relay Protocol — Mutations & Chat (RelayZone)

**Mutations (quick actions).** Mobile writes an `ActionRequest` record:

- `kind` — closed enum of commands: `target_done`, `target_snooze`, `inbox_resolve`, `inbox_dismiss`, `inbox_snooze`, `task_create`, `track_read` (the set = what existing desktop Queries support);
- `payload` (encrypted JSON: entity id, params), `createdAt`, `status: pending`.

Desktop receives a silent push via the zone subscription → applies the command **through the existing Swift Queries** (same code path as the desktop UI — no third mutation path, cf. the catch-up dual-ack lesson) → sets `status: applied|failed` (+ error message) → changed rows flow back through DataZone as normal sync.

Mobile applies the action to its replica **optimistically**, marks it pending, reconciles when updated data arrives; `failed` → revert + error toast.

**Chat.** `ChatSession` → `ChatMessage` (user turn) → desktop wakes on push, runs `ClaudeService` (`claude` CLI, streaming) and writes a `ChatChunk(sessionId, seq, text)` roughly every 1.5 s; the final chunk carries `done: true`. Mobile assembles chunks by `seq` — pseudo-streaming with a couple seconds of latency. Chunk records are monotonic appends; we never rewrite one record repeatedly (avoids optimistic-locking conflicts).

**Liveness detection.** Desktop refreshes a `Heartbeat` record every 5 minutes (negligible CloudKit quota cost). Mobile rule: heartbeat older than ~12 minutes **or** no first chunk within 20 s → offer "Mac unreachable — answer directly via API?" (Section 3 fallback). Never switch silently: the user must know they are about to spend API tokens with narrower context.

**Hygiene.** Desktop deletes `ActionRequest` records older than 7 days and chat records older than 30 days.

## Section 3: Mobile Agent Fallback & iOS App Structure

**LLM client.** In `WatchtowerKit`: protocol `MobileAgentBackend` with two implementations:

- `RelayBackend` — Section 2 path (primary);
- `DirectAPIBackend` — `URLSession` + SSE streaming to `api.anthropic.com`, user's own key (BYOK) in Keychain. Default model sonnet, configurable.

**Tool use over the replica.** `DirectAPIBackend` exposes read tools **identical to the MCP server v1 spec** (`list_targets`, `get_target`, `get_today_briefing`, `list_digests`, `get_digest`, `list_tracks`, `get_track`, `list_people`, `get_person`, `list_upcoming_events`), executed locally as SQL against the GRDB replica. The MCP spec is the contract (including "missing data → empty result, never an error"); long-term the same tool set backs three surfaces (MCP, relay agent, mobile agent).

Two write tools — `create_task`, `snooze_item` — do not touch the DB directly; they enqueue `ActionRequest` records (Section 2; `snooze_item` maps to `target_snooze`/`inbox_snooze` by entity type, `create_task` to `task_create`). The offline agent can "do" things that land on the Mac with the rest of the queue.

**System prompt** — adapted from the desktop chat prompt: same role, but the schema description covers the slice only, plus an honest "you have no raw Slack messages; if the answer needs quotes from conversations, tell the user the desktop is required."

**iOS app structure** (mirrors the proven desktop architecture):

```
WatchtowerMobile/
├── App/            WatchtowerMobileApp, TabView routing
├── Sync/           CKSyncEngine wrapper, ReplicaStore (GRDB), ActionQueue
├── Chat/           ChatViewModel, backend switcher, ChatView
├── Features/       Today (briefing + day calendar) | Inbox | Tasks | Tracks | Settings
└── (models, relay protocol, agent tools — imported from WatchtowerKit)
```

Five tabs: **Today**, **Inbox**, **Tasks**, **Tracks**, **Chat** (+ Settings). ViewModels use the same `@MainActor @Observable` + GRDB `ValueObservation` pattern as the desktop: CloudKit changes flow to the UI with no manual refresh.

**Notifications as a product feature.** CloudKit subscriptions provide silent pushes for sync; visible alerts are generated locally: the desktop tags slice records with `notifyLevel` (urgent inbox item, briefing ready, calendar conflict), mobile fetches on silent push and raises a **local notification**. The "what matters" logic stays on the desktop where the AI already prioritized.

## Section 4: Security, Onboarding, Error Handling, Testing

**Onboarding (product path).**

1. Install desktop → Settings → enable "Mobile sync" → desktop checks the iCloud account and starts the initial slice push;
2. Install the iOS app → same Apple ID → replica hydrates automatically, zero configuration;
3. Optional: enter an Anthropic API key for the offline agent (Settings → Keychain); without it, chat simply requires the Mac.

No QR codes, no tokens, no "enter server address". Requirements: one Apple ID on both devices, iCloud Drive enabled.

**Security.**

- All content fields go through `encryptedValues` only (E2E with Advanced Data Protection; onboarding gently recommends enabling ADP);
- API key and secrets in Keychain (`kSecAttrAccessibleAfterFirstUnlock`);
- The SQLite replica sits in the app container under iOS Data Protection; no custom crypto;
- The relay executes only commands from the closed `kind` enum — arbitrary SQL/code cannot travel from phone to Mac by construction.

**Error handling (main failure modes).**

- **User's iCloud quota full** (`quotaExceeded`) → desktop banner, sync pauses, local operation unaffected;
- **No iCloud account / disabled** → both sides show an explicit "sync off" status; mobile lives on the last replica;
- **Mac asleep during chat** → 20 s timeout → fallback offer; never a silent hang;
- **Edit conflicts** — nearly impossible by construction (DataZone single-writer, chunks monotonic); on `serverRecordChanged` in DataZone the policy is "desktop always wins";
- **Duplicate command delivery** (push arrives twice) → commands are idempotent: `applied` is checked by recordName before execution.

**Testing.** CloudKit cannot run in unit tests, so the seam is a `CloudSyncTransport` protocol with an in-memory fake. Covered on the fake: sync-state diff logic (what to push/delete), chunk assembly by `seq`, `ActionRequest` idempotency, optimistic-mutation revert on `failed`, heartbeat fallback trigger. Mobile agent tools are tested like ordinary Queries against a fixture GRDB database (same style as the 490 existing desktop tests). E2E against live CloudKit — manual via TestFlight, not in CI.

## LLM Access Policy

- **Primary:** relay to the Mac; the subscription token never leaves the Mac (`claude` CLI runs there) — fully ToS-clean.
- **Fallback:** user's own Anthropic API key from the phone (BYOK), explicit opt-in per conversation when the Mac is unreachable.
- **Explicitly rejected for the product:** shipping the Claude subscription OAuth token (or `claude setup-token` output) to the phone — Anthropic ToS restricts subscription tokens to official clients and has blocked lookalike clients before.

## Out of Scope for v1 (deliberate)

On-device model (Apple Foundation Models), direct Tailscale channel as a fast path, raw Slack message sync, Apple Watch app, widgets, Android.

# Targets — Prefill from Source

Date: 2026-04-28
Status: Approved (awaiting implementation plan)
Branch: TBD (likely a continuation of `feature/targets-ai-ui`)

## Summary

Whenever a target is created from an in-app source (Briefing attention item, Digest, Track, Inbox item, or a parent target's sub-item being promoted), the form must open with a content-rich prefill computed from the actual source records in the local SQLite DB — `text`, a substantive `intent` lifted from the upstream entity, and `secondary_links` where applicable. No LLM call is made at form-open time; this is a synchronous mapping `source → form fields`. The existing "Extract with AI" button stays in the form as an optional enrichment path.

## Motivation

Today the five "create target from source" entry points pre-fill only `text` (and occasionally an empty `intent`), forcing the user to retype context they already know is in the source — channel name, snippet, narrative, reason — every single time. The result is either skipped intent (lost provenance) or copy-paste churn. Pulling that context from the DB on the way into the form is a small, deterministic change that meaningfully shortens "create target from briefing item" from "type intent yourself" to "review pre-filled intent and hit Create".

## Current State (audit)

**Go backend** — already supports everything we need at the data layer:

- `internal/db/targets.go:29-78` — `CreateTarget()` (single-row insert; recomputes parent progress).
- `internal/targets/store.go:29-59` — `Store.CreateBatch()` (extract path; not touched by this spec).
- `internal/db/schema.sql:322-360` — `targets` table; `source_type` CHECK accepts `extract | track | digest | briefing | manual | chat | inbox | jira | slack | promoted_subitem`. `target_links` table holds `secondary_links`.

**Swift desktop**

- `WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift` — single user-facing form. Currently exposes a parameter sprawl: `prefillText`, `prefillIntent`, `prefillSourceType`, `prefillSourceID`. Has an "Extract with AI" button (untouched by this spec).
- `WatchtowerDesktop/Sources/Views/Targets/PromoteSubItemSheet.swift` — separate form for sub-item promotion. Already inherits `level / priority / ownership / dueDate` from the parent in `init()`. Today its `intent` defaults to bare `parent.intent`.
- `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift:162` — `TargetQueries.create(...)` is the single GRDB INSERT path used by both sheets.
- Five existing callsites that open one of the two sheets with prefill:
  - `WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift:27-34, 191-193`
  - `WatchtowerDesktop/Sources/Views/Digests/DigestDetailView.swift:69-74`
  - `WatchtowerDesktop/Sources/Views/Tracks/TrackDetailView.swift:492-506`
  - `WatchtowerDesktop/Sources/Database/Queries/InboxQueries.swift:149-150` (Inbox-card → CreateTargetSheet path)
  - `TargetDetailView` → `PromoteSubItemSheet` (sub-item promotion)

## Scope

In scope:
- Introduce a single `TargetPrefillBuilder` that consumes the DB and returns a `TargetPrefill` per source. Five builders, one structure, owned tests.
- Replace `CreateTargetSheet`'s sprawl of `prefill*` parameters with `prefill: TargetPrefill?`.
- Extend `PromoteSubItemSheet` to receive a precomputed `prefilledIntent` (so its intent is content-rich, not just `parent.intent`).
- Extend `TargetQueries.create(...)` to accept `secondaryLinks: [TargetPrefillLink]` and write them in the same transaction as the target itself.
- Update all five callsites to invoke the builder before opening the sheet.

Out of scope:
- Any LLM call at form-open time. The existing "Extract with AI" button stays as is.
- The CLI paths (`watchtower targets create`, `watchtower inbox task`) — they remain flag-driven.
- Localization. The intent strings produced by the builder are hard-coded English (consistent with the rest of the UI today). When the app gains a String Catalog, the small set of label strings introduced here gets keyed in the same pass as everything else.
- Any change to the existing `internal/targets/Pipeline.Extract` AI-extract flow.
- A unification refactor that would fold `PromoteSubItemSheet` into `CreateTargetSheet`.
- Source-type changes / new CHECK values on `targets.source_type`.

## Design

### 1. New Swift type — `TargetPrefill`

New file `WatchtowerDesktop/Sources/Models/TargetPrefill.swift`:

```swift
struct TargetPrefill: Equatable {
    var text: String
    var intent: String
    var sourceType: String   // one of the existing source_type CHECK values
    var sourceID: String
    var secondaryLinks: [TargetPrefillLink] = []
    var parentID: Int? = nil // promote-subitem only
}

struct TargetPrefillLink: Equatable {
    var externalRef: String  // must satisfy IsValidExternalRef: "jira:..." or "slack:..."
    var relation: String     // "contributes_to" | "blocks" | "related" | "duplicates"
}
```

The struct mirrors what `TargetQueries.create(...)` already accepts plus the new `secondaryLinks` and `parentID` fields. `parentID` is kept on the prefill (not on the form fields) because it is a structural decision, not a user-editable field in the create flow today.

### 2. New Swift service — `TargetPrefillBuilder`

New file `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift`. Static methods, all `async throws`, all take a `DatabaseManager` (or a `DatabasePool`) so the per-source DB queries are explicit:

```swift
enum TargetPrefillBuilder {
    static func fromBriefingItem(_ item: AttentionItem,
                                 briefing: Briefing,
                                 db: DatabaseManager) async throws -> TargetPrefill
    static func fromDigest(_ digest: Digest,
                           topic: DigestTopic?,
                           db: DatabaseManager) async throws -> TargetPrefill
    static func fromTrack(_ track: Track,
                          db: DatabaseManager) async throws -> TargetPrefill
    static func fromInbox(_ item: InboxItem,
                          db: DatabaseManager) async throws -> TargetPrefill
    static func fromSubItem(parent: Target,
                            subItem: TargetSubItem,
                            index: Int) -> TargetPrefill   // sync, no JOINs needed
}
```

Each method opens a single short `dbPool.read { ... }` transaction, performs the lookups it needs, and returns. On a missing related entity (e.g., the upstream track referenced by a briefing item has been deleted), the relevant intent fragment is omitted; the builder does not throw on those soft cases. It only throws on hard DB errors.

#### 2.1 `fromBriefingItem` — pass-through to upstream

Briefing is a meta-entity (a roll-up of items pulled from tracks / digests / inbox). The new target should reference the **upstream entity**, not the briefing itself, when the attention item carries `source_type + source_id`.

- If `item.sourceType` is one of `track | digest | inbox`:
  - Load the upstream entity by id. If it is missing, fall through to the fallback below.
  - `text = item.text`
  - `intent` is built by recursively delegating to the upstream builder's intent contribution (see 2.2-2.4) and prepending a one-line provenance prefix `"Surfaced in briefing of \(briefing.dateLabel)."` plus, when present, `"Reason: \(item.reason)"` and `"Briefing flag: \(item.priority)"`.
  - `sourceType = item.sourceType!`
  - `sourceID  = item.sourceID!`
  - `secondaryLinks` — same as the upstream builder would produce (e.g., slack channel ref for track / digest).
- Fallback (no upstream, or upstream not found):
  - `text = item.text`
  - `intent = item.reason` if non-empty, else empty.
  - `sourceType = "briefing"`
  - `sourceID = String(briefing.id)`
  - `secondaryLinks = []`

#### 2.2 `fromDigest` — channel context + summary

- Query `ChannelQueries.fetchByID(digest.channelID)` → `channelName` (fallback to channel id if not found).
- `text = topic?.title ?? digestSummaryFirstLine(digest)` (single line — the form's `text` field is short by convention).
- `intent`:
  - Header line: `"From #\(channelName) digest on \(digest.dateLabel):"`.
  - Body: `topic?.summary ?? digest.summary`.
  - If `topic?.parsedKeyMessages` is non-empty: `"\nKey messages:\n  • <up to 5 joined by newlines>"`.
- `secondaryLinks = [TargetPrefillLink(externalRef: "slack:\(digest.channelID)", relation: "related")]` if `channelID` is non-empty, else `[]`.
- `sourceType = "digest"`, `sourceID = String(digest.id)`.

#### 2.3 `fromTrack` — narrative + decision + channels

- Query channel names for `track.decodedChannelIDs` (cap 3 lookups).
- `text = track.text`.
- `intent`:
  - Body: `track.context` (the narrative).
  - If `track.decisionSummary` is non-empty: `"\nDecision: \(track.decisionSummary)"`.
  - If `track.blocking` is non-empty: `"\nBlocking: \(track.blocking)"`.
  - If channel names list is non-empty: `"\nIn channels: \(names.joined(separator: ", "))"`.
- `secondaryLinks = track.decodedChannelIDs.prefix(3).map { TargetPrefillLink(externalRef: "slack:\($0)", relation: "related") }`.
- `sourceType = "track"`, `sourceID = String(track.id)`.

#### 2.4 `fromInbox` — sender / channel / why-it-matters

- Queries: `UserProfileQueries.fetchByID(item.senderUserID)` → `senderDisplayName` (fallback to the raw user id), `ChannelQueries.fetchByID(item.channelID)` → `channelName` (fallback to channel id).
- `text = item.snippet`.
- `intent`:
  - Header: `"From @\(senderDisplayName) in #\(channelName) (\(item.triggerType))."`.
  - Body: `"\"\(item.snippet)\""` (quoted snippet — anchors the user even after the upstream Slack message scrolls away).
  - If `item.aiReason` non-empty: `"\nWhy it matters: \(item.aiReason)"`.
- `secondaryLinks = [TargetPrefillLink(externalRef: "slack:\(item.permalink)", relation: "related")]` if `item.permalink` non-empty, else `[]`.
- `sourceType = "inbox"`, `sourceID = String(item.id)`.

#### 2.5 `fromSubItem` — synchronous parent inheritance + siblings hint

This one needs no DB query — `parent` is already the in-memory `Target` the user is looking at.

- `text = subItem.text`.
- `intent`:
  - Header: `"Sub-target of #\(parent.id) «\(parent.text)»."`.
  - If `parent.intent` is non-empty: `"\nParent context: \(parent.intent)"`.
  - If `parent.decodedSubItems` has other open siblings (excluding this index): `"\nSibling sub-items:\n  • <up to 5 joined>"`.
- `sourceType = "promoted_subitem"`.
- `sourceID = "\(parent.id):\(index)"` (matches the format `internal/db/targets_promote.go` writes today; keep the contract).
- `parentID = parent.id`.
- `secondaryLinks = []`.

### 3. `CreateTargetSheet` — API simplification

Current sprawl is replaced by a single optional prefill:

```swift
struct CreateTargetSheet: View {
    var prefill: TargetPrefill? = nil
    // ... rest of @State and body unchanged
}
```

`onAppear` body becomes:

```swift
.onAppear {
    if let p = prefill {
        text = p.text
        intent = p.intent
        sourceType = p.sourceType
        sourceID = p.sourceID
        secondaryLinks = p.secondaryLinks
    }
}
```

`sourceType` and `sourceID` move from `let prefill*` to `@State` (they are needed at create-time, not editable in the form, but they should be passed through to `TargetQueries.create(...)`). `secondaryLinks` is a new `@State [TargetPrefillLink]`. The form does not render an editor for them in this scope — they exist purely to be persisted on Create. (A future enhancement could expose them as removable chips in the form; out of scope here.)

The "Source: briefing #42" footer line is preserved; it now reads `sourceType` / `sourceID` from the new `@State`.

The `extractButton` ("Extract with AI") flow is untouched. Today it opens `ExtractPreviewSheet` independently of the surrounding form — that path is orthogonal to this spec.

### 4. `PromoteSubItemSheet` — accept prefilled intent

`PromoteSubItemSheet` keeps its specific signature (it owns level / priority / ownership / dueDate inheritance, which is more than the generic prefill carries). One change: a new optional initializer parameter `prefilledIntent: String?`. If non-nil, the `_intent = State(initialValue: prefilledIntent)` overrides today's `_intent = State(initialValue: parent.intent)`.

Callsite (`TargetDetailView`) computes the prefill via `TargetPrefillBuilder.fromSubItem(parent:subItem:index:)` (synchronous) and passes its `intent` field as `prefilledIntent`.

### 5. `TargetQueries.create(...)` — accept secondary links

Current signature in `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift:162`:

```swift
static func create(_ db: Database,
                   text: String, intent: String,
                   level: String, periodStart: String, periodEnd: String,
                   priority: String, subItems: String,
                   sourceType: String, sourceID: String) throws -> Int
```

Add a new trailing parameter `secondaryLinks: [TargetPrefillLink] = []`. After the `targets` INSERT, in the same write transaction, insert one row per link into `target_links` (`source_target_id = newTargetID`, `external_ref = link.externalRef`, `relation = link.relation`, `confidence = NULL`, `target_target_id = NULL`).

Validation: skip any link whose `externalRef` does not satisfy `IsValidExternalRef` (matches the Go-side contract in `internal/targets/extractor.go:146`); log via `print(...)` (no Logger plumbing here). The default empty array preserves all existing callers (tests, extract flow) unchanged.

### 6. Callsite changes (5 sites)

Pattern across all five sites: existing direct prefill assignment is replaced by an `async` Task that builds the prefill, then sets `showCreateTarget = true`. Errors surface as a small banner near the trigger.

| Callsite | Builder method | Notes |
|---|---|---|
| `BriefingDetailView.swift:191-193` | `fromBriefingItem(item, briefing:, db:)` | Existing `targetPrefillText / targetPrefillIntent` `@State` is replaced by a single `targetPrefill: TargetPrefill?`. |
| `DigestDetailView.swift:69-74` | `fromDigest(digest, topic: nil, db:)` | If/when the view supports per-topic create, pass the topic; not in this spec. |
| `TrackDetailView.swift:492-506` | `fromTrack(track, db:)` | |
| `InboxQueries.swift:149-150` (Inbox-card flow) | `fromInbox(item, db:)` | The actual sheet trigger lives in `InboxCardView` / `InboxFeedView`; the query helper just supplies data. The async builder call belongs in the view, not in the query helper. |
| `TargetDetailView` → `PromoteSubItemSheet` | `fromSubItem(parent:, subItem:, index:)` (sync) | Pass the resulting `intent` as `prefilledIntent:` to the sheet. |

### 7. Error handling

- Builder throws → callsite shows a small inline banner ("Failed to prepare prefill: \(error.localizedDescription)") and **does not open the sheet**. The user can retry the click. We do not silently fall back to a half-empty prefill, because the missing data is exactly the data the feature is supposed to surface.
- Soft "missing related entity" cases (upstream track deleted, channel renamed, user profile not synced yet) are absorbed inside the builder via fallback labels (channel id instead of name, raw user id instead of display name). They do not throw.

### 8. Tests

New file `WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift`. Use the existing `TestDatabase` helper (`WatchtowerDesktop/Tests/Helpers/TestDatabase.swift`) to seed an in-memory schema.

Cases:
1. `fromBriefingItem` with `item.sourceType = "track"` and the upstream track present — assert `target.sourceType = "track"`, `target.sourceID = item.sourceID`, `intent` contains both `track.context` and the briefing reason prefix.
2. `fromBriefingItem` with no `item.sourceType` — fallback path: `target.sourceType = "briefing"`, `target.sourceID = String(briefing.id)`.
3. `fromBriefingItem` with `item.sourceType = "track"` but the track row was deleted — falls back to the briefing path; does not throw.
4. `fromDigest` happy path: channel resolved, key messages present, `secondaryLinks` populated.
5. `fromDigest` with channel id not in `channels` table — `intent` falls back to channel id; no throw.
6. `fromTrack` happy path: narrative + decision + 2 channels resolved → `intent` contains all four pieces, `secondaryLinks` has 2 entries.
7. `fromInbox` happy path: sender display name resolved, channel resolved, snippet quoted in intent, permalink in `secondaryLinks`.
8. `fromInbox` with empty `permalink` — `secondaryLinks` is empty.
9. `fromSubItem` with parent that has 3 open siblings — sibling list is rendered; `parentID` is set.
10. `TargetQueries.create(... secondaryLinks: [...])` — round-trip: assert exactly N rows inserted into `target_links`, and that an invalid `externalRef` (e.g. `"http://..."` ) is dropped, not persisted.

UI tests are not added in this spec. The change is mechanical at the callsites and the form itself does not change layout. Existing `CreateTargetSheet` smoke / build tests cover the rename of the sheet's parameter list.

## Risks and Open Questions

- **Channel name lookup may be slow on cold cache.** GRDB read of `channels` is microseconds per row; not a real risk, but worth a sanity check on a freshly-synced workspace where `channels` has thousands of rows.
- **Intent length.** A track with a long narrative + decision + blocking + channels can produce a >500-char `intent`. The form's `intent` editor already has `maxHeight: 110`, so it scrolls. Acceptable.
- **AttentionItem upstream type extension.** Today `AttentionItem.sourceType` is mapped to track / digest / inbox. If the briefing prompt ever emits a new upstream type (e.g., `meeting`), the `fromBriefingItem` switch will need a new branch. We log-and-fall-back to the briefing path on unknown types so the form keeps working.
- **No localization yet.** All strings produced by the builder are hard-coded English. Consistent with the rest of the desktop UI; revisit when a String Catalog lands.
- **The "Extract with AI" button is now slightly redundant for the source-prefilled case.** It still has value when the user pastes additional free-form text on top of the prefill, but expect product / UX feedback once this ships.

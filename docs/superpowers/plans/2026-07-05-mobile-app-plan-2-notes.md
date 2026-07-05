# Carry-over Notes for Plan 2 (Desktop Hub) — from Plan 1 Final Review

Binding inputs for whoever writes/executes Plan 2. Source: Plan 1 whole-branch review (branch `feature/mobile-app`, 0eddabd..5774968).

1. **CloudChangeToken shape must be validated by a CKSyncEngine spike BEFORE anything persists a `CloudChangeToken`.** The seam's token is `value: Int` and pull-based (`changes(since:)`); real `CKServerChangeToken` is opaque `Data` and CKSyncEngine is push-to-delegate. Plan 2's FIRST task: spike the real adapter against the seam; if the shape doesn't survive contact, switch the token to opaque `Data` then — it is `Codable` (intended for persistence), so reshaping after anything persists it is a storage migration. The ordering is the load-bearing part.

2. **Per-record encode-failure handling in the push loop.** `RowPayloadCoder.payload(from:)` throws `EncodingError` on `Double.infinity`/`NaN` (SQLite REAL can hold them, e.g. `9e999`). The sync engine must skip-and-log that record, never abort the push cycle. Add to Plan 2's silent-failure checklist.

3. **Idempotent-delete transport contract is undecided.** `InMemoryCloudTransport.delete` of a never-saved recordName silently emits a tombstone; real CloudKit surfaces `.unknownItem`. Plan 2 must either document idempotent delete on the `CloudSyncTransport` protocol and normalize the CK adapter to match (swallow `.unknownItem` — consistent with spec Section 4 duplicate-delivery idempotency), or change the fake. Until decided, tests must not assert on delete-of-unknown behavior.

4. **Relay record-kind constants.** Relay payloads define recordName prefixes (`action-`, `chatmsg-`, `chatchunk-`) but no canonical `CloudRecord.kind` strings. Define them (e.g. static constants next to each payload) when Plan 2 first writes relay records — do not invent ad hoc strings.

5. **(Plan 3) `RunningSummary.Meta` members are internal.** Publicize when the iOS app reads `.meta` — a compile error at that point is expected, not a regression.

6. **(Plan 3) Add one Kit test file with a plain `import WatchtowerKit`** (no `@testable`) to compile-check the public API exactly as the iOS app consumes it.

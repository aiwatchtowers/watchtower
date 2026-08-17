# Mobile: digests reading surface + stream_digest slice

Date: 2026-08-17. Workstream 4 of the mobile reanimation plan
(`docs/superpowers/plans/2026-08-17-mobile-reanimation-plan.md`).

## Goal

The phone can READ digests: Slack channel/daily/weekly digests (already
synced as `digest` + `digest_topic` slices) and Gmail/Jira stream digests
(new `stream_digest` slice). Opening a digest on the phone marks it read on
the desktop through the existing relay-action pattern. No editing, no
generation, no deletion from the phone.

## Wire format

### New slice kind: `stream_digest`

- `SliceKind.streamDigest = "stream_digest"` appended to the enum (rawValue
  frozen; pinned in `RowPayloadCoderTests.testAllSliceKindRawValuesAreFrozen`).
- Publisher window: `SELECT * FROM stream_digests ORDER BY id DESC LIMIT 50`
  — the same window shape as the `digest` slice. All columns ship: the only
  content column is `topics_json`, which IS the digest body (no equivalent of
  `transcript_text`/`speakers_json` to project away; a stream digest tops out
  at a few KB of topic candidates).
- Record name: `stream_digest-<id>`.

### `digest` slice: additive `channel_name` column

The phone has no `channels` table, so the publisher resolves the channel name
in SQL (the `meeting_transcript` slice's `event_title` precedent):

```sql
SELECT d.*, (SELECT name FROM channels WHERE id = d.channel_id) AS channel_name
FROM digests d ORDER BY d.id DESC LIMIT 50
```

Additive only — old phone builds ignore the extra key; the Kit `Digest`
model gains an optional `channelName` (`channel_name`), nil for cross-channel
(daily/weekly) digests and unsynced channels.

### Kit replica mirror: `StreamDigest`

Public Kit model mirroring the Core model column-for-column
(`id`, `source`, `account_id`, `scope`, `period_from`, `period_to`,
`topics_json`, `created_at`, `read_at`) plus public `StreamTopic` /
`StreamCandidate` for `topics_json` decoding. The desktop executable keeps
resolving the bare names to Core via `Sources/App/CoreTypeAliases.swift`.

### New relay actions

- `ActionKind.digestRead = "digest_read"` — entity id = `digests.id`;
  desktop applies `DigestQueries.markDigestRead` (no-op if already read).
- `ActionKind.streamDigestRead = "stream_digest_read"` — entity id =
  `stream_digests.id`; desktop applies `StreamDigestQueries.markRead`.

Both follow the existing switch: `requireRow` first, unknown id → `.failed`
echo, no params. RawValues appended to the frozen
`RelayPayloadTests.testAllActionKindsAreStable` pin.

## Phone UI

- Entry point: a `NavigationLink` row on Today (below Today's Calendar,
  beside the Recordings link precedent) — NOT a seventh tab.
- `DigestsView` (list): Slack digests and stream digests merged, newest
  first by `created_at`. Slack rows show channel (or "Daily digest" /
  "Weekly digest" for cross-channel types), period, summary snippet, unread
  dot. Stream rows show source (Gmail/Jira), scope, period, unread dot.
- `DigestDetailView`: summary + topics (from the `digest_topic` slice,
  ordered by `idx`) with each topic's decisions. Legacy digest without
  topic rows falls back to the digest-level `decisions` JSON. Stream detail:
  topics with their decision/idea candidates. Read-only.
- Mark-as-read: detail `.task` enqueues `digestRead`/`streamDigestRead`
  through `ActionOutbox` when `read_at` is nil (once per open); the read
  state flips when the updated row hydrates back. Failure to enqueue is
  logged, never blocks reading.

## Invariants

1. `stream_digest` rawValue, `digest_read`/`stream_digest_read` rawValues,
   and the `channel_name` key are wire format — frozen by literal fixtures.
2. The phone never mutates replica rows; read state arrives only via
   hydration (pending overlay not required for reads — a lost action leaves
   the digest unread, which self-surfaces).
3. Desktop mark-read remains idempotent (`read_at IS NULL` guard); duplicate
   relay delivery is absorbed by the processed set.
4. The replica needs no new tables: digests reuse the generic
   `slice_records` store like every other kind.

## Test plan

- Kit: SliceKind + ActionKind frozen pins updated; literal `digest_read`
  action encode fixture; hydrate-and-decode tests for `StreamDigest` and
  `Digest` payloads including degenerate input — stream digest with empty
  `topics_json`, legacy digest without `channel_name` and with `[]` topics.
- Desktop `SlicePublisherTests`: `stream_digest` publishes the full row
  (fixture asserts columns incl. `topics_json`/`read_at`); `digest` records
  carry `channel_name` when the channel row exists and NULL when not.
- Desktop `RelayProcessorActionTests`: `digest_read` and
  `stream_digest_read` apply → `read_at` set + `.applied` echo; unknown id →
  `.failed`; second delivery does not clobber the first `read_at`.
- `make mobile-build` compiles the new phone surface (device gate runs on
  the controller's merged build).

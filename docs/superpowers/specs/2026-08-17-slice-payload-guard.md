# Slice payload size guard (mobile reanimation plan, Workstream 5 item 14)

## Goal

Close the `.limitExceeded` retry-forever hole in the slice publish pipeline.
Today no payload size check exists anywhere: an oversized record (unbounded
`notes_md` / `chapters_json`) reaches CloudKit, the save fails with
`.limitExceeded`, the failure is unhandled, and the engine retries forever —
while `publishOnce` has already recorded the row's hash, so the diff believes
the row published and never re-offers it.

## Design

The guard lives in `SlicePublisher.publishOnce` (not `SliceDiff`, which stays
pure/stateless — the throttle needs per-publisher state):

- Threshold: `SlicePublisher.maxPayloadBytes = 900_000` bytes, checked against
  the ENCODED payload (`SliceRecord.payload`, the RowPayloadCoder JSON that
  becomes the CKRecord's `payload` field 1:1). CloudKit's per-record cap is
  1 MB; the 100 KB headroom covers system fields, `kind` / `modifiedAt` /
  `notifyLevel`, and record-name overhead.
- Oversized upserts are partitioned out BEFORE `transport.save`:
  - NOT saved,
  - their hash is NOT recorded in `HubSyncState` (so the diff re-offers the
    row every cycle, and a later smaller version publishes normally),
  - counted in the returned `skipped` stat by record name,
  - logged as a warning with the row identity and byte size — throttled per
    (recordName, payload hash): the same stuck oversized payload warns once,
    a CHANGED oversized payload for the same row warns again.
- The publisher's end-of-cycle "un-encodable" warning now covers only
  diff-level skips (encoder throw / invalid id); oversized rows are excluded
  from that line so a stuck row does not re-spam it every cycle.
- A successful publish of a record clears its throttle entry, so a row that
  shrinks below the threshold and later grows oversized again warns again.

## Wire format

Unchanged. No new record fields, no payload changes; records at or below the
threshold are completely unaffected.

## Invariants

1. `payload.count <= maxPayloadBytes` for every record handed to
   `transport.save` by the slice publisher.
2. An oversized row never gets its hash recorded — the diff keeps seeing it
   as unpublished.
3. Below-threshold behavior is byte-for-byte identical to before.
4. One warning per distinct oversized (recordName, payload hash) pair per
   publisher lifetime.

## Test plan (SlicePublisherTests style, no hardcoded dates)

- Oversized row → in `skipped`, not in transport, hash absent; sibling normal
  row publishes in the same cycle untouched.
- Shrink the oversized row → next cycle publishes it normally.
- Same oversized row across two cycles → skipped both times, ONE warning
  (observed via an internal warning counter); mutate the row while still
  oversized → a second warning.
- Boundary (degenerate-input rule): payload of exactly `maxPayloadBytes` is
  NOT oversized; one byte more is.

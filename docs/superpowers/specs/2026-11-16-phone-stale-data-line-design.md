# The phone says how old its workbench data is

Target #1873 (group #1871); owner decisions: ask #1396 ("Причина + видимость"), ask #1398
(the wire field, Now, the tone), ask #1399 (the tone against the orange rule).
Mockups: [`2026-11-16-phone-stale-data-line-mockups.html`](2026-11-16-phone-stale-data-line-mockups.html)
(branch `fix/1873-hub-publish-visibility`, beside this file).

## Problem

When the tower stops publishing, the phone keeps drawing its replica: answered asks still open,
finished sessions still working. Two failures did this:

- **The whole publish is down** (relay `unavailable` for hours). No record arrives, the heartbeat
  included.
- **One kind is stuck** (November 11–15: `record_too_large` on one kind while the heartbeat and
  the other kinds kept going). The heartbeat stays fresh; nothing on the phone can tell.

Nothing on the Workbench tab says the data is old. Now's tower chip turns to "asleep · last seen
2 h ago" in the first case only, and that reads as a normal sleeping Mac.

## What the phone knows

- The tower's **heartbeat**: `updated_at` (restamped every 15 min, so its age is the age of the
  newest data the tower sent) and `last_publish_at` (the end of the last cycle that published
  anything). The phone's online rule is "heartbeat under 35 min old"
  (`RelayFeed.heartbeatStaleAfter`, owner decision Q2 on board #724).
- **Whether Relay answers this iPhone** (`HubSession.relayUnansweredSince`, set while the phone's
  own calls to Relay fail). It lives in memory: after an app restart it is empty until a call
  fails again, which the launch fetch does within seconds.
- New, **`stuck_since`** in the heartbeat (below).

## The wire change: `stuck_since`

The heartbeat gains an optional `stuck_since` (Unix seconds, like its other times): when the
oldest kind the hub still cannot publish whole first failed. A kind is stuck from its first
attempt that did not go through whole (a failed save, a failed source read, or a record the
cycle skipped: oversized, unsealable, refused by the transport) until an attempt goes through
whole. The field is absent while every kind goes through, and from an older hub (which then
behaves as today). The heartbeat restamps at once when the value changes, so the phone sees it
with the next full diff (60 s), not the next 15 min stamp. `last_publish_at` keeps its meaning.

Contract: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` heartbeat row, Go
`wire.Heartbeat.StuckSince`, Kit `HeartbeatPayload.stuckSince`, the shared fixture
`hub_contract_cases.json` case `stuck_since`.

## The line

One line at the top of the screen, under the tower chip:

| State | When | Line |
|---|---|---|
| Fresh | heartbeat under 35 min old, Relay answers, nothing stuck 10 min or more | no line |
| Stuck | `stuck_since` 10 min old or more | `Updated 08:26 · Acme Mac is not sending some updates` |
| Stale | heartbeat 35 min old or more | `Updated 15:20 · Acme Mac is not sending updates` |
| Offline | Relay has not answered this iPhone for 60 s (the Relay banner's own wait) | `Updated 15:20 · this iPhone can't reach Relay` |
| Loading / empty | not linked, or no heartbeat yet | no line (the screen's own empty or loading state stands) |

- Precedence: offline, then stale, then stuck. When the phone cannot reach Relay it cannot know
  what the tower sends; a stale heartbeat makes `stuck_since` old news.
- "Updated" is `stuck_since` for stuck (the stuck kind's data is no newer), and
  `last_publish_at` (else `updated_at`) for stale and offline. Never the heartbeat's own stamp
  alone: a heartbeat restamped every 15 min would look fresh over data that is not.
- Time: `15:20` today, `yesterday 15:20`, `14 Nov, 15:20` older, in the phone's time zone,
  locale and 12/24-hour setting.
- The tower is named as everywhere else (`TowerText.name`/`sentenceName`: its name, "your tower"
  without one).
- Stuck waits 10 min: a record refused once and taken on the retry (seconds later; 5 min for
  `record_too_large`) does not flash the line. Offline waits 60 s, as the Relay banner on Now does,
  so a short Relay failure does not flash it either.
- Tone: red (`PhoneTone.red`, role `status`), with an `exclamationmark.arrow.circlepath` glyph.
  Orange stays reserved for waiting-for-you (spec §14, `OrangeToneTests`).
- The line ticks with the screen's existing `TimelineView` (Workbench list 30 s, workbench 60 s,
  Now 1 s), so it appears without a refresh once a threshold passes.

## Where

- **Now**: under the tower chip, above the Relay banner. Now leaves the offline state to that
  banner (it already says Relay does not answer, and when): there the line shows stuck and stale
  only, and nothing while Relay does not answer.
- **Workbench tab, the list of workbenches**: under the tower switcher chip, above
  "N folders on your tower". On the empty list it sits under the chip too.
- **Workbench tab, one workbench** (sessions, board, automations): the first row of the list,
  above the segment's content.

## Model and tests

`ReplicaFreshness` (WatchtowerMobile, Features/Workbench) takes the heartbeat, the tower's name,
`linked`, `relayUnanswered`, `now`, a calendar and a locale, and returns `nil` or the line (text
and tone). The strings live there. `ReplicaFreshnessTests` covers each state, the 35 min edge
(34:59 fresh, 35:00 stale), the 10 min stuck edge, the three date forms, an unnamed tower, the
precedence, and an older hub (no `stuck_since`). The Go side: `TestStuckSince*` (a refused kind,
a skipped record, clearing), `TestHeartbeatCarriesStuckSince` (present, restamped, cleared), the
contract fixture on both sides. The screenshot tour shows the stale line in place on Now (01s) and
both Workbench screens (05s, 06s), and the stuck, stale and offline lines side by side (06f).

## Docs

`docs/features/mobile-companion.md` (the line, its states, its red tone),
`docs/features/go-hub.md` (`stuck_since`, the log reasons), the protocol spec's heartbeat row,
and the user guide's iPhone page.

## Decisions

- New heartbeat field `stuck_since`, so a single stuck kind shows on the phone (ask #1398).
- The line shows on Now too, under the chip (ask #1398).
- Tone: red (ask #1399). It supersedes ask #1398's orange: orange is reserved for waiting-for-you
  on the phone (spec §14, `OrangeToneTests`), so the rule gets no exception.
- Stale threshold is the existing 35 min heartbeat rule, not a new 20 min one: one rule for
  "online" across the phone (решил агент; the 35 min rule is owner decision Q2 on #724).
- Stuck waits 10 min before the line shows (решил агент): the hub retries a `record_too_large`
  record every 5 min, so one refused-then-taken retry must not show; a real stuck kind shows
  10–11 min after its first failure.
- Offline waits 60 s, the Relay banner's wait, and Now leaves offline to that banner (решил агент,
  after the spec review).
- "Updated" reads `stuck_since` / `last_publish_at`, not the heartbeat's stamp (решил агент, after
  the spec review).
- Offline wins over stale, stale over stuck (решил агент).

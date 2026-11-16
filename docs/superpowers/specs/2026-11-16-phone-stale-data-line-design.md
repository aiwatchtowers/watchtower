# The phone says how old its workbench data is

Target #1873 (group #1871), owner decision ask #1396 ("Причина + видимость").
Mockups: [`2026-11-16-phone-stale-data-line-mockups.html`](2026-11-16-phone-stale-data-line-mockups.html).

## Problem

When the tower stops publishing (in the incident behind #1871 the Go hub's relay was
`unavailable` for hours), the phone keeps drawing its replica: answered asks still open,
finished sessions still working. Nothing on the Workbench tab says the data is old. The Now
tab's tower chip turns to "asleep · last seen 2 h ago", but that reads as a normal sleeping
Mac and the Workbench tab has no such hint at all.

## What the phone already knows

- The tower's **heartbeat** (`HeartbeatPayload.updatedAt`) in the replica. The hub republishes
  it every 15 min, so its age is the age of the newest data the tower sent. The phone's
  online rule is "heartbeat under 35 min old" (`RelayFeed.heartbeatStaleAfter`, owner decision
  Q2 on board #724); `MacReachability` and the Now chip read it.
- **Whether Relay answers this iPhone** (`HubSession.relayUnansweredSince`, non-nil while the
  phone's own calls to Relay fail). Now's Relay banner reads it.
- Whether the phone is linked at all, and whether a heartbeat ever arrived.

No new wire field is needed: the heartbeat's age and the phone's own Relay state cover the
failure. A tower whose heartbeat keeps arriving while one kind fails is not covered; part A
(the log reason) makes that visible on the tower side.

## The line

A quiet one-line caption at the top of the screen, under the tower chip:

| State | When | Line |
|---|---|---|
| Fresh | heartbeat under 35 min old and Relay answers | no line |
| Stale | heartbeat 35 min old or more | `Updated 15:20 · Acme Mac is not sending updates` |
| Offline | Relay does not answer this iPhone (heartbeat of any age) | `Updated 15:20 · this iPhone can't reach Relay` |
| Loading / empty | not linked, or no heartbeat yet | no line (the screen's own empty or loading state stands) |

- "Updated" is the heartbeat's time: `15:20` today, `yesterday 15:20`, `Nov 14, 15:20` older,
  in the phone's time zone and 12/24-hour setting.
- The tower is named as everywhere else (`TowerText.name`: its name, "your tower" without one).
- Offline wins over stale: when the phone cannot reach Relay, it cannot know whether the tower
  is sending.
- Tone: `PhoneTone.secondary` caption with a `clock.arrow.circlepath` glyph; never orange or red.
  It is a fact about the data, not an error the owner must fix.
- The line ticks with the screen's existing `TimelineView` (Workbench list 30 s, workbench 60 s),
  so it appears without a refresh once the 35 min pass.

## Where

- **Workbench tab, the list of workbenches**: under the tower switcher chip, above
  "N folders on your tower". On the empty list it sits under the chip too.
- **Workbench tab, one workbench** (sessions, board, automations): the first row of the list,
  above the segments' content.
- **Now**: no new line. The chip already says "asleep · last seen 2 h ago" from the same
  heartbeat and the Relay banner covers the phone's own Relay failure with its last-update line;
  a third line would repeat both.

## Model and tests

`ReplicaFreshness` (WatchtowerMobile, Features/Workbench) takes the heartbeat date, the tower's
name, `linked`, `relayUnanswered`, `now` and a calendar, and returns `nil` or the line's text.
The strings live there; `ReplicaFreshnessTests` covers each state, the 35 min edge (34:59
fresh, 35:00 stale), the three date forms, an unnamed tower, and offline winning over stale.
The screenshot tour gains frames for the stale and offline lines on both Workbench screens.

## Decisions

- Threshold is the existing 35 min heartbeat rule, not a new 20 min one: one rule for "online"
  across the phone, and the hub's 15 min heartbeat plus one missed write fits under it
  (решил агент; the 35 min rule itself is the owner's decision Q2 on #724).
- No new wire field: heartbeat age plus the phone's Relay state suffice (ask #1396 "Причина +
  видимость" asks for visibility from what exists; решил агент).
- Now gets no new line; its chip and Relay banner already say it (решил агент).
- The line is secondary-toned, not a warning (решил агент).

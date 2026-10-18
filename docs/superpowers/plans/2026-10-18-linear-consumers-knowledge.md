# Linear Plan 2, lane 2 — knowledge consumers (#688, #689)

Spec: `docs/superpowers/specs/2026-10-15-linear-integration-design.md` §4.3, §6
(rows memory, ideas, Catch-Up, KB search, tracks/digest, meeting prep / people
cards, `get_task_context` / `find_experts`, NL→SQL schema), §8. Migration 00144.
Owner rule: Linear behaves like Jira; Jira behaviour and its tests stay as they are.
Gating: the existing Jira switches govern both trackers (spec §3.5) — a
tracker-neutral surface that was gated on `jira.enabled` is gated on
`jira.enabled || linear.enabled`; `memory.sources.jira` governs the Linear
memory source too.

## Tasks

1. **`issue_slack_links` + neutral key detector.** Migration 00144 recreates
   `jira_slack_links` as `issue_slack_links` with `tracker` (rows copied as
   `'jira'`, ids and the AUTOINCREMENT mark kept, per-kind identities gain
   `tracker`). `internal/jira/key_detector.go` → `internal/issuekey` (a prefix
   that is a known Jira project key or Linear team key matches; one link per
   tracker). Go readers: Jira-only readers filter `tracker = 'jira'`
   (`GetJiraIssuesFor*`, who-to-ping, blockers, project map, without-Jira);
   neutral readers (`db/tracks.go` has-ticket filter, `slack_purge.go`) read
   both. Swift `JiraQueries` link reads + `JiraSlackLink` move in the same
   change (dual path). Tests: migration copy/down-up, per-tracker identity,
   Jira readers ignore Linear links, detector Linear cases, gate.
2. **Ideas + Catch-Up.** 00144 also adds `'linear'` to `stream_digests.source`
   and `idea_mentions.source`. `runLinearDigests`: one stage-1 pass per Linear
   account over issues updated since `linear_accounts.ideas_floor`, comments
   folded in, the same render/floor machinery as Jira (IDEA-01 floor honesty:
   floor only past rendered issues, tie drain, empty topics advance). Feature
   fast-forward stamps the Linear floors. Catch-Up names the stream "linear"
   and the section header covers Linear. Swift `StreamDigest.sourceLabel` /
   `IdeaMention.Source` learn `linear` (dual path).
3. **Memory.** `runLinearIngest`: mechanical issue → episode per Linear
   account, watermark `linear_accounts.memory_last_extracted_ts`, alias
   `linearissue:<account>:<id>`, provenance `linear:<KEY>` registered in the
   MEM-12 registry (resolves current and previous keys), scoped registries
   (linear builder linear-only; pipeline belief registry gains it). Seeds:
   Linear team keys become project entities.
4. **KB search.** `linearSource` (`linear:<account>:<key>`, anchors
   `account_id` + `key`, link = issue url); KB-03 fixture covers it.
5. **Meeting prep + people cards.** Attendee load from `tracker_issues`
   (both trackers); delivery stats from `tracker_issues` (Jira components
   still read from `jira_issues`).
6. **`get_task_context` / `find_experts`.** Jira first (unchanged), then a
   Linear issue by current or previous key: comments, links
   (`issue_slack_links`, previous keys included), decisions (`idea_mentions`
   source `linear`), people via `tracker_people`.
7. **Tracks / digest CLI + NL→SQL schema.** Linear issues linked to a track
   or digest are listed next to Jira ones; `internal/ai/prompt.go` documents
   `tracker_*` and `issue_slack_links`.
8. **Docs + inventory.** `docs/features/linear.md` consumers section; changelog
   entries in memory (MEM-12), ideas (IDEA-01), knowledge-search (KB-03),
   catchup, dev-surface, tracks, external-sources (EXT-04 unchanged).

## Contracts touched (extension only)

MEM-12 (`linear:` scheme), IDEA-01 (Linear stream floor), KB-03 (Linear
anchors), EXT-04 (the detector imports no AI/sync package), DEV-02/03
(mechanical, cites `linear` evidence by key), FEAT-03 (fast-forward covers
the Linear floors).

## Tests

Inner loop per package (`go test ./internal/<pkg>`), cmd tests by `-run`,
`make lint-diff`, filtered Swift tests (`JiraQueriesTests`,
`StreamDigestQueriesTests`) under the shared Swift lock, `make lint-swift`.

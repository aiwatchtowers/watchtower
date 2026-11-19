## 13. Contracts touched (all approved by the owner in ask #1373)

- **PROJ-12** (ask answer delivery; the spec named it PROJ-13 before the inventory check — PROJ-13 is the ask guard and is not changed): a non-owner writer of `owner_asks.answer`, and `origin`/journal marking of twin answers.
- **PROJ-21** (permission answers): a third decider besides Mac and phone.
- **PROJ-14** (finish_session): in an armed session the finish gate waits for the twin's review Approve; the twin may answer the handover ask.
- **SPECREVIEW-0x**: a spec/plan verdict written by the twin (marks still written by the Desktop).
- **REVIEW-0x**: a review round approved by the twin; Approve counts for merging into a non-main branch (skill pack rule).
- **AGENT-0x / DEV-06**: the brief line; no new MCP tool for agents.
- Ask guard / presence semantics: Watchman's mode is separate from `owner_presence`; presence is not changed.
- **Go hub** (`docs/features/go-hub.md`, PROJ-12/21 on the hub): the answer core moves to `internal/askanswer`; the hub's phone behaviour is unchanged (its tests move with the code).
- **C1 Inbox**: one more Inbox entry, **Watchman**, with its own empty-state copy key.
- **Pinned CLI JSON** (phase 1b): `watchman status --json` learning gains `relabel_pending` (rows the relabel pass has not flagged yet; the Desktop disables **Run backtest now** and shows the relabelling line while it is above 0, the daemon's weekly run waits for 0); `watchman backtest --json` gains `report_path` (the run's per-item report with the judge's reasons, a local workspace file); `watchman backtest --json` and `watchman status --json` category rows gain `handed` (`TestWatchmanBacktest_JSONKeysPinned`, `internal/watchman/testdata/status.json`); the Desktop decodes it tolerantly (missing → 0). `docs/inventory/watchman.md` gets a changelog line; WATCHMAN-03 and WATCHMAN-06 are unchanged (labels and handoff never act).
- **New module `docs/inventory/watchman.md`** with guard tests: WATCHMAN-01 the hard-limit table is never decided by the twin and the guard layers deny it while armed; WATCHMAN-02 a twin write never overwrites an owner answer (CAS); WATCHMAN-03 twin decisions become precedents only after the owner's OK; WATCHMAN-04 nothing acts while `platform.Away` says present or cannot be read (phase 2, D47: nothing acts on a session that is not armed); WATCHMAN-05 a new `workbench watchman-guard` hook is installed only through `integrate claude-code|codex` with the other hooks.

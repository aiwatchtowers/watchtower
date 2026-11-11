# Behavior Inventory — Diagnostics (Report a Problem)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when changing `watchtower diagnostics`, a line it prints,
> an input it reads, its `--json` keys, or the Desktop's Report a Problem
> sheet, read this file first. Any proposed change that would break a guard
> test or remove a contract must be raised as a question before touching
> code.

**Module:** `cmd/diagnostics.go`, `internal/diagnostics/`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/ReportProblem/`
**Last full audit:** 2026-11-11

## DIAG-01 — The diagnostics carry kinds, counts, states and error classes only

**Status:** Enforced

**Observable:** `watchtower diagnostics` (plain text, and `--json`) prints versions, the macOS version and a chip option, config and AI state as closed values, enabled feature ids, connected source kinds with counts and states, the Quick Connections count, the daemon state and the age of the last cycle, the last 20 failures as time + pipeline name (or `unknown`) + error class, crash counts with a time (or `last time unknown`) and a `watchtower/` function (or `location unknown`), log and database file sizes, the schema version and whether an organization manages the Mac. It never prints a workspace name, account, team or site name or domain, email, id, channel/space/project name, Quick Connection or automation name, path, the raw build flavor (only `default` or `corp`), the raw `ai.provider` value, model output, error text or a log line, whatever the inputs hold and whichever input fails. The `--json` object has exactly the keys `text`, `version`, `macos`, `chip`, `provider`, `sources`, `flavor` and `partial`. The Desktop sheet shows the command's `text` verbatim and adds only the user's own text.

**Test guards:**
- Guard: `cmd/diagnostics_test.go::TestDIAG01_NoNamesOrText` (canaries from `internal/logcanary` in the workspace name — `active_workspace` and `--workspace` —, `ai.provider` in the file and in `WATCHTOWER_AI_PROVIDER`, team names, domains, emails, labels and hosts, a channel name, Quick Connection and automation names, `pipeline_runs.error_msg`, account status and error text, the `last_sync.json` error, a panic message in `watchtower.log` and `BuildFlavor`; plain and `--json`, across the normal, invalid-config, unknown-workspace-flag and busy cases; no canary, no `/Users/` and no `<acct>:<id>` shape in the output), `internal/diagnostics/text_test.go::TestDiagnosticsText_Pinned` (every line text against `internal/diagnostics/testdata/text.golden`)
- Supporting: `internal/diagnostics/runner_test.go::TestReport_JSONKeys`, `cmd/diagnostics_test.go::TestDiagnostics_WritesNothing`, `TestDiagnostics_FormOptions`, `TestDiagnostics_InputFailures`, `internal/diagnostics/lines_db_test.go::TestDiagnostics_AccountTablesMapped`, `internal/diagnostics/errorclass_test.go::TestErrorClass`; Swift `ReportProblemModelTests.testReportCarriesOnlyCLITextAndUserText`, `DiagnosticsAnswerTests.testDecodesPinnedKeys`

**Why locked:** The report goes into a public GitHub issue. Watchtower holds the owner's company correspondence, and its logs and stored errors still carry account short names, ids and provider error text (FILES-01 allows that because only the owner reads them). One printed name or error message would publish it. The closed vocabulary is what lets the sheet say "no names, ids, message text or log lines" truthfully.

**Locked since:** 2026-11-11

## Changelog

- 2026-11-11: file created with DIAG-01, introduced by Report a Problem (board #1527, spec `docs/superpowers/specs/2026-11-04-report-a-problem-design.md`; owner approval in ask #1026, the `partial` key in ask #1043).

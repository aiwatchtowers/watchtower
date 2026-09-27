---
type: chore
title: "Low-priority findings bundle — PR #3 Confluence connector (Desktop, architecture, usage)"
status: open
priority: low
tags: [pr3-confluence-desktop-arch, review-2026-09-27, bundle]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Desktop, architecture, usage)
created: 2026-09-27
---

4 low-priority findings from the PR #3 Confluence connector (Desktop, architecture, usage) track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

## OCR helper verification: cache key omits ctime, and the check and the exec are two separate path lookups

- type: bug · confidence: med · tags: [security, codesign, ocr, toctou]
- where: internal/extract/ocr_verify.go:74-77,99-131,209-220, internal/extract/ocr.go:86-117

The stated threat model (ocr_verify.go header) is "a same-uid swap of the file cannot run arbitrary code under the app's TCC responsibility chain". Two gaps weaken it. (1) The verdict cache is keyed on `(ino, mtime, size)` only. A same-uid writer can overwrite the helper in place at the same size (same inode), restore the mtime with `utimes`, and get a cached `ok` without a new codesign run. ctime, which a user cannot set, is not in the key. (2) `Recognize` calls `Available` (stat, then the cached verdict) and afterwards `exec.CommandContext(h.path, …)`. That is a second path resolution, so a `rename` in between runs the swapped file. Separately, the requirement string `anchor apple generic and certificate leaf[subject.OU] = "<team>"` names no `identifier`, so any binary signed by the team passes, the main app executable included. Exploitation needs same-uid code already running, hence low priority. But the guard claims more than it delivers. Suggested direction: add `Ctimespec` to `fileKey`, add `identifier "watchtower-ocr"` to the requirement, and either exec a verified private copy or re-stat after spawn.

## Generic engine and schema built for providers that do not exist: connection_id and enabled have no writer

- type: idea · confidence: high · tags: [architecture, speculative-generality, schema]
- where: internal/db/migrations/00074_external_sources.sql:6-32, internal/db/ext_sources.go:12-71, internal/extsync/types.go, internal/extsync/engine.go:146-160

`ext_sources` carries `connection_id REFERENCES external_connections(id)`, a partial unique index for it, and an XOR CHECK against `jira_account_id`. It also has an `enabled` column that `HasRunnable` reads. No code path writes a `connection_id`, since `CreateExtSource` takes a Jira account only. Nothing ever sets `enabled = 0`: unselect deletes the row, and the Desktop toggle maps to select/unselect. `provider` is CHECK-limited to `'confluence'`. `internal/extsync` (~3.3k non-test lines across engine/stream/reconcile/attachments/comments/links) is therefore a provider-neutral framework with one implementation. It sits beside the per-integration syncer pattern (`jira.Syncer`, `gmail.Syncer`) and has its own status conventions: it writes `ok` back itself, unlike Jira, and keeps its own budget and rotation. A second provider may justify it. Until then, the unused columns and the FK into Quick Connections are dead schema that every reader and the Swift model must carry. Suggested direction: if no second provider is planned, drop `connection_id` and `enabled` in a follow-up migration. Otherwise record the planned provider in the spec so the abstraction has a named second user.

## doc_links is a second cross-source link table next to jira_slack_links, with a looser Jira-key rule

- type: idea · confidence: high · tags: [architecture, duplication, jira-keys]
- where: internal/doclinks/detect.go:39-46, internal/jirakey/jirakey.go:10, internal/db/schema.sql:943-954, internal/tools/taskcontext.go + taskcontext_confluence.go:37-57

Slack→Jira references live in `jira_slack_links`, written by `jira.KeyDetector`, which filters matches against known project keys. Confluence→Jira and Slack/mail/Jira→Confluence references live in the new `doc_links`, written by `doclinks.JiraKeys`. That function is the bare `[A-Z][A-Z0-9_]+-\d+` with no filter. So every Confluence page mentioning `UTF-8`, `ISO-27001`, `SHA-256` or `COVID-19` gets `doc_links` rows. The comment argues that is harmless because a key nobody synced is never looked up. The result is still two link graphs with different detection rules, two scanners (KeyDetector, linkscan), and `get_task_context` merging both. Suggested direction: when the Slack→Jira path is next touched, fold it into `doc_links` (`from_kind='slack'`, `to_kind='jira_issue'`), or at least apply the known-project filter in `JiraKeys` so both graphs agree on what counts as a key.

## Backlog item on token-file atomicity is partly stale; its cross-process half is now reached on every Settings → Jira open

- type: chore · confidence: high · tags: [backlog-hygiene, tokens, jira, concurrency]
- where: docs/backlog/2026-09-26-token-files-for-rotating-refresh-tokens-are-rewritten-in-place.md, internal/jira/auth.go:104-141, WatchtowerDesktop/Sources/Views/Settings/ConfluenceSpacesSection.swift:47-55, cmd/confluence.go:111-137

PR #3 changed `jira.TokenStore.Save` to temp+rename. The backlog item still cites `internal/jira/auth.go:104-114` as an in-place `os.WriteFile`, so that half is fixed for Jira and the item overstates it. The other half, the cross-process refresh race on a rotating Atlassian refresh token, got more likely. Before, the Desktop reached it through `jira boards --account` on refresh. Now every visible `ConfluenceSpacesSection` spawns `confluence spaces`, which builds its own `jira.Client` over `jira_token_<id>.json` (`openConfluenceSession`), and does so once per enabled Jira account on every appear, while the daemon's client may be refreshing the same file. A lost race is mapped to `ErrAuthRevoked`, and the engine stamps every space `revoked` while the daemon's Jira pass stamps the account itself. Suggested direction: update the backlog item (Jira atomicity done, the cross-process flock still open, the new Desktop caller listed), and consider having the Desktop read the space list from a daemon-cached listing rather than live on each open.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

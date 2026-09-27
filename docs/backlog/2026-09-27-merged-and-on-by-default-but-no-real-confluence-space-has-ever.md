---
type: question
title: "Merged and on by default, but no real Confluence space has ever been synced"
status: open
priority: high
tags: [usage, confluence, rollout, oauth, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Desktop, architecture, usage)
created: 2026-09-27
---

**Where:** docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md:570-573, internal/jira/scopes.go:17-21, internal/config/defaults.go (knowledge.connectors.enabled = true), PR #3 body checklist item "Owner: enable the Confluence API read scopes … and smoke one real space"
**Confidence:** high

The spec requires a real-data smoke before the PR. It says that smoke is "Blocked … on the owner prerequisite in §5", because the Confluence scopes are not enabled on the Atlassian OAuth app. PR #3 merged on 2026-09-27 with that checklist item still unchecked. `scopes.go` says outright that the scope→endpoint mapping "is not verified page by page; it is pending a live smoke". The PR body says the same of the `user/bulk` and comment-container response shapes: they are only verified against documentation. The feature defaults to ON and the Desktop now shows it to every Jira user (next finding). About 23k lines of connector code (engine, fetcher, extractors, OCR helper, linkscan) have run only against hand-written fixtures. Until the smoke runs, the owner cannot tell apart three states: works, silently needs_consent everywhere, or fails on a response shape. Suggested direction: have the owner run Task 13 step 2 of the plan (enable the scopes on every shipped flavor, re-consent, sync one mid-sized space) before the next release cut. Alternatively, ship the Desktop section behind a hidden flag until the smoke passes.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

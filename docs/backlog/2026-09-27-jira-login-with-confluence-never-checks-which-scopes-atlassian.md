---
type: bug
title: "jira login --with-confluence never checks which scopes Atlassian actually granted, so \"Grant access\" can loop with no explanation"
status: open
priority: med
tags: [oauth, confluence, cli, desktop, docs-drift, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Desktop, architecture, usage)
created: 2026-09-27
---

**Where:** cmd/jira.go:646-690, internal/jira/auth.go:196-200,377-382, CLAUDE.md "Confluence knowledge connector" auth bullet, WatchtowerDesktop/Sources/ViewModels/ConfluenceSpacesViewModel.swift:255-262
**Confidence:** high

The code comments and CLAUDE.md contradict each other on what happens when the OAuth app lacks the Confluence API. `auth.go` says Atlassian "rejects the wider scope set outright". CLAUDE.md says "consent silently omits the scopes and every space stays needs_consent". `runJiraLogin` does not settle the question at runtime. It calls `jira.Login(..., opts)`, stores the token, and prints "Jira Cloud connected!" without ever calling `jira.HasConfluenceScopes(token)`; the only caller of that function is the later `confluenceScopesOK`. In the silent-omission case the Desktop's `reconsentAsync` sees success and runs `load()`. The CLI then returns the same `--with-confluence` hint and the same consent block reappears. The user can click the button forever and never learn that the fix is in the Atlassian developer console. Suggested direction: when `opts.WithConfluence` is set, check the returned token after the exchange. If the scopes are missing, exit non-zero with a message naming the developer-console prerequisite, and state the observed Atlassian behaviour once in both places.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

**Update 2026-10-18 (PR #391, board #573):** partly addressed, for `jira add` only. `jira.Login` now returns `jira.ErrScopeRefused` when Atlassian redirects with `invalid_scope`. `jira add --with-confluence` retries once with the Jira scopes alone, and it prints "Jira connected; Confluence isn't enabled for this Atlassian app." whenever the returned grant fails `HasConfluenceScopes`. The connect sheet's board step reads `confluence access --json` and shows the same sentence instead of a Grant button. Still open: `jira login --with-confluence`, which is the Settings **Grant Confluence access** re-consent and can still loop; and the case where Atlassian shows its own error page without redirecting, where the flow waits for Cancel or the 5-minute timeout.

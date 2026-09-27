---
type: bug
title: "In consent mode the Desktop hides the already-selected spaces, so they cannot be seen or unselected although unselect is purely local"
status: open
priority: med
tags: [desktop, settings, confluence, ext-02, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Desktop, architecture, usage)
created: 2026-09-27
---

**Where:** WatchtowerDesktop/Sources/Views/Settings/ConfluenceSpacesSection.swift:35-40, WatchtowerDesktop/Sources/ViewModels/ConfluenceSpacesViewModel.swift:125-146,255-262, cmd/confluence.go:252-285
**Confidence:** high

`body` renders `consentContent` in place of `spacesContent` whenever `vm.needsConsent` is true. `apply(_:)` sets that flag for any CLI error containing `--with-confluence`. That covers missing scopes, the revoked-sign-in hint and "no token or site". Take an account with selected spaces whose Atlassian grant lapsed or was refreshed without the scopes. `load()` still reads that account's `ext_sources` rows, and the `merge` path is written precisely so that selected-but-unlisted spaces stay visible "so it can be unselected". But the view never shows them: no per-space status, no error text, and no Sync toggle. Yet `confluence unselect` needs no token (`resolveJiraAccountForLocalDelete`). The only way to drop the synced content from the Desktop is therefore to re-consent first, and a user who wants to stop using Confluence cannot. Spaces of a *disabled* Jira account are hidden entirely (`filter(\.enabled)`), with the same effect. Suggested direction: render the consent banner above the DB-backed list rather than instead of it, and keep unselect enabled in that state.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

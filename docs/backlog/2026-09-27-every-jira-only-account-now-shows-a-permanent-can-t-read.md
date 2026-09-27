---
type: bug
title: "Every Jira-only account now shows a permanent \"can't read Confluence\" block with a Grant button that cannot work yet"
status: open
priority: med
tags: [desktop, settings, ux, confluence, oauth, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Desktop, architecture, usage)
created: 2026-09-27
---

**Where:** WatchtowerDesktop/Sources/Views/Settings/JiraConnectionDetail.swift:141-149, WatchtowerDesktop/Sources/Views/Settings/ConfluenceSpacesSection.swift:33-60,89-111, cmd/confluence.go:111-137
**Confidence:** high

`confluenceSections` renders one `ConfluenceSpacesSection` for every enabled Jira account. Its `.task` runs `confluence spaces --account N --json` right away, and for a grant without the Confluence scopes `openConfluenceSession` returns the `--with-confluence` hint. That is every existing Jira install, because `jira add` never requests those scopes. As a result, every Jira user who opens Settings → Jira sees "Watchtower can't read Confluence on this site yet" plus a "Grant Confluence access" button. The block cannot be dismissed and has no "not now" option. While the owner prerequisite above is unmet, that button starts an OAuth consent against an app that lacks the Confluence API. The PR's own comments say Atlassian then either rejects the scope set or silently omits it (see the next finding). There is also no way to request Confluence when first connecting Jira: `AddJiraAccountView` is unchanged, so a user who wants Confluence always goes through a second consent. Suggested direction: show the section only once the user opts in (an "Add Confluence" disclosure), or collapse it to a single line for accounts without the scopes. Add a `--with-confluence` toggle to the Add Jira sheet.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

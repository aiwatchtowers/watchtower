---
type: bug
title: "Reconcile is delete-only: an item that comes back is never re-fetched until someone edits it"
status: open
priority: med
tags: [extsync, reconcile, cursor, data-loss, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Go)
created: 2026-09-27
---

**Where:** internal/extsync/reconcile.go:76-139 (reconcile/reconcileDocs), internal/extsync/stream.go:99-107 (sinceOf), internal/confluence/fetcher.go:204-225 (CQL lastmodified)
**Confidence:** med

`reconcile` compares `All` with the local ids and only deletes. It ignores refs that `All` lists but the store lacks, even though `All` already returns ids and versions. The delta streams see an item again only when its `lastmodified` falls within cursor − 24 h. Scenario: a page gets a view restriction that excludes the owner. The daily reconcile deletes it, which is correct. The restriction is lifted a week later. That does not create a page version, so `lastmodified` stays old, `Changed` never lists it again, and the page (with its comments and attachments) stays out of search until someone edits it. The same happens with restore-from-trash and, probably, with moving a page into a selected space. This is not among the accepted v1 limits. The archived-page limit (R10) is a different case. Fix direction: in reconcile, collect `remote − local` (and version mismatches) and feed them through the same batch path as a changed-ref list (`processBatch`/`processAttachmentBatch`). No extra enumeration is needed.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

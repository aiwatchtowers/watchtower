---
type: bug
title: "Comment/attachment reconcile treats a CQL search listing as proof of deletion, with no sanity guard"
status: open
priority: med
tags: [extsync, confluence, reconcile, cql, data-loss, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Go)
created: 2026-09-27
---

**Where:** internal/confluence/fetcher.go:118-123 (All → searchRefs for comment/attachment), internal/extsync/reconcile.go:106-122, 141-173, 220-238
**Confidence:** low

For pages, `All` uses the v2 space listing, keyed by space **id** and backed by the database. For comments and attachments it uses CQL `space = "<KEY>" AND type = …`, which comes from Confluence's search **index**. That index is eventually consistent and addressed by space **key**. Reconcile deletes every stored row missing from that listing. It checks neither "remote came back empty while local has N" nor a large drop ratio. Failure scenarios: (a) the site's search index is rebuilding or lagging and CQL returns a partial 200 → partial deletion; (b) the space key is changed (Confluence Cloud allows this) while `ext_sources.container_key` is never refreshed → CQL on the old key returns nothing or errors. If it returns nothing, every attachment and comment is deleted while the pages (listed by id) survive. With the delete-only reconcile above, those rows do not come back until each one is modified. Confidence is low because the exact CQL behaviour for a renamed key or a degraded index is not verified live. Fix direction: skip the delete step (and log it) when a kind's remote set is empty or shrinks by more than about 50% against local. Also refresh `container_key` from `Containers()`/space id before building CQL.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

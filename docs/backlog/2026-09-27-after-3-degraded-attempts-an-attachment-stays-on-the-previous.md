---
type: bug
title: "After 3 degraded attempts an attachment stays on the previous version's text forever (partial new text is discarded)"
status: done
priority: med
tags: [extsync, attachments, ocr, version-gate, stale-content, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Go)
created: 2026-09-27
---

**Where:** internal/extsync/attachments.go:176-198 (writeAttachmentItems), internal/extsync/pending.go:26-41, 81-91, internal/extsync/attachments.go:397-406 (revisitRefs `extract_attempts < 3`)
**Confidence:** high

When a stored attachment gets a new version V2 and the outcome is degraded (`ocr_pending` or a transient failure), the design keeps V1's text and marks V2 as `pending_version`. Once `extract_attempts` reaches 3, `revisitRefs` stops selecting the row. The delta gate also treats V2 as not stale because it equals the pending version, so nothing ever moves the row to V2. Concrete case: V2 of a PDF has a full text layer plus one scan page that the Swift helper cannot render (`OCRError.renderFailed` exits 2). That makes the batch fail deterministically, so every try ends `ocr_pending`. `pdfText` returned all of V2's text-layer pages and the other OCR batches, but `writeAttachmentItems` skips the write because the row already exists. Search keeps serving V1's obsolete text, and the owner can't tell. Fix direction: on the attempt that exhausts the budget, write the degraded result when it has sections (`ocr_pending` with partial text), or at least drop the stale V1 text. Keep "last good text" only while retries remain.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

Fixed in fix/extsync-reconcile-attachments: the revisit that spends the last attempt on a new version now writes that version with its partial text (ocr_pending) or none (failure) instead of keeping the obsolete text; a degraded try of the stored version still keeps its text (`writeAttachmentItems`/`storedAttempt.lastTry`, `TestOCRPendingExhaustedNewVersionStoresPartialText`, `TestDegradedLastTryOfStoredVersionKeepsText`).

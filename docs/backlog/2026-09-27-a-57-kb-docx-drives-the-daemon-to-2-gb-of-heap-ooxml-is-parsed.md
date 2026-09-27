---
type: bug
title: "A 57 KB .docx drives the daemon to ~2 GB of heap (OOXML is parsed in process, with no XML depth cap)"
status: done
priority: high
tags: [extract, ooxml, dos, memory, untrusted-input, daemon, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Go)
created: 2026-09-27
---

**Where:** internal/extract/ooxml.go:72-96 (walk), internal/extract/ooxml.go:17-22 (budget), internal/extract/extract.go:132-135, internal/extsync/attachments.go:230-253 (fetchConcurrency 4)
**Confidence:** high

The zip-bomb guard caps uncompressed *bytes* (100 MiB) and opened entries (1000), but not XML nesting. `encoding/xml`'s `Decoder.Token()` keeps one stack entry per open element and has no depth limit. Reproduced: a docx whose `word/document.xml` holds 20M × `<a>` compresses to **57 KB**, stays under the byte budget, and `ooxmlText` peaks at **2,058 MB HeapInuse, 3.6 GB total alloc, 8.5 s** before it returns `failed`. Unlike PDFs, OOXML runs inside the daemon process, not a killable helper. `extractAll` runs 4 attachments at once, so four such files cost about 8 GB on a 16 GB Mac. Anyone who can upload to a selected space can trigger this, and it can recur on each retry or new version. Fix direction: count depth in `walk` and fail over about 256 levels (docx needs about 10). Also cap tokens/elements, or move OOXML into the same helper-process sandbox as PDF. Test gap: `fuzz_test.go` fuzzes PDF only; nothing fuzzes or depth-tests OOXML. (Lower confidence, same class: the PDF helper's memory is not capped either. A deflate-bombed content stream of `Tj` text keeps accumulating in `GetPlainText` until the 60 s kill. CLAUDE.md records "uncapped memory" as a limit for the OCR helper only.)

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

Fixed in fix/backlog-ooxml-depth: every OOXML part walk now fails a document nested deeper than 256 elements as `failed` and one whose single XML token needs more than 256 KiB of input as `too_large` (a 2M-level docx now allocates under 1 MiB instead of ~500 MiB); walks read raw tokens (`RawToken`) so open elements' `xmlns:*` declarations are not retained (256 levels of ~85 KiB of declarations held ~160 MiB live before); the Confluence storage parser was already bounded by x/net/html's 512-element stack and now has a resource pin test. The PDF-helper memory note in this finding is not addressed here.

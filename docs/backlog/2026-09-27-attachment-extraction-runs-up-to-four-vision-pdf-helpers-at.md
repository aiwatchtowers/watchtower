---
type: chore
title: "Attachment extraction runs up to four Vision/PDF helpers at once inside the serial daemon cycle, and the 90 s budget does not bound it"
status: done
priority: med
tags: [cost, ocr, daemon, performance, 16gb, review-2026-09-27]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Desktop, architecture, usage)
created: 2026-09-27
---

**Where:** internal/extsync/stream.go:21, internal/extsync/attachments.go:50,226-253,287-290, internal/extract/ocr.go:117, cmd/sync.go (extSyncCycleBudget = 90s), internal/daemon/daemon.go:405-408, WatchtowerDesktop/Sources/App/AppState.swift:800
**Confidence:** med

`extractAll` fans out with `g.SetLimit(fetchConcurrency)`, where `fetchConcurrency` is 4. The budget is checked only before launching an item, and each launched item may run for up to `extractDeadline` (8 minutes: a 60 s PDF parse plus up to five 60 s OCR batches). So during a scan-heavy backfill, one `phaseExternalSync` can hold four `watchtower-ocr` processes. Each runs `.accurate` recognition with three languages at up to 4096 px, the helper's memory is uncapped (a documented limit, but not the ×4), and all four start at default QoS with no `nice` or background priority. That can go on for up to ~8 minutes past the 90 s budget. `runSync` is serial, so every later phase (digests, inbox, memory, briefing) waits behind it on every cycle until the backfill finishes. The docs describe overshoot as "one attachment"; the real bound is four concurrent attachments. Nothing gates on battery or user idleness either. A smaller point: every Sync toggle also fires `DaemonManager.syncNow()`, a full out-of-schedule `runSync` including the AI phases, just to start one space. Suggested direction: run extraction with concurrency 1 (download fetches can stay at 4), launch the helpers at background QoS (`taskpolicy -b` or `setpriority`), and consider a Confluence-only trigger for the post-select nudge.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

Fixed in fix/extsync-reconcile-attachments: attachments are now downloaded and extracted one at a time (`extractAll`; metadata fetches stay 4-wide), so a cycle overshoots its budget by at most one attachment, and the PDF and OCR helpers run at nice 10 (`internal/extract/helperexec.go`; not the macOS background band, which also throttles I/O and starved test helpers past their timeouts under load). Not done: a Confluence-only trigger for the Desktop's post-select sync nudge (`DaemonManager.syncNow()` still runs a full cycle) — a Swift change left for a Desktop lane.

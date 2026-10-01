---
type: chore
title: "Confluence GetJSON reads an unbounded success body"
status: done
priority: low
tags: [confluence, memory, hardening, review-2026-09-27]
context: noticed while fixing the OOXML depth bomb (fix/backlog-wave2)
created: 2026-09-27
---

**Where:** internal/jira/confluence_api.go (GetJSON)
**Confidence:** med

The Confluence client decodes the whole success response with no size cap. It is linear memory, not a
depth blow-up, and the server is Atlassian, but a page body or a proxy error page can be large. Wrap the
body in an io.LimitReader sized to the largest legitimate response (storage bodies are the big ones) and
fail loudly above it. The PDF helper's own memory is also uncapped (side note of the OOXML finding);
consider an RLIMIT/ulimit or a page-count bound there too.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

Resolution: `GetJSON` now reads its 2xx body through `io.LimitReader(resp.Body,
maxSuccessBodyBytes+1)` (16 MiB — comfortable headroom over the Confluence fetcher's own 1M-rune
page-body cap) and fails with `ErrTooLarge` — the same sentinel `Download` already uses — when the
read comes back over the cap, instead of handing an unbounded reader to `json.Decode`. Pinned by
`TestConfluenceGetJSON_SuccessBodyCap` (over the cap fails) and
`TestConfluenceGetJSON_ExactlyAtCapSucceeds` (the boundary still decodes). The PDF-helper memory
note is out of scope here (internal/extract, not internal/jira) and is left open.

---
type: chore
title: "Confluence GetJSON reads an unbounded success body"
status: open
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

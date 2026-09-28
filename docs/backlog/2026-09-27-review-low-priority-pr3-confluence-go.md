---
type: chore
title: "Low-priority findings bundle — PR #3 Confluence connector (Go)"
status: open
priority: low
tags: [pr3-confluence-go, review-2026-09-27, bundle]
context: post-merge review of PR #3 (Confluence connector) at 9687fc3f — track PR #3 Confluence connector (Go)
created: 2026-09-27
---

6 low-priority findings from the PR #3 Confluence connector (Go) track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

## HTML attachments that omit </head> (valid HTML5) index as empty text with status ok (fixed in fix/bl-confluence-content)

- type: bug · confidence: high · tags: [extract, html, content-loss]
- where: internal/extract/plain.go:65-66, 114-124 (skippedElements / tag)

`stripHTML` runs the raw tokenizer, not the tree builder, and counts `skip` depth on start and end tags of `head`/`script`/`style`/`noscript`/`template`. An implied end tag never arrives. Reproduced: `<html><head><title>T</title><body><p>Hello body</p></body></html>` → `""`. With an explicit `</head>` the same document gives "Hello body". The status is `ok`, so the attachment is never retried and only its file name is searchable. Fix direction: drop `head` from the depth-counted set, or close it at `<body>`. Alternatively render with `html.Parse` (the tree builder handles implied tags), as `internal/confluence` already does.

Resolution: `head` is tracked separately from the `skippedElements` depth
counter via `htmlStripper.inHead`, closed explicitly by `</head>` and
implicitly by a `<body>` start tag (HTML5 §13.2.6.4.6). Pinned by
`TestHTMLMissingHeadClose` (`internal/extract/extract_test.go`), asserting
the explicit- and implicit-close documents render identically. **Round 2
generalization:** `<body>` is only the common case of HTML5's "in head"
insertion mode's "anything else" rule — ANY opening tag not allowed inside
`<head>` (`headAllowedTags`: title/meta/link/style/script/base/noscript/
template) closes it, even with no `<body>` tag at all (e.g.
`<html><head><title>T</title><p>Hello`). Pinned by
`TestHTMLHeadClosedByOrdinaryTag`.

## Storage XHTML nested deeper than 512 elements silently indexes as an empty page (fixed in fix/bl-confluence-content)

- type: bug · confidence: high · tags: [confluence, storage, parser, silent-failure]
- where: internal/confluence/storage.go (StorageToSections, "in practice this never returns a non-nil error"), golang.org/x/net/html parser (open-element stack cap 512)

`golang.org/x/net/html` returns an error once the stack of open elements passes 512. `StorageToSections` then returns `nil, nil, nil` with no log line, and its own comment says this "never" happens. Reproduced: 511 nested `<div>` → 1 section; 512 → 0 sections. The page is stored with `sections_json = []` (title only, no Jira keys, no mentions), and nothing records why. Hand-written storage format rarely gets that deep. It can happen with generated or imported pages, or with non-`ac:` self-closing tags the HTML5 parser leaves open (see the next finding). Fix direction: log the parse error through the fetcher, then fall back to a tokenizer-only text strip (or record a status) instead of an empty body.

Resolution: `StorageToSections` gained a fourth return value, `parseErr`,
and now falls back to `fallbackText` (a linear, tag-blind tokenizer strip —
no tree, no open-element stack, so the resource bound `storage_depth_test.go`
already pinned still holds) instead of an empty body when `parseFragment`
fails. Both call sites (`Fetcher.pageItem`, `Fetcher.commentItem`) log the
fallback through the fetcher's new `SetLogger` seam (wired in both
`cmd/sync.go`'s `wireExternalSync` — the daemon path — and, since round 2,
`cmd/confluence.go`'s `runConfluenceSync` — the foreground `confluence sync`
path — the `jira.Client.SetLogger` precedent). Pinned by the extended
`TestStorageDeepNestingIsBounded`, which now also asserts a non-nil
`parseErr` and that the fallback section still carries the body's text, and
by `TestExternalSyncWiring_SetsFetcherLogger`/`TestConfluenceSync_SetsFetcherLogger`
(`cmd/confluence_test.go`) for the two wiring points. **Round 2 addition:**
the fallback also runs the plain-text Jira key scan
(`jira.KeyRegexp`/`converter.scanJiraKeys`) over the fallback text, so
`doc_links` still picks up a page's plain-text Jira mentions even on this
path (`userIDs` stays nil — a mention token only ever comes from an
`ac:link`/`ri:user` element the fallback never parses). Pinned by
`TestStorageFallbackScansJiraKeys`.

## Storage converter drops date lozenges and status macro labels (fixed in fix/bl-confluence-content)

- type: bug · confidence: med · tags: [confluence, storage, content-loss, search]
- where: internal/confluence/storage.go (inlineElement default → inlineChildren; renderMacro default → renderMacroBody), internal/confluence/storage.go (normalizeSelfClosing only rewrites names containing ':')

Confluence stores a date as `<time datetime="2026-09-01" />`. Reproduced: `<p>Due <time datetime="2026-09-01" /> ship it</p>` → "Due ship it", with the date gone. `time` has no children, and its `datetime` attribute is never read. The self-closing form isn't normalized either, because the name has no ':'. The `status` macro (`ac:parameter ac:name="title"`) has no body, so `renderMacroBody` returns "" and labels like "DONE"/"BLOCKED" vanish (confidence med, from code reading). Search for a due date or a status therefore misses these pages. Fix direction: render `time` as its `datetime` value, and render the status macro's `title` parameter (plus other body-less macros with a title-like parameter).

Resolution: `normalizeSelfClosing` now also rewrites `<time .../>` into an
explicit start+end pair (added `alwaysSelfClosingByName`, since `time` has
no ':' to key on), so it no longer swallows the rest of its surrounding
phrase as children; a new `renderTime` (wired into both `renderBlock` and
`inlineElement`) renders its `datetime` attribute. `renderMacroBody` falls
back to a body-less macro's `ac:parameter[ac:name="title"]` value
(`macroTitleParameter`) when it has neither `ac:rich-text-body` nor
`ac:plain-text-body` — covers `status` and any other title-only macro.
Pinned by `TestStorageDateLozenge`/`TestStorageStatusMacroLabel`
(`internal/confluence/storage_test.go`) and extended into the
`macros.xhtml`/`macros.golden.json` fixture pair.

## A "scope does not match" 401 rotates the Atlassian refresh token three times before it surfaces (fixed in fix/bl-jira-hardening)

- type: bug · confidence: high · tags: [jira, oauth, confluence, tokens]
- where: internal/jira/client.go:117-176 (doURLWith 401 loop), internal/jira/client.go:180-195 (persistentUnauthorized)

The PR's own comment says Atlassian answers a request the grant lacks a scope for with 401 "Unauthorized; scope does not match". `doURLWith` still treats every 401 on attempts 0–2 as a stale access token. It calls `refreshIfCurrent`, which really refreshes (the stored token equals the one just used), so three refresh-token rotations and three token-file rewrites happen before `persistentUnauthorized` finally classifies the body as a scope error. This can recur every cycle while an endpoint needs a scope missing from `ConfluenceScopes` (the scopes.go comment says the endpoint→scope mapping is "not verified page by page"). Each extra rotation widens the known cross-process refresh race and the non-atomic token write (backlog: token-files-for-rotating-refresh-tokens…). Fix direction: read the 401 body on the first response and return right away when it names a scope, without refreshing.

Resolution: `persistentUnauthorized` is replaced by `classify401`, called on every 401 (not only the
last retry) — a body naming a scope now returns immediately as a plain `*HTTPStatusError`, with no
`refreshIfCurrent` call and so no refresh-token rotation. Non-scope 401s keep the existing
refresh-then-retry behavior, now on their own independent budget (see the go-bugs-infra bundle's
401/429 counter-split entry, fixed by the same change). Pinned by
`TestClient_PersistentUnauthorizedScopeIsNotRevoked`, updated to assert exactly one server call
instead of the four the old behavior required.

## Non-UTF-8 text attachments (UTF-16 or cp1251 CSV/TXT) are recorded as final failed (fixed in fix/bl-confluence-content)

- type: bug · confidence: med · tags: [extract, encoding, content-loss, localization]
- where: internal/extract/plain.go:21-35 (readUTF8)

`readUTF8` strips only a UTF-8 BOM and marks anything else that fails `utf8.Valid` as `StatusFailed`, which is final and never retried. Windows "Unicode" text (UTF-16LE with a `FF FE` BOM) and CSV saved by Excel in a Russian or Ukrainian locale (cp1251) are common in the owner's ru/uk environment, and their contents never become searchable. Fix direction: decode UTF-16 by its BOM, and try `golang.org/x/text` windows-1251 as a fallback when the UTF-8 check fails and the bytes decode cleanly.

Resolution: `readUTF8` now decodes a UTF-16LE/BE BOM via
`golang.org/x/text/encoding/unicode` (already an indirect dependency,
promoted to direct by `go mod tidy` — no new module, no version change), and,
failing that, tries `golang.org/x/text/encoding/charmap.Windows1251` when
the UTF-8 check fails. **Round 2 correction:** `decodeCleanly`'s
"no `utf8.RuneError`" check alone is *not* a reliable signal — cp1251 has
only one undefined byte (0x98) in its whole 256-value table, so it "decodes
cleanly" for almost any 8-bit byte stream, including cp1252/ISO-8859-2/
KOI8-R/GBK mojibake. A windows-1251 decode is now additionally gated on
`looksLikeCyrillicPlainText` (Cyrillic ≥ ~50% of all letters, no word mixing
Latin+Cyrillic, no mid-word Cyrillic case flip, uppercase Cyrillic not
outnumbering lowercase) before it's trusted as real Russian/Ukrainian text;
for HTML the gate runs on the markup-stripped text, not the raw
markup+content, since tag names are themselves Latin letters and would
dilute the ratio. `TestPlainInvalidUTF8Fails`'s fixture changed — its old 3
bytes happen to be valid cp1251 ("aяю"), exactly the content this fix
recovers — to one still undecodable under every supported path (cp1251's one
genuinely undefined byte, 0x98). Tests:
`TestPlainUTF16BOMDecodes`/`TestPlainWindows1251Decodes`
(`internal/extract/extract_test.go`);
`TestPlainNonCyrillicMojibakeFails`/`TestPlainCyrillicCSVWithLatinHeadersDecodes`
(`internal/extract/encoding_test.go`) pin the plausibility gate against
cp1252/GBK/KOI8-R mojibake and a real mostly-Russian CSV with Latin headers.

**Round 2 addition — HTML charset declarations honored first:** `htmlText`
now honors a charset the document declares itself — the MIME Content-Type's
charset param or a byte-order mark (both "certain" per
`golang.org/x/net/html/charset.DetermineEncoding`), or an HTML
`<meta charset>`/http-equiv Content-Type tag (`scanMetaCharset`, since
`DetermineEncoding`'s own meta detection is, through its public API,
indistinguishable from its final windows-1252-by-default guess) —
unconditionally, before any guess. An HTML document with no declaration
anywhere still falls through to the same UTF-8/windows-1251-plausibility
path as plain text, never `DetermineEncoding`'s own windows-1252 default
(which would reintroduce exactly the mojibake risk this fix guards against).
Tests: `TestHTMLHonorsDeclaredMIMECharset`/`TestHTMLHonorsMetaCharset`/
`TestHTMLHonorsHTTPEquivMetaCharset`/`TestHTMLUndeclaredFallsBackToPlausibilityGate`/
`TestHTMLUndeclaredMojibakeStillFails` (`internal/extract/encoding_test.go`).

## linkscan freezes a Slack message's from_ref at first sighting, so a root later promoted to a thread keeps its channel-day ref

- type: bug · confidence: med · tags: [doclinks, linkscan, slack, cursor]
- where: internal/doclinks/linkscan/scan.go:56-60, 285-310 (readSlack via kb.SlackDocRef), internal/kb/source_slack.go (slackKeyFor)

`readSlack` builds `from_ref` from the row's current `thread_ts` and walks messages by a forward-only rowid cursor. A top-level message that gets its first reply later has `thread_ts` set by the sync upsert, with the same rowid, and moves from its channel-day document to a thread document ("promoted root", per CLAUDE.md). Its Confluence link keeps pointing at the day document, which no longer contains the message, and a reply that repeats the URL adds a second ref. "Discussed in: N Slack threads" (`kb/source_ext_links.go`) then over-counts, and the link names a document without the URL. This is related to, but not the same as, the accepted "edits are not rescanned" limit. Fix direction: when a row's `thread_ts` changes, re-point that message's `doc_links` rows (or derive `from_ref` at read time from the message's ts).

Investigated (not fixed — needs a design decision, not a mechanical patch):
confirmed both fix directions require a `doc_links` schema/migration change,
not just a cursor tweak. `doc_links`' PRIMARY KEY is `(from_kind, from_ref,
to_kind, to_ref)` (`internal/db/schema.sql`) with no per-message identity
column — `from_ref` for a Slack row is *already* an aggregate (a whole
channel-day or a whole thread), deliberately, so the KB can stamp/reconcile
it as one document. A day-ref can legitimately aggregate several unrelated
top-level messages' links, so "re-point on promotion" cannot correctly
resolve to a `DELETE ... WHERE from_ref = <the stale day ref>` without also
risking deleting a sibling message's still-valid link from that same day —
there is currently no column to tell which day-ref row came from which
message. Both fix directions in the finding (re-point on promotion, or
derive `from_ref` at read time) therefore need a new per-message identity
column on `doc_links` (e.g. `channel_id`+`ts`) plus a migration, a rewrite
of the write path (`linkscan.link`, the generic reconcile in
`internal/doclinks/detect.go`, which also keys deletes on `from_ref`), and
of the one current reader (`discussedIn` in `internal/kb/source_ext_links.go`,
whose `COUNT(DISTINCT from_ref)` would need to re-derive or re-group by the
new column) — out of scope for a mechanical parser/converter fix. Left open
for an owner design call; not attempted here.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

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

**Triage 2026-10-02 (checked against main e0f7fec6):** items 1–4 are in main
(`fix/bl-confluence-content` → PR #23, dbd59d84; `fix/bl-jira-hardening` →
PR #15, a1d11196) with their pinning tests present. Item 5 is fixed except the
withdrawn undeclared-charset guess, and item 6 needs a `doc_links` schema
design — both wait on an owner design call, so the bundle stays open for those
two only. Nothing mechanical is left here.

## HTML attachments that omit </head> (valid HTML5) index as empty text with status ok (fixed — PR #23, dbd59d84)

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

## Storage XHTML nested deeper than 512 elements silently indexes as an empty page (fixed — PR #23, dbd59d84)

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

## Storage converter drops date lozenges and status macro labels (fixed — PR #23, dbd59d84)

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

## A "scope does not match" 401 rotates the Atlassian refresh token three times before it surfaces (fixed — PR #15, a1d11196)

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

## Non-UTF-8 text attachments (UTF-16 or cp1251 CSV/TXT) are recorded as final failed (partially fixed — PR #23, dbd59d84; the undeclared-charset guess is left for an owner design call, see below)

- type: bug · confidence: med · tags: [extract, encoding, content-loss, localization]
- where: internal/extract/plain.go (readUTF8, decodeDirect, htmlText)

`readUTF8` strips only a UTF-8 BOM and marks anything else that fails `utf8.Valid` as `StatusFailed`, which is final and never retried. Windows "Unicode" text (UTF-16LE with a `FF FE` BOM) and CSV saved by Excel in a Russian or Ukrainian locale (cp1251) are common in the owner's ru/uk environment, and their contents never become searchable. Original fix direction: decode UTF-16 by its BOM, and try `golang.org/x/text` windows-1251 as a fallback when the UTF-8 check fails and the bytes decode cleanly.

**Fixed and kept:** UTF-16 BOM decoding (`decodeByBOM`/`decodeDirect`), declared-charset handling for HTML (MIME `charset=`/`<meta charset>`/http-equiv, the HTML5 meta-declared-UTF-16→UTF-8 carve-out, the U+FFFD-share wrong-declaration check), BOM trimming ahead of any decode attempt, and the `<head>`-closing fixes (text-closes-head, void elements not blocking it). Tests: `TestPlainUTF16BOMDecodes`, `TestHTMLHonorsDeclaredMIMECharset`/`HonorsMetaCharset`/`HonorsHTTPEquivMetaCharset`, `TestHTMLMetaUTF16LabelIsTreatedAsUTF8`/`DoesNotOverrideARealBOM`, `TestHTMLDeclaredUTF8OverInvalidBytesFails`/`RecoversValidUTF8`, `TestHTMLDeclaredReplacementEncodingOverMojibakeFails`, `TestHTMLUnknownMetaLabelRecoversValidUTF8`/`OverNonUTF8Fails`, `TestHTMLHeadClosedByTextWithNoTag`/`TitleTextIsNotHeadContent`/`ByTextDespiteVoidElements` (all `internal/extract/encoding_test.go`).

**Withdrawn: the undeclared cp1251/KOI8 single-byte-charset guess.** This sub-item stays OPEN — no undeclared, BOM-less, non-UTF-8 plain-text or HTML attachment is decoded by guessing a legacy Cyrillic charset. `readUTF8`/`htmlText` return `StatusFailed` for such input, exactly as on `main` before this PR's encoding-detection work began. A declared-utf-8 HTML document whose decode trips the U+FFFD check also now falls straight to `StatusFailed` (or recovers via `decodeDirect` if the real bytes happen to be valid UTF-8 after all) — never to a guess.

Three approaches were tried across rounds 2–4 and each regressed on some class of real-world input — the common failure is that every workable *signal* (case pattern, word-level anomaly rate, letter frequency) picks out SOME real documents as garbage or SOME garbage as real, because the family of confusable single-byte/legacy encodings is large and their outputs genuinely overlap statistically:

1. **Round 2 — zero-tolerance rules** (Cyrillic-letter ratio, no word mixing Latin+Cyrillic, no mid-word case flip, uppercase not dominating lowercase): rejected a whole real document for a single camelCase brand name (`ПриватБанк`), a single keyboard-layout typo, or any all-caps content (a legacy 1C/accounting export — a real, common cp1251 source).
2. **Round 3 — the same rules turned into proportions** (a share-of-words floor instead of zero tolerance; uppercase-dominance removed as mathematically unfixable — real all-caps prose and all-caps mojibake are letter-case-identical): fixed round 2's false rejections, but itself rejected realistic, lowercase-heavy KOI8-R/KOI8-U prose, because ordinary sentence capitalization is too sparse in a real paragraph to clear a 10%-of-words floor. Case-based rules oscillate between too strict and too loose because letter case is not actually the signal that distinguishes a correct decode from a wrong one for this encoding family.
3. **Round 4 — letter-frequency scoring** (decode as windows-1251/koi8-r/koi8-u, score each by Cyrillic ratio + share of ~10 common ru/uk letters, accept the highest scorer past a floor and margin): fixed the round 3 regression (KOI8 prose now scored and decoded correctly), but an independent verify pass with a much broader probe corpus (business prose in RU/UK/BG/SR/DE/FR/PL/CS/EL/TR/HE/AR/ZH/JA/KO, plus sliding-window sweeps) found it still wrong on three fronts, at least one a real regression from `main`:
   - an almost-entirely-valid UTF-8 Russian/Ukrainian file carrying a single stray non-UTF-8 byte (a concatenated cp1251 line, a stray NBSP, a file cut mid-rune) was indexed as full-document mojibake — a genuine regression, since `main` failed such files outright;
   - Ukrainian KOI8-U text heavy in є/ї/ґ (not top-10 letters) was sometimes decoded as KOI8-R instead, turning those letters into box-drawing characters;
   - Greek (cp1253/ISO-8859-7) and Hebrew (cp1255/ISO-8859-8) prose, and short (under ~100 char) GBK/EUC-JP/EUC-KR fragments, scored high enough via the KOI8 candidate to be indexed as garbage — KOI8 and these charsets share enough of a phonetic/frequency shape that the score can't always tell them apart, especially for short text.

**Suggested direction for a future attempt (not implemented here):** only attempt an undeclared guess when (a) the MIME type and the document itself declare no charset at all — never as a fallback that overrides a declaration or a mostly-valid decode — AND (b) a proper statistical detector trained/validated on a large real corpus per candidate charset (e.g. a byte- or trigram-frequency language model per encoding, not a hand-picked top-letter list) agrees, with a sample-size floor before it is trusted at all (the round 4 sweep showed short samples of *every* family are unreliable, not just Cyrillic). A cheaper alternative that sidesteps statistical detection entirely: let the owner configure an explicit per-space (or per-account) fallback charset for attachments with no declaration, since a given Confluence space/mail account typically has one consistent legacy charset in practice, if any.

Tests restored/added this round: `TestPlainInvalidUTF8Fails` reverted to its pre-detection-work fixture and intent; `TestPlainWindows1251WithoutDeclarationFails` (was `TestPlainWindows1251Decodes`) now asserts `StatusFailed`; `TestPlainMojibakeFamiliesFail` folds in koi8-r/koi8-u/windows-1251 alongside the other rejected families (undeclared Cyrillic content fails just like everything else now); `TestPlainUTF8WithOneStrayByteFails` pins the specific regression that triggered the withdrawal; `TestHTMLDeclaredUTF8OverInvalidBytesFails` (was `...FallsThrough`) now asserts failure instead of guess-recovery; `TestHTMLUnknownMetaLabelRecoversValidUTF8`/`OverNonUTF8Fails` and `TestHTMLUndeclaredNonUTF8Fails` split the old guess-recovery tests into their new fail/recover-via-decodeDirect halves. All of `looksLikeCyrillicPlainText`, `isWordAnomalyMeaningful`, `bestCyrillicText`, `scoreCyrillicText`, `scoreCandidate`, `cyrillicCandidate` and their constants are deleted; `decodeCleanly` stays (used only by the UTF-16-BOM path now).

## linkscan freezes a Slack message's from_ref at first sighting, so a root later promoted to a thread keeps its channel-day ref (left — needs an owner design call)

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

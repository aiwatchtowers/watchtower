# Confluence page editing from the chat — design

Date: 2026-09-30. Status: approved in conversation (owner: "A", then the full design, then "go, review, merge when green").
Builds on: `docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md` (read-only sync, EXT-01..04) and the agent-actions registry (`internal/tools`, AGENT-01..06).

## 1. Goal

From the Watchtower chat the owner works on a Confluence page with the assistant.
The assistant reads the page **live**, including all its comments. It then
proposes precise edits, either a fragment replacement or a whole-section
replacement. The owner sees a word-level diff of only the touched region and
approves it. The edit is applied only if the page has not changed since the
preview.

Owner decisions:
- Comments are **input** only. The assistant reads them but never replies to or resolves them.
- The edit unit is **both**. The assistant picks `replace_text` for small edits and `replace_section` for rewrites.
- The approach is **native registry tools** with **markers** for rich elements.

### Non-goals

- Replying to, resolving or creating comments.
- Creating new pages. Editing attachments. Moving or renaming pages.
- Edits triggered from Confluence itself, such as `@watchtower` comments.
- Editing through the sync engine or `ext_*`. The sync stays read-only; EXT-01 is unchanged.

## 2. Auth

- Write scopes are **opt-in**: `write:page:confluence write:blogpost:confluence`
  (constant `ConfluenceWriteScopes` in `internal/jira/scopes.go`). They are
  requested only by `jira login|add --with-confluence-write`, which implies
  `--with-confluence`. The rule that a plain re-login keeps already-granted
  scopes extends to the write scopes: re-login requests them when the stored
  token already has them.
- `HasConfluenceWriteScopes(tok)` mirrors `HasConfluenceScopes`.
- Without write scopes, `edit_confluence_page`'s Validate returns a
  `*ValidationError` telling the model to ask the owner to allow editing:
  `Confluence editing not granted — run: watchtower jira login --account N --with-confluence-write`.
  In the Desktop, the Confluence section of the Jira account gains an **Allow
  editing** button, shown when the read scopes are present and the write scopes
  are not. It runs the re-login with the flag.
- All writes go through the account's `*jira.Client` via a new
  `ConfluenceAPI.PutJSON` (method PUT only). It uses the shared single-flight
  refresh, the 401/429 handling and the `HTTPStatusError`.
- **EXT-01 is narrowed, not weakened.** The *sync engine and fetcher* stay
  GET-only. The EXT-01 guard's method pin for `ConfluenceAPI` becomes
  `{Download, GetJSON, PutJSON}`. A new guard asserts the extsync engine and
  `confluence.Fetcher` can never reach `PutJSON`: they depend only on the
  GET-only `confluence.API` interface. EXT-01's inventory text is updated to
  say so. `PutJSON` is reachable only from `internal/confluenceedit`, the
  package used by the edit tool.
- **New contract EXT-05 — Confluence writes are approved, versioned and
  bounded.**
  - The only write path is `edit_confluence_page`, which is `External`, so it
    runs only after Approve (AGENT-03).
  - Every write carries the base version the owner saw. It is applied only if
    the live version still equals it, as `PUT` with version+1.
  - A rich element is removed only if it appears in the approved diff's
    removal list.
  - Guards:
    - `TestEXT05_WriteRequiresMatchingVersion`: a live-version mismatch at apply time means no PUT.
    - `TestEXT05_RichElementsSurviveUntouched`: a no-op edit round-trips the storage byte for byte.
    - `TestEXT05_OnlyEditToolReachesPut`: a `go list -deps` / import guard.

## 3. The editable text model (`internal/confluenceedit`)

This is a pure package: no DB, no network. It converts between storage XHTML
and an **editable text** view, and it applies edits.

- `Parse(storageXHTML) (*Doc, error)` builds a block model. It reuses
  `internal/confluence`'s normalisation for self-closing `ac:`/`ri:` tags and
  CDATA escaping, so the rules for real storage input are shared.
- **Blocks:** heading (h1–h6), paragraph, list (nested), table, code/noformat
  macro, and "opaque" blocks.
- **Inline:** text, bold/italic/strike/code, links (`a href`, `ac:link` to a
  page), line breaks.
- Anything else becomes a **marker**. This covers user mentions, Jira macros,
  images, attachments, emoticons, status macros, and any other `ac:*`
  element or unknown macro, inline or block. Each marker keeps its exact
  original XHTML bytes.
- `Doc.Text()` renders the editable text: markdown for the supported
  formatting, and markers as `⟦k:label⟧`. Here `k` is a stable per-page ordinal
  and `label` is a human hint, for example `⟦3:jira PROJ-123⟧`, `⟦5:@Ann Lee⟧`,
  `⟦7:image diagram.png⟧`, `⟦9:macro toc⟧`. Headings render as `#`..`######`.
  A table renders as a markdown pipe table only when every cell is plain
  inline content; otherwise the whole table is one opaque block marker.
- **Round-trip law:** `Render(Parse(x))` equals the canonicalised `x`. This
  holds by construction: an untouched block re-emits its original bytes. Only
  blocks that an edit touches are re-serialised from their new text.
- **Edits:**
  - `replace_text {old, new}`
    - `old` is matched against `Doc.Text()` after whitespace normalisation.
      It must occur **exactly once**, and it must lie within **one block**
      (a paragraph, list item, table cell, heading or code block). Otherwise
      the edit fails with a message saying why: not found, ambiguous, or spans
      blocks.
    - The block's text is rewritten, and the block alone is re-serialised from
      the new text via a markdown-inline → XHTML converter.
    - Markers present in the new text are restored to their original bytes.
  - `replace_section {heading, new_body}`
    - `heading` is matched against heading text (exactly one heading must
      match). The section runs from that heading to the next heading of the
      same or higher level.
    - `new_body` is markdown (paragraphs, lists, pipe tables, fenced code,
      markers). It replaces the section's body; the heading itself is kept.
    - Converted blocks are emitted as storage XHTML: `p`, `ul/ol/li`, `table`,
      and the `code` macro with CDATA.
  - **Markers:**
    - Each marker in the new text must exist in the original page, and must
      appear at most once in the whole resulting document.
    - An unknown or duplicated marker is an error.
    - A marker present in the replaced region but absent from its new text is
      **removed**, and it is reported in the removal list.
- `Apply(doc, edits) (newStorage string, changes []Change, err error)`.
  `Change{Kind, Locator, Before, After, Removed []string}`. `Before` and
  `After` are the editable text of the touched region, and they feed the
  card's diff.

## 4. Tools (`internal/tools/confluence_page.go`)

### `get_confluence_page` (read, chat surfaces main + target)

- Args `{page: string, account?: int}`. `page` is a numeric id, a Confluence URL
  (`/pages/<id>`), or a title resolved through `kb.Search` restricted to
  `confluence`. An ambiguous title returns the candidates.
- The tool is live. It fetches
  `GET /wiki/api/v2/pages/{id}?body-format=storage` (blogpost fallback) and
  gets comments through the existing fetcher's `Comments()`.
- It returns:
  - `{id, title, space, url, version, text, comments[]}`, where `text` is
    `Doc.Text()`;
  - each comment as `{author, created, kind footer|inline, anchor_text,
    resolved, body, replies[]}`.
- Caps: `text` is limited to 60 000 runes. The truncation is flagged, and
  edits stay allowed only outside the truncated tail, which is enforced by
  Validate. At most 200 comments.
- `AccessRead`. It makes no writes. It is mounted only in chat mode (`--chat`),
  never in dev-mode MCP: DEV-01 stays untouched because this is a network
  read, not a local one.

### `edit_confluence_page` (write, External, chat surfaces main + target)

- Args `{page_id, base_version, edits: [{kind: replace_text|replace_section, old?, new?, heading?, new_body?}], reason?}`.
- **Validate:**
  - the write scopes are present;
  - there are 1–20 edits;
  - the field shapes are correct.
- **Normalize** (at propose time):
  - fetches the live page;
  - requires `version == base_version`, otherwise returns a ValidationError
    "page changed since you read it (now vN) — re-read with get_confluence_page";
  - runs `Apply`.
  On success it pins into the stored args:
  `{account_id, page_id, title, url, base_version, new_storage, changes[]}`.
  `new_storage` is what will be written; `changes` feeds the card.
- **Execute** (after Approve):
  - re-fetches the page;
  - if `version != base_version`, returns an error; the card shows the
    conflict and nothing is written;
  - otherwise it issues
    `PUT /wiki/api/v2/pages/{id}` `{id, status:"current", title, body:{representation:"storage", value:new_storage}, version:{number: base+1, message:"Edited via Watchtower"}}`.
    A blogpost uses `/blogposts/{id}`.
  - On success it re-fetches the page into `ext_documents` when that page
    belongs to a selected source, so search reflects the edit on the next KB
    cycle. This is best-effort and reported as `warning`.
  - It returns `{url, version}`.
- `External: true`, so it never auto-executes (AGENT-03).

Both tools are registered in `cmd/actions_registry.go`'s `buildToolRegistry`,
through a client factory built from the account's `*jira.Client` (the
`jiraWriteClientFactory` shape). The registry pin test is updated.

## 5. Chat prompt

The Go chat prompt and the Swift prompt copies (the dual path) gain a short
Confluence-editing paragraph:
- read with `get_confluence_page` before editing;
- keep every `⟦…⟧` marker you don't mean to delete, verbatim;
- prefer `replace_text` for small edits;
- pass `base_version` from the read;
- after a "page changed" error, re-read.

## 6. Desktop

- **`AgentActionCardView`** renders `edit_confluence_page`:
  - a title line with a link;
  - per change: the locator (the section heading, or "text in <section>"),
    followed by a **word-level diff** of Before → After (deleted words struck
    through in red, inserted words in green);
  - a "Removes: <labels>" line when `Removed` is non-empty;
  - on conflict or failure, the row's error (`AgentAction.error`, the
    `agent_actions.error` column) is shown verbatim.
  The word diff is a pure Swift function in WatchtowerCore, a Myers or LCS
  diff over word tokens, and is unit-tested.
- **Confluence section:** an **Allow editing** button, visible when read
  access is OK and write access is not. The CLI reports `can_edit` in
  `confluence spaces --json` output metadata, or through a new
  `confluence access --json` command. The button runs
  `jira login --account N --with-confluence-write` through the existing re-login flow.

## 7. Errors

- Every edit failure at propose time becomes a `ValidationError` with an
  actionable message the model can follow: not found, ambiguous, spans
  blocks, unknown or duplicate marker, version changed, no write scope, or
  the page is too large.
- At apply time:
  - a version conflict returns the error `conflict: the page was edited after the preview (now vN); nothing was written`;
  - 403 means missing scope, with the hint;
  - 409 from Atlassian is treated the same as a conflict.
- The card never manufactures success. `result_json` carries the new version.

## 8. Testing

- **`confluenceedit`:**
  - golden round-trip on real-shape fixtures (the storage fixtures from
    `internal/confluence/testdata/storage` plus new ones with tables, nested
    lists, mentions, Jira macros, images, code, panels, layouts);
  - `replace_text` cases: found, absent, ambiguous, spans blocks, inside a
    table cell, inside a list item, inline formatting preserved around it;
  - `replace_section`: the last section, a nested heading level, a new body
    containing a table, a list and code;
  - marker kept, marker removed and reported, marker unknown, marker
    duplicated;
  - a fuzz round-trip, bounded.
- **Tools:**
  - a fake client covering propose → Normalize pinning;
  - version mismatch at propose;
  - version conflict at apply, with no PUT;
  - a successful PUT body shape;
  - missing write scope;
  - title resolution: ambiguous and unique.
- **Guards:** EXT-05 (three tests, §2). The EXT-01 pin update plus the
  "fetcher/engine can't reach PutJSON" guard.
- **Swift:** the word-diff unit tests, the card summary lines, and the Allow
  editing button logic in the VM.

## 9. Slices

1. Scopes plus `PutJSON`, the login flag, and the EXT-01 narrowing guard.
2. The `confluenceedit` model: parse, text, markers and the round-trip law.
3. `confluenceedit` edits: replace_text, replace_section, markdown → XHTML.
4. Tools: get and edit, the registry wiring, the prompts (Go and Swift),
   EXT-05, and the inventory.
5. Desktop: the diff card, Allow editing, and the CLI access reporting.
6. Docs: the CLAUDE.md note and the app-guide.

## 10. Implementation deltas

Rulings made while implementing this design (ledger:
`.superpowers/sdd/2026-09-30-confluence-page-editing/progress.md`). Earlier
sections above are the original design and are not rewritten to match.

- **R1:** the T5 (Desktop) brief carries T4's exact args/result JSON keys, read
  from T4's committed code rather than copied from this spec's prose — the
  spec's §4 sketch and the actual tool JSON shapes can drift; T4's committed
  code is the source of truth.
- **R2:** `ac:link` page links stay markers — byte-exact space keys and
  anchors, but the link's visible text is not editable inline (cost: can't
  retitle a link from chat).
- **R3:** mention markers are labelled `@accountId` inside `internal/confluenceedit`
  itself; `get_confluence_page`/`edit_confluence_page` relabel them to
  `@Display Name` for the model, from `ext_users`/`Users()`, best-effort
  (cost: an unresolved mention still shows the model an id).
- **R4:** the block model (§3) grew block byte spans, a container id, and a
  region-replacement seam in `Render`, and `replace_section`'s region is
  clamped to the heading's own container — kept in Task 2 (the model) rather
  than pushed into Task 3 (edits), so Task 3 stays about applying edits and
  converting markdown, not about document structure.
- **R5:** stricter than R4 — a section region also stops before any nested
  `ac:layout` directly inside the heading's own container, never swallowing
  or splitting a layout (cost: body content after a layout is not part of the
  preceding section).
- **R6:** the formatting-skeleton guard — before a unit is rewritten, its
  pre-edit text is round-tripped through the markdown→XHTML path and its
  formatting skeleton compared against the unit's actual storage; a mismatch
  refuses the edit rather than silently turning look-alike text (`__init__`,
  `[1](2)`) into real formatting (cost: some edits are refused that a human
  editor would consider safe).
- **R7:** tightens R6 from a skeleton **count** (multiset) to an **ordered**
  sequence — a count let a lost tag and a gained tag of the same kind cancel
  out; the guard also moves NBSP/Unicode spaces outside emphasis delimiters
  first, so a faithful `<strong>Label:&nbsp;</strong>` round-trip isn't
  falsely refused.
- **R8:** the Confluence-editing prompt rule lives in the actions contract
  (`internal/chat/actions_contract.go` ↔ Swift `AgentToolsContract`, pinned by
  shared fixtures) — the surfaces that actually mount the tools — not
  duplicated into the `search_knowledge` prompt copies.
- **R9:** a successful `edit_confluence_page` write does **not** trigger an
  immediate `ext_documents` refresh — `internal/extsync` has no
  single-document refresh path, only its normal per-source cycle. The edited
  page is picked up on the daemon's next external-sync cycle, so a Confluence
  edit made through chat lags `search_knowledge` by up to one cycle. §4's
  "best-effort … reported as `warning`" re-fetch-into-`ext_documents` step was
  not built; `executeConfluenceEdit`'s result carries only
  `{page_id, title, url, version}`, no `warning` field.

- **R10:** **Allow editing** stays inside the Confluence section of Settings →
  Connections → Jira, which is gated on feature `knowledge-connectors`. With
  Confluence sync off the button is hidden, while `get_confluence_page` and
  `edit_confluence_page` still work; the edit tool's refusal names
  `watchtower jira login --account N --with-confluence-write`, the one path to
  the write grant then (cost: one extra step for a sync-off user; v1 limit).
- **§6 correction:** a failed or conflicting write is shown from the action
  row's error column (`AgentAction.error`), not `result_json.error` — Execute
  returns an error, which the registry stores in `agent_actions.error`, and
  writes no result.
- **Retry after a lost response (final review, superseded by R12):** a
  revoked grant at PUT time names
  `watchtower jira login --account N --with-confluence-write`. The "possibly
  this edit was saved" wording that shipped with it is gone — see R12.
- **Tool args (final review):** `get_confluence_page` accepts `account_id` as
  an alias of `account` (the name its result and `edit_confluence_page` use);
  two different ids are a validation error.
- **Attributed emphasis (final review):** a `strong`/`b`/`em`/`i`/`s`/`del`/
  `strike`/`code` element carrying any attribute is a marker, not markdown, so
  a rewrite elsewhere in its unit keeps it byte for byte (the R6/R7 skeleton
  compares tag names only and would not notice a lost attribute).

- **R11 (local review, section rewrites):** a `replace_section` used to
  re-render every block of the section from markdown, silently dropping what
  the editable text cannot show (paragraph alignment, intraword emphasis,
  table layout and column widths, code titles, noformat, multi-paragraph
  list items) — none of it visible in the approved diff. Now the new body is
  matched in order against the section's original blocks by editable text;
  a matched block re-emits its original bytes; a changed block is derived
  from the next unmatched original of its kind and re-rendered only when
  that original passes the R6/R7 skeleton guard and is representable in
  markdown (no attributes on p/li/table/heading, no column widths, not
  noformat, no code-macro parameter but the language, no multi-paragraph
  list item), else the edit is refused naming the block. Headerless and
  column-header tables are one block marker in `Text()` instead of a pipe
  table with a fake header row. The R6 refusal no longer suggests
  `replace_section` as a bypass ("edit that passage in Confluence"). A
  section enclosing one an earlier edit of the same call replaced is refused
  (cost: some section rewrites are refused; the owner edits those blocks in
  Confluence). Guards: `TestEXT05_SectionRewriteKeepsUntouchedBlocksByteExact`
  and `FuzzApply`'s "own text plus one paragraph changes nothing else"
  property.
- **R14 (local review round 3, section-wide lossy deletion):** R13's
  per-gap candidate rule kept missing pairings across a match (a rich
  block moved and edited, duplicate texts, a `<br/>` paragraph split into
  edited blocks). It is replaced by one post-merge check over the whole
  section: every original is kept (matched or moved), derived (checked by
  the representability test) or deleted, and a deleted original markdown
  cannot carry faithfully (the same test, including text that reads back
  as several or other blocks) refuses the edit with the R11 message while
  any changed block — derived or new — of its kind is anywhere in the
  section; for an original whose text reads as another kind, any changed
  block counts. A deletion with no such block stays allowed (the diff
  shows it). Two refinements: a run of new blocks elsewhere in the section
  joining to a multi-block original's text is a move (bytes kept), and of
  two same-text, same-kind originals the merge keeps the rich one when it
  would otherwise delete it. This is stricter than a literal reading that
  exempts changed blocks derived from a faithful original: a changed block
  of the rich block's kind may be its edit whichever original the merge
  derived it from, and R13's guard (delete plain, edit aligned) relies on
  that. Guards: `TestEXT05_SectionRewriteNeverDropsRichBlockSilently`,
  property `FuzzSectionMerge`. Also in round 3: the "already saved"
  comparison strips `local-id` attributes from start tags only, never
  from text or CDATA.
- **R13 (local review round 2, section merge):** the R11 merge must never
  lose formatting through pairing or reordering. A new block whose text
  equals an unmatched original's anywhere in the section was moved, not
  changed: it re-emits that original's bytes at its new place (a reorder
  keeps a code title, a table layout, a paragraph's alignment). Since the
  text cannot say which original a changed block was edited from, every
  unmatched original of a kind a new block in the same gap could derive
  from must itself be derivable, else the edit is refused naming it —
  deleting a plain paragraph and changing an aligned one side by side is
  refused rather than re-paired so the aligned one is silently deleted. A
  rich block is still deleted when no new block of its kind shares its gap.
  Guards: `apply_r13_test.go`. Also in round 2: at `base_version + 1` the
  "already saved" comparison ignores the `local-id`/`ac:local-id`
  attributes Confluence stamps on save, and any other storage there is a
  hedged conflict ("this edit may have been saved; re-read with
  get_confluence_page before retrying") — superseding R12's plain wording
  for that one case.
- **R12 (local review, write precondition):** `Normalize` pins `base_hash`,
  the sha256 of the storage the preview was computed from; `Execute` writes
  only while the live page has the same version AND the same storage hash (a
  change that did not bump the version is a conflict too, no PUT). At
  `base_version + 1` the live storage decides: equal to this edit's
  `new_storage` is `this edit is already saved (vN); nothing was written now`
  (a Retry after a lost PUT response), anything else the plain `conflict: the
  page was edited after the preview (now vN); nothing was written` — so a
  second proposal made off the same read as an applied one is no longer
  told "possibly this edit was saved" (cost: none).
- **Local review, smaller items:** `notes` in the pinned args surface a
  failed user-name lookup on the card; the card offers no Approve for a
  proposal it cannot read; the edit tool skips the display-only space-key
  GET (`GetPageBody`); `get_action`'s arg elision keeps numbers' exact text.

**PutJSON's one production caller** is `internal/tools/confluence_page_client.go`'s
`PutPage` (called only by `confluence_page_edit.go`'s `executeConfluenceEdit`)
— not `internal/confluenceedit`, which §3 might otherwise suggest: that
package is a pure text model with no DB and no network access at all. See
`docs/inventory/external-sources.md`'s EXT-01/EXT-05 for the guard that pins
this.

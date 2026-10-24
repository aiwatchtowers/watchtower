# Images and web links become knowledge (2026-10-25)

Board: #907 (track "Knowledge storage"), group #908 (#909 research, #910 owner uploads, #911 Slack, #912 Confluence, #913 index and retrieval) plus web links. Owner decisions: asks #563, #566, #568. Current-state audit: comment on #909.

## Intent and the why

Owner (ask #563): "an image is information just like text and must carry the same weight"; "if graphics reached us, they must be processed — and the web links too". Today a screenshot in a Slack thread, a diagram inside a Confluence page or a link someone pasted is invisible: search, the agents and the chat see the words around it, never what it shows or points to. The owner's work happens in those screenshots, diagrams and links as much as in text.

Success: a thread whose only content is a screenshot of an error, a Confluence page whose architecture lives in a diagram, or a message that is just a link is found by `search_knowledge` — by the agents, the chat and the briefing — through what the image shows or what the linked page says, the same way as through text.

## Goals

1. **Every new image that reaches Watchtower gets a model-written description** (what it shows, its text, the structure of a diagram, the entities and keys on it), from every source that brings images: Slack message files, Confluence inline images and image attachments, Gmail and IMAP image attachments and inline images, and the owner's own uploads (AI chat attachments, workbench target images).
2. **Every new web link in synced content gets a short summary of the page it points to** (ask #568: any link, in this group) — except links in mail and links that carry a secret in the address (ask #573).
3. **The description is part of the document the image or link sat in** — the Slack thread/day, the Confluence page, the mail thread — as its own section, so it ranks, links and opens like the text around it. Keys and URLs read off an image become links the way they do in text (the `issuekey`/`doclinks` scanners).
4. **Only new content** (ask #566): images and links that arrive after the feature ships; no history backfill.
5. **Cost is not a constraint** (ask #566); the pass still pauses near the Claude plan limit like every background pass, so it never starves the owner's own work.

## Non-goals

- History backfill (ask #566).
- Video, audio, and documents other than images (PDFs keep the existing Confluence extraction path).
- Images inside fetched web pages, and links found inside fetched pages (no crawling: one hop).
- Showing descriptions as a new UI element next to images in the app; they surface through search, agents, chat and the briefing. (The Desktop already has no Slack image view.)
- Phone surfaces; sync between Macs.
- Images in Workchat (they go straight to Claude Code, which sees them).

## Anti-goals (a failure even if it works)

- A description or page summary that is treated as an instruction: content read off an image or a web page is data, exactly like synced text (prompt injection; see "Safety").
- Watchtower fetching an address on the owner's own machine or network on the say-so of a message (SSRF): a link in Slack must never make Watchtower call `localhost`, the local preview server, a router, or an intranet host.
- Image bytes or page bodies piling up on disk.
- A deleted message, page or mail leaving its image description or link summary searchable; a revoked account's descriptions surviving the purge.
- A slow or failing describer delaying sync or the knowledge index.

## Current state (from the #909 audit)

- Slack: `files:read` is requested; `goslack.Message.Files` arrives decoded and is never read; the `files` table (`id, message_channel_id, message_ts, name, mimetype, size, permalink`) exists with no writer; nothing downloads images.
- Confluence: `ac:image` is dropped from page text (`internal/confluence/storage.go` ~406, ~533); image attachments are downloaded (≤ 25 MiB, never persisted, EXT-03), OCR'd on device by `watchtower-ocr` and indexed as attachment documents.
- Gmail/IMAP: only the first text/plain part is kept; image parts are reachable in the parsed tree but not decoded.
- Owner uploads: chat attachments (≤ 5 MiB images) reach Claude as image blocks in the chat only; target images are board-only.
- Models: no background Go call can send an image today; the chat builds Claude image content blocks (`internal/chat/attachments.go` `BuildContentBlocks`, stream-json input). Codex and Ollama take no images.
- The best template for a per-item pass with a status machine, attempts and a cycle budget is the Confluence attachment stream (`internal/extsync/attachments.go`).

## The design

### One media pipeline

- **A media item** is one image or one web link found in a source, with: its source and parent document (enough to compute the parent's knowledge key), how to fetch it (Slack file id + private URL with the account token; Confluence attachment id or external `ri:url`; Gmail message + attachment id; IMAP mailbox/UID/part; a local file path for owner uploads; a URL for links), media type and size, a status (`pending`, `ok`, `skipped_type`, `too_large`, `unreachable`, `unavailable` (no vision-capable provider), `failed`), attempts, and the description.
- **Discovery is part of each sync** (writes only rows, never bytes): the Slack message writer records each message's files and each link in the text; the Confluence converter records each `ac:image` (attachment filename or external URL) and links; the Gmail/IMAP parsers record image parts and links; the chat attachment and target image writers record owner uploads. Content older than the feature's start is never recorded (a start mark set by the migration, the floors precedent).
- **A describe pass in the daemon** (its own phase, after sync, before the knowledge index, the extsync-attachments template): takes pending items in batches under a cycle budget, fetches the bytes to a temp file (deleted right after, EXT-03), and asks the model. Failures retry a bounded number of times; a permanently failing item ends `failed` and is never retried by the pass.
- **Dedupe by content:** the same image bytes (sha256) or the same normalized URL is described once; later items reuse the description.

### Describing

- **Images:** one call per image with the image as a content block and no tools, strong tier (the owner wants schemes read well and does not care about cost), prompt `media.describe` (both providers per `add-ai-prompt`; the image call itself is Claude-only today — see the provider rule). Output: a short title, a description (what it shows; for a diagram, its parts and how they connect), the verbatim text on it, and keys/URLs on it. Capped length.
- **Web links:** fetch the page, extract readable text (title, main text; the `internal/extract` HTML helpers), then one light call `media.summarize_link` for a 2–5 sentence summary plus the page title. A link to a plain image URL is an image item instead. A login page, an error page or a non-HTML/non-image response gets `unreachable` (no summary).
- **Provider rule:** only a vision-capable provider describes images (Claude today). With Codex or Ollama as the configured provider, image items wait as `unavailable` and are described when a vision-capable provider is available — never silently dropped. Link summaries work on every provider.

### Into the knowledge index

- The parent document gets one section per described item: `Image: <title> — <description>` / `Link: <page title> (<url>) — <summary>`. Its anchor opens the parent message/page at the item. The parent is re-rendered when a description lands (a `kb_dirty` mark for the parent key, the Go↔SQL key dual path already used by source deletions).
- Keys and URLs read off an image go through the same link scanners as text, so a Jira key on a screenshot links the thread to the issue.
- Confluence image attachments that already have OCR text keep their own attachment documents; their description is added as a section beside the OCR text, and the inline `ac:image` in the page body becomes an `Image:` section of the page that points at the attachment.
- Owner uploads: a chat attachment's description joins that chat's turn for the registry miner (part B), so a decision shown in a screenshot can be proposed; a target image's description is returned by `get_target` next to the image path, so agents read it.

### Deletions, purge, privacy

- Deleting the parent (Slack tombstone, Confluence page gone, Gmail/IMAP diff, chat or target deleted) deletes its media items and drops their sections (the existing source-deletion paths, SRCDEL-01..03).
- A revoked account's media items go with the account purge (PURGE-01..02).
- Image bytes and page bodies are never stored; only descriptions, summaries, titles, URLs and the fetch locator.

### Safety

- **Fetching links:** only `http`/`https`; the resolved address must be public — loopback, link-local, private (RFC 1918, ULA), multicast and the host's own addresses are refused, checked on every redirect (≤ 5) and at connect time (no DNS rebinding); no cookies, no credentials, a fixed user agent; a size cap and a time limit per fetch; links to sources Watchtower already syncs (Slack, Confluence, Jira, Linear, Gmail, Google Docs/Calendar) are not fetched — the existing link scanners already connect them.
- **Links never opened (ask #573):** any link found in mail (Gmail, IMAP) — a GET there can unsubscribe, confirm, approve or log in — and any URL whose query or fragment carries a secret-looking parameter (`token`, `sig`/`signature`, `key`, `secret`, `code`, `auth`, `session`, `X-Amz-*`/presigned forms, and the like; the list is the builder's, pinned by a test). Mail images are still described; only mail links are skipped.
- **Prompt injection:** the describe and summarize calls have no tools; their output is stored and indexed as data, rendered inside the parent document like the text around it, never into a system prompt; size-capped; a description cannot create links other than the keys and URLs that the scanners recognize.

## Constraints

- Contracts touched (amendments need the owner's approval with this document): EXT-03 (image bytes still never persisted — extended to every source), KB-01..03 (new sections, re-render on description), SRCDEL-01..03 and PURGE-01..02 (media rows follow their parent), CHAT-05 (no outbound fetch from the chat artifact side — unaffected; the fetch lives in the daemon), the Slack API budget (file downloads share the account's rate limiter).
- Model calls outside any write transaction; prompts on stdin; `planusage.NearLimit` pause; strong tier for images, light tier for link summaries.
- One migration for the media table(s) and the start mark; mirror `schema.sql`, golden + Swift test schema.
- Public repo hygiene: synthetic images and pages in tests.
- User guide: a page on what is described and where it shows.

## Left to the builder

- Table shape (one `media_items` table or items + a description cache keyed by hash), the status names, batch sizes, caps (image bytes, page bytes, description length) and timeouts.
- The exact Claude invocation for an image (`claude -p` with stream-json input and the chat's content-block builder is the expected route).
- Readable-text extraction details for web pages.
- Phasing (sensible order: pipeline + Slack images → links → Confluence → mail → owner uploads → docs).

## Settled after the builder check (my calls)

- **Slack discovery covers both writers.** The default cycle saves `search.messages` matches (`internal/sync/search_sync.go`), whose decoded struct has no files; the full-sync/replies path (`message_sync.go`) has `goslack.Message.Files`. The search path decodes the match's raw `files` when Slack includes it, and otherwise, for a match marked as carrying files (file-share subtype / upload flag), fetches that one message through the history call inside the account's rate limiter. Links come from the message text on both paths.
- **Junk filter (not a cap):** tracking pixels and tiny images (below a few KB or about 1×1), mail signature logos and avatars (inline images in a mail's signature part), and the same bytes seen again are not described. Everything else is, bots included.
- **Vision provider:** the strong tier's configured provider describes images when it can take an image (Claude; Codex if its CLI image input works in our wiring — the builder checks and wires it, otherwise Codex counts as unable); otherwise items wait as `unavailable`.
- **Owner uploads:** a chat attachment's description joins that chat's turn in the ideas registry's chat material (part B, PR #465 — `ideas.consolidate` reads chat turns), so a decision in a screenshot can be proposed for Approve.
- **Retention:** descriptions and summaries live as long as their parent and follow its deletion and the account purge, like message text and digests do; no image bytes or page bodies are kept.
- **Knowledge search becomes an AI feature (ask #573):** its Features entry (`internal/features/registry.go`) gains AI cost and new copy, the onboarding/guide wording follows, and existing installs with Knowledge search on get the pass from the upgrade on (only new content, so nothing old is fetched).
- **Contracts also touched:** FEAT-01 (the Knowledge search entry's cost and copy), KB-02 (the index itself stays mechanical: the describer lives outside `internal/kb`, the index only renders stored descriptions) and SRCDEL-02 (a tombstoned Slack message's media rows go with it and come back with the next fetch, like its files and reactions).

## Calls made by me (for the owner to check)

1. Descriptions become sections of the parent document, not separate search results — the image weighs like the text around it.
2. Links are fetched only to public addresses; intranet and local links are not fetched (a link to an internal page usually needs a login anyway), and links to sources we already sync are left to the existing link scanners.
3. One hop only: no images inside fetched pages, no links inside them.
4. With Codex/Ollama as the provider, images wait until a vision-capable provider is configured instead of being dropped.
5. Strong model for images (diagrams), light model for link summaries.
6. Workchat images are out (Claude Code already sees them).
7. (Owner decision, ask #573) No new switch: describing images and links is part of Knowledge search — it runs whenever Knowledge search is on, and the feature's copy changes from "no AI, nothing leaves your Mac" to say it uses AI for images and fetches public links.

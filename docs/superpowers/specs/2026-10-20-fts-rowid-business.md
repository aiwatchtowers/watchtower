# Search indexes keyed by row — business spec

Board #872 (group #527). Owner decisions: ask #362 (rebuild on the launch screen; fix all three indexes together). Technical spec: `2026-10-20-fts-rowid-design.md`.

## The problem

Three full-text search indexes find "their" row by a column the index cannot look up: the Slack messages index (`messages_fts`, by channel + timestamp), the meeting transcripts index (`transcripts_fts`, by transcript id) and the memory index (`memory_fts`, by node id). So every time a row is written, edited or deleted, SQLite reads the whole index to find the old entry. For Slack this happens for every synced message: the sync holds the database's write lock longer the more messages the install has, and clearing Slack data reads the whole index once per message. The same pattern makes several tests quadratic.

## What changes for the owner

- **Writes stop slowing down as the database grows.** Each index is keyed by its row's own id, so updating or removing an entry is a direct lookup.
- **Search works exactly as before** — same results, snippets and order in the app, the chat's message search and the memory search.
- **One-time rebuild after the update, on the launch screen.** The Slack messages index is filled once from the existing data (the transcripts index is small and is rebuilt inside the update itself). The launch screen shows "Updating search index — 0:42" while it runs, in the same step as the database compaction (#850); "Skip for now" appears after 15 s and the rebuild continues at the next launch. If the rebuild is skipped, search finds only what was synced or written since the update until the rebuild completes at a later launch; nothing is lost. After the rebuild the old index is removed, which also frees space for the compaction that follows. If the app is not opened (daemon only) or the rebuild is skipped, the background sync finishes it in short steps.
- Nothing to configure.

## Decisions for the owner

One open (asked with this review): the memory index. Its notes' text lives only in that index and the vault files, so rebuilding it carries a real risk (an empty index would make the assistant rank memories as unimportant and could evict them), while it is small enough that its slowness does not matter today. My proposal: leave it as is in this work and revisit if it grows. This departs from "fix all three together" (ask #362), so it is your call.

My calls, to check while reading:
- the rebuild runs before the compaction in the same launch step, so the space the old indexes free is reclaimed in the same launch;
- a skipped or interrupted rebuild resumes where it stopped (it works in chunks), it never starts over;
- during the gap between the update and the rebuild finishing, search may miss older Slack messages; nothing is lost;
- the rebuild has its own rules: it is not blocked by the compaction giving up after failures, and it needs less free disk than the compaction;
- a new rule for future changes: anything that rebuilds the messages table must keep each row's internal id, because the index now relies on it.

## Out of scope

- Search ranking or query changes.
- Other tables' indexes (only these three use this pattern; memory is proposed out, see above).

## How we know it is done

- After the update, the first launch shows the rebuild once; search returns the same results as before for the same queries.
- Syncing and clearing Slack data no longer get slower with the number of stored messages (measured on a large synthetic database).
- The tests that seeded around the quadratic trigger no longer need to.

# Compacting the database after an update — business spec

Board #850 (group #527). Owner decision: ask #349 ("at launch after an update", with a visible "Optimizing database…" step). Technical spec: `2026-10-18-db-compact-design.md`.

## The problem

Version 0.21 cleared the stored Slack payloads (migration 00134, data minimisation). SQLite does not give that space back by itself. On a long-running install `watchtower.db` is a multi-GB file whose `messages` table is mostly empty pages: about one message per page. Every query that touches messages — search, digests, inbox, sync — reads many times more pages than it needs to. This is likely the main reason 0.21 feels slow.

The fix is SQLite's `VACUUM`, which rewrites the file compactly (several times smaller on such an install). It needs the database to itself for its duration — up to a minute or so for a multi-GB file — so it cannot run quietly while the app works.

## What changes for the owner

- **After an update, when the database has space to give back, the first launch shows "Optimizing database…"** on the launch screen, with the size it is working on and the time so far ("Optimizing database — 2.0 GB, 0:42. This happens rarely, usually after an update."). When it is done the app opens as usual and the daemon starts.
- **It runs only when it pays off:** after a migration known to free a lot of space (00134 is the first one), or when more than a quarter of the file (and at least 256 MB) is free space. Otherwise the launch looks exactly as today.
- **It never risks data or the disk.** `VACUUM` is all-or-nothing: if it is interrupted (the app is quit, the Mac sleeps or crashes) the database stays as it was and the step comes back at the next launch. If the disk does not have enough free space (twice the database's size), the step is skipped and a small notice says how much space it needs; the app works normally.
- **No launch loop.** If compaction fails three launches in a row (for example a disk error), it stops trying until the next app version and says so once.
- **"Skip for now"** appears on the launch screen after 15 seconds. It stops the step safely (the database is unchanged) and the app opens; the step comes back at the next launch.
- **The daemon waits.** At this point of the launch the daemon is not running yet (after an update it is always stopped; on an ordinary launch the app restarts it anyway), so nothing competes for the database. Agent sessions left running across the update can see their status updates delayed or dropped for that time; their next update corrects them.
- `watchtower db compact` is also available by hand (it reports what it would gain and refuses while the daemon runs unless told otherwise).

## Decisions for the owner

None open — the timing was decided in ask #349. My calls, for you to check while reading:
- the thresholds (a known space-freeing migration, or free space over 25 % and over 256 MB);
- the disk rule (free space at least twice the database size, else skip with a notice);
- "Skip for now" after 15 seconds, and the step returning at the next launch.

## Out of scope

- Moving agent analytics out of `watchtower.db` (#849).
- Physically scrubbing deleted data or encrypting the database (#595). Compaction does rewrite the file without the cleared payloads, which helps that goal, but it is not a guarantee about free blocks on disk.
- Background or scheduled compaction while the app runs.

## How we know it is done

- On a long-running install, the first launch of the new version shows the step once; `watchtower.db` becomes several times smaller; the next launch shows no step.
- Search, Inbox and digests feel faster; `db lockstats` holds for message-heavy sites drop.
- A launch with too little disk space skips with the notice and opens normally.

# SQLCipher for the whole database — spike (board #602)

Date: 2026-10-21. Status: research spike, no production code changed. Decision pending (owner ask).

## Question

Encrypting individual columns is ruled out: it breaks FTS5 (all search, KB, `find_experts`) and `LIKE`
(inbox mentions, Jira `[~id]`, channel stats, linkscan). The alternative is SQLCipher over the whole
file, which SQL does not see. This spike measures what that costs and checks that it builds:

- hook open (budgets 500 ms / 1 s), with a raw key (no PBKDF2) from the Keychain, unwrapped by the
  Secure Enclave;
- search, `search_knowledge`, LIKE-heavy scans, aggregates;
- `kb.Reindex`-like rebuilds, write bursts, VACUUM;
- the one-time `sqlcipher_export`;
- the Go driver swap and GRDB + SQLCipher on the Swift side, plus whether one file opens on both sides.

## Setup

- Machine: Apple M3 Max (16 cores), 48 GB RAM, macOS 27 (Darwin 27.0), internal SSD.
- Data: two copies of real install databases, taken with `sqlite3 .backup` into a scratch directory
  outside the repo. The live files were never opened by a repo-built binary.
  - **S**, 110 MB: the current schema (537 schema objects), 16.4k KB chunks over 2.7k documents, no
    Slack messages.
  - **L**, 546 MB: an older schema (201 objects), 145k Slack messages (486 MB of `messages` pages),
    `messages_fts`, no KB tables.
- Engines:
  - **modernc**: `modernc.org/sqlite` v1.49.1 (SQLite 3.53.0). This is what we ship today.
  - **cipher-plain**: `github.com/mattn/go-sqlite3` v1.14.52 (cgo), linked against a SQLCipher
    4.19.0 community amalgamation (SQLite 3.53.4) built with CommonCrypto, opening the plaintext
    file without a key.
  - **cipher-enc**: the same build opening a SQLCipher copy made by `sqlcipher_export`. Raw 32-byte
    key, `key=x'<64 hex>'`, so no PBKDF2. SQLCipher 4 defaults: 4096-byte pages,
    HMAC-SHA512, AES-256-CBC. WAL is kept.
- Method: each open measurement is a fresh process (25 runs; the first is reported apart, then the
  median of the rest). Each query is run 7 times on one connection; "first" is the first run and
  "warm" is the median of the other 6. Each write test runs on a fresh copy of the file, 3 runs,
  median shown. The OS page cache is warm in every run: `purge` needs root, so a truly cold disk
  was not measured (see Unmeasured). Default `cache_size` (2 MiB) unless stated.
- The open path copies `db.OpenExisting`: a `mode=rw` file URI, `busy_timeout(500)`,
  `query_only(1)`, one connection and a Ping. After that come hook-like reads: the
  `goose_db_version` scan done by `db.Open`, a workbench row, the newest terminal session and the
  open asks.

## Numbers

### Hook open (fresh process, in-process time from open to the reads finishing)

| DB | modernc | cipher-plain | cipher-enc | enc p90 |
|---|---|---|---|---|
| S 110 MB (537 objects) | 3.07 ms | 2.75 ms | 3.03 ms | 3.11 ms |
| L 546 MB (201 objects) | 1.24 ms | 1.22 ms | 1.32 ms | 1.35 ms |

- The whole bench process takes about 11 ms of wall time in every configuration. Encryption adds
  **0.1–0.3 ms** to an open: page 1 and the schema pages are decrypted, and there is no KDF.
- The open cost is driven by how many schema objects there are, not by the file size.
- Key fetch, measured with a small Swift CLI using CryptoKit and the Security framework. It reads a
  login-keychain generic-password item holding an SE-wrapped DB key, restores the Secure Enclave
  P-256 key, runs ECDH and HKDF, then an AES-GCM open:

| Step | first in process | warm median (30) |
|---|---|---|
| Keychain read (`SecItemCopyMatching`) | 1.4–1.7 ms | 1.6 ms |
| SE unwrap (ECDH in the enclave + HKDF + AES-GCM) | 4.6–4.8 ms | 4.5 ms |
| **Total** | **6.1–6.4 ms** | **6.1 ms** |

**A hook pays about 6.5 ms more than today: ~6 ms for the key and ~0.3 ms for the open.** That is
under 1.5 % of the 500 ms budget.

### Queries (warm median, default 2 MiB page cache)

| Query | DB | modernc | cipher-plain | cipher-enc | enc vs modernc |
|---|---|---|---|---|---|
| `messages_fts` MATCH + join, top 50 | L | 4.81 ms | 2.24 ms | 7.58 ms | +58 % |
| KB `search_knowledge` shape (kb_fts + 2 joins, bm25, snippet) | S | 13.05 ms | 7.63 ms | 16.00 ms | +23 % |
| Inbox mentions `LIKE '%<@id>%' OR '%<@id\|%'` (full scan) | L | 115 ms | 89 ms | 566 ms | ×4.9 |
| linkscan `LIKE '%atlassian.net/wiki/%'` over all messages | L | 169 ms | 132 ms | 610 ms | ×3.6 |
| Channel stats aggregate (GROUP BY channel) | L | 162 ms | 113 ms | 669 ms | ×4.1 |
| 1000 point lookups by rowid | L | 5.8 ms | 4.4 ms | 9.8 ms | +69 % |
| KB body LIKE (full scan) | S | 44 ms | 33 ms | 77 ms | +74 % |
| KB aggregate by source | S | 32 ms | 19 ms | 67 ms | ×2.1 |
| Inbox list, 200 rows | S | 2.7 ms | 1.8 ms | 1.8 ms | −33 % |

Same queries on cipher-enc, but with a large page cache on the connection (`cache_size` of 1 GiB
for L and 256 MiB for S):

| Query | first run | warm median | cipher-plain warm, same cache |
|---|---|---|---|
| messages FTS | 9.0 ms | 1.46 ms | 1.44 ms |
| mentions LIKE scan | 601 ms | 39 ms | 39 ms |
| linkscan scan | 77 ms | 74 ms | 75 ms |
| channel aggregate | 58 ms | 50 ms | 51 ms |
| KB search | 17.0 ms | 6.5 ms | — |
| KB LIKE scan | 73 ms | 28 ms | — |

How to read these:

- The 5–15 % Zetetic figure holds only when the working set is already in SQLite's own page cache.
  A page that comes from the OS cache is decrypted and HMAC-checked on every read. On this machine
  that costs about **1 ms per MB of pages** (roughly 1 GB/s). So a full scan that misses the 2 MiB
  default cache is 4–5× slower: every page is decrypted again on every scan.
- Once a page is in SQLite's cache, encrypted and plaintext reads take the same time.
- The cgo SQLite build is 20–45 % faster than modernc on plaintext. Part of the encryption cost is
  paid back by dropping modernc. With a larger cache on the daemon's and Desktop's long-lived
  connections, encrypted warm queries come out faster than today's modernc numbers.

### Writes (median of 3, fresh copy each run, default cache)

| Workload | DB | modernc | cipher-plain | cipher-enc | enc vs modernc |
|---|---|---|---|---|---|
| `kb_fts` rebuild (≈ `kb.Reindex` of everything) | S | 770 ms | 526 ms | 853 ms | +11 % |
| `messages_fts` rebuild | L | 218 ms | 150 ms | 189 ms | −13 % |
| 200 committed tx × 50 rows (sync-cycle burst) | S | 39 ms | 35 ms | 49 ms | +26 % |
| same | L | 52 ms | 44 ms | 49 ms | −6 % |
| 100k-row insert, one tx | S | 240 ms | 242 ms | 291 ms | +21 % |
| same | L | 293 ms | 264 ms | 353 ms | +20 % |
| VACUUM | S | 385 ms | failed¹ | 564 ms | +47 % |
| VACUUM | L | 2.49 s | 1.50 s | 3.43 s | +38 % |

¹ SQLCipher 4.19 refused to VACUUM the plaintext copy of S (`unable to open database`). It
VACUUMed the encrypted copy of S, the plaintext L and a fresh plaintext file without trouble. This
was not investigated further: no production path VACUUMs a plaintext file through SQLCipher, and the
migration (`sqlcipher_export`) works on S. It is still worth a look before shipping.

### One-time `sqlcipher_export` (plaintext → encrypted, attach + export + `journal_mode=WAL`)

| DB | time (3 runs) | output size | peak extra disk |
|---|---|---|---|
| S 110 MB | 0.52–0.55 s (1.04 s on the very first run) | 108.6 MB | ≈ 1× source |
| L 546 MB | 1.69–1.73 s | 547.8 MB | ≈ 1× source |

The export needs **2× the database size** free until the old file is removed. On these sizes it is
a sub-2-second launch step. Rekeying (`PRAGMA rekey`) rewrites every page at about the same cost, and
needs the database to itself.

### Checks

- The encrypted file has no `SQLite format 3` header; a marker string written through the
  encrypted path does not appear in the file; a wrong key fails with `file is not a database`.
- Go writes and Swift reads, and the other way round, on one WAL file:
  1. The Go build (mattn + SQLCipher 4.19) wrote the file: an FTS rebuild, write bursts, VACUUM.
  2. GRDB 7.11.1 + SQLCipher.swift 4.19.0 opened it in a `DatabasePool`
     (`prepareDatabase { PRAGMA key = "x'…'" }`, 5.7 ms to open). It reported
     `cipher_version 4.19.0 community`, SQLite 3.53.4, `ENABLE_FTS5 = 1`, WAL, the same cipher
     settings, and ran a `kb_fts MATCH … ORDER BY bm25` in 1.2 ms. Then it created a table.
  3. The Go side reopened the file and saw the new table.

## Build findings

### Go

- **modernc.org/sqlite cannot do SQLCipher.** The driver has to become cgo.
- **No maintained turnkey driver.**
  - `mutecomm/go-sqlcipher` was last tagged in 2020 (SQLCipher 4.4).
  - Other `go-sqlcipher` forks are small and stale.
  - Mainline `mattn/go-sqlite3` has no SQLCipher tag and no `sqlite3_key` binding.
  - `ncruces/go-sqlite3` (WASM) has its own encrypting VFSes (Adiantum/XTS). Their file format is
    not SQLCipher's, so GRDB cannot open those files.
- **Realistic path:** a small in-repo fork (or vendored copy) of `mattn/go-sqlite3`.
  - Its `sqlite3-binding.c/.h` are replaced by the SQLCipher amalgamation.
  - cgo flags: `SQLITE_HAS_CODEC`, `SQLITE_TEMP_STORE=2`, `SQLITE_EXTRA_INIT/SHUTDOWN`,
    `SQLCIPHER_CRYPTO_CC`, FTS5 enabled; link with `-framework Security -framework CoreFoundation`.
  - This spike linked the amalgamation as a static lib through mattn's `libsqlite3` tag. That
    works: `cipher_version` reports 4.19.0. But the tag also pulled a Homebrew `libsqlite3.dylib`
    into the binary. Production must not do that, because two SQLite copies in one process break
    POSIX locking on the same file. Hence the vendored fork.
- **Key delivery:** SQLCipher reads a `key` URI parameter (`key=x'<hex>'` is a raw key) before
  any page read. That matters because mattn runs its own PRAGMAs (`busy_timeout`, `locking_mode`,
  `synchronous`) *before* `ConnectHook`, so a `PRAGMA key` in the hook comes too late. A fork can
  instead call `sqlite3_key_v2` right after `sqlite3_open_v2`. That is cleaner: no key in the DSN
  string, which `sql.DB` keeps in memory for the pool's lifetime.
- **What `internal/db` has to change:**
  - DSN: mattn has no generic `_pragma=`. Today's `_pragma=busy_timeout/foreign_keys/synchronous/
    query_only` become `_busy_timeout`, `_foreign_keys`, `_synchronous`, `_query_only` (all
    supported), or a `ConnectHook`. `_txlock=immediate` is supported by mattn as is, and
    `mode=rw` passes through in file URIs.
  - `sqlite+metrics` (`internal/db/lockmetrics/driver.go`) wraps a generic `driver.Driver` and keeps
    working. Its `*sqlite.Error` and `sqlite3.SQLITE_BUSY*` code switch, and `db.go`'s FK check,
    move to `sqlite3.Error.ExtendedCode`.
  - Imports of `modernc.org/sqlite`: 3 production files, plus 13 test files.
- **Build, CI and notarization:**
  - The app's CLI build (`scripts/build-app.sh`) is already `CGO_ENABLED=1` for arm64 (code
    grammars), so a notarized build changes little: static C, system frameworks only.
  - `.goreleaser.yaml` (`CGO_ENABLED=0`, darwin+linux × amd64/arm64) cannot build this any more.
    It would need per-target C toolchains, and Linux needs an OpenSSL or LibTomCrypt provider
    instead of CommonCrypto.
  - The Ubuntu CI jobs (Go Test, race shards, lint) need a Linux build of the same fork, with
    OpenSSL. The alternative is a build tag that keeps modernc for tests, but then CI no longer
    tests the shipped engine.
  - cgo also slows `go test` builds the first time (the amalgamation compiles in about 30 s; it is
    cached after that).
- **Upside:** cgo SQLite is 20–45 % faster than modernc on plaintext in every read test above.

### Swift (GRDB 7)

- GRDB 7 supports SQLCipher through **SPM only by forking GRDB**. Its `Package.swift` carries
  "GRDB+SQLCipher" comments: drop the `GRDBSQLite` system-library target and add
  `SQLCipher.swift`. CocoaPods has `GRDB.swift/SQLCipher`. A patched copy of GRDB 7.11.1 plus
  `SQLCipher.swift` 4.19.0 (a binary xcframework from Zetetic, community edition) built in a
  separate package in 36 s. The Desktop ML stack was not rebuilt.
- FTS5 is compiled into the SQLCipher.swift build. GRDB's Swift FTS5 APIs (`FTS5Pattern` and so on)
  sit behind `#if SQLITE_ENABLE_FTS5`, which needs a define in the fork. The Desktop only uses raw
  `MATCH` SQL (`SearchQueries`, `MemoryQueries`, `ChatSearchQueries`, `GuideQueries`), which works
  either way.
- Go and Swift stay compatible only if both sides are pinned to the **same SQLCipher major version
  and the same cipher settings** (4.x defaults here). The Go amalgamation and SQLCipher.swift need
  to move in lockstep, with a test that opens one side's file on the other.
- SPM has a single GRDB in a package graph. `WatchtowerKit` (the iPhone app) shares the
  dependency, so the phone would ship SQLCipher too, even though it never opens this database. GRDB
  warns that the SQLCipher build must be the only SQLite in the app; a second copy in the process
  on the same file is the locking hazard above.

## Risks

- **The Keychain while the Mac is locked.** Hooks run while the owner is away and agents keep
  working. A `WhenUnlocked` item, or an iCloud-keychain item (we already saw the notary profile go
  "missing" on a locked Mac), cannot be read then. The item must be `AfterFirstUnlock(ThisDeviceOnly)`
  in the data-protection keychain, or the key must come from a long-lived process (daemon or
  session host) over its socket. Reading while locked was not measured.
- **Keychain sharing between binaries.** The item must be readable without a prompt by the Desktop
  app, the CLI, the daemon, the MCP server and every hook. A file-based login-keychain ACL is
  per-binary and breaks on every update unless the code requirement is the team ID. A shared
  `keychain-access-groups` entitlement on the bundled CLI needs signing work and may need a
  provisioning profile for Developer ID; that is unverified. A Go hook also needs cgo calls into
  Security.framework (CryptoKit is Swift-only, so the Go side uses `SecKey` APIs).
- **Every opener needs the key.** That covers `db.Open` (goose migrations under the
  `<db>.migrate.lock` flock), `RunSchemaUpgrade`, `db compact`, the session-state hook (`db.Open`,
  not under a deadline), `OpenExisting` hooks, Desktop GRDB, `DBLockMetrics`, the code-index CLI,
  tests and debugging. `sqlite3 -readonly` is no longer usable on the file; a debugging session needs
  a `sqlcipher` shell and the key.
- **Full scans.** Without a larger cache, LIKE scans and aggregates over big tables cost 4–5×:
  inbox mentions, linkscan, channel stats, `kb` LIKE. The daemon cycle runs several of them. The fix
  is `cache_size` on long-lived connections, at the price of memory per pooled connection; FTS
  replacements for the hot LIKEs are a possible further step.
- **WAL and backups.** WAL frames are encrypted, and `-shm` holds only the WAL index. Plaintext
  history is not scrubbed by the migration:
  - old `*.bak-*` copies (one install had a 586 MB plaintext backup beside the DB);
  - Time Machine and APFS snapshots;
  - freed SSD blocks.

  The migration must delete or re-export backups, and the docs must say that history before the
  switch stays wherever it was backed up.
- **The database is not the only plaintext store.** Next to it sit `agentlog.db` (a separate
  file), `daemon.log`/`watchtower.log`/`sessions.log`, per-account credential JSON files, the
  memory vault, automation drafts and `dblock.jsonl`. Encrypting `watchtower.db` alone protects part
  of the data.
- **Rotation.** `PRAGMA rekey` needs the database to itself (stop the daemon, the MCP servers and
  the hooks) and takes about as long as the export (~2 s for 0.5 GB). An SE wrap lets the wrapping
  key rotate without touching the data.
- **Recovery.** If the Keychain item or the Secure Enclave key is lost (a new Mac, a restore from
  backup, a reset), the data is gone. That suits a re-syncable cache, but owner-made data (asks,
  boards, memory, chat history) would be lost. An escrow or export path has to be decided.
- **Threat model.** FileVault already encrypts the disk at rest. SQLCipher adds protection only
  against copying the file while the user is logged in: other same-user processes, agents running
  `cat`/`sqlite3` on the file, sync or backup tools, a stolen unlocked machine. Any process that can
  get the Keychain item can still read everything.

## The fallback: session state in a separate plaintext database

The fallback was proposed in case hooks turned out to be expensive. **The numbers do not call for
it.** An encrypted open plus the key fetch adds about 6.5 ms against 500 ms / 1 s budgets. Splitting
the database costs a lot:

- cross-file foreign keys (session ↔ workbench, asks, targets);
- a second migration track (like `agentlog.db`);
- dual-path Desktop queries;
- a second file to back up.

It would only make sense if hooks *cannot* get the key, for example a Keychain item unreadable on a
locked Mac with no daemon running. That is better solved by making the key reachable (an
`AfterFirstUnlock` item, or a socket on the session host) than by splitting the schema.

## Recommendation and options

**Performance is not the blocker.** Hooks are unaffected. Search and FTS rebuilds land within
±25 % of today, and are faster than today once the driver is cgo and the page cache is sized.
The real costs are elsewhere:

- maintaining two forks (mattn + SQLCipher amalgamation, and GRDB + SQLCipher.swift, pinned
  together);
- dropping the pure-Go cross-build and fixing the Linux CI;
- key availability for every process, including on a locked screen;
- the plaintext files around the database.

1. **A — Adopt SQLCipher for `watchtower.db` (and `agentlog.db`), in stages.** First swap modernc
   for a vendored mattn + SQLCipher fork and fork GRDB, with no encryption yet; that alone speeds
   things up. Then deliver the key through an `AfterFirstUnlock` data-protection Keychain item
   wrapped by the SE, with a socket fallback, and raise `cache_size` on the long-lived connections.
   Then run a launch-time `sqlcipher_export` with a 2× free-space check and the backups removed,
   and encrypt the credential files and logs. Effort: large, several PRs.
2. **B — Do not encrypt the database now.** Rely on FileVault. Tighten what is cheap: 0600 on every
   workspace file, the credential JSONs moved into the Keychain, the old `*.bak-*` copies removed,
   logs stripped of content. Effort: small. Gap: same-user processes can still read the database.
3. **C — Only the engine swap.** Ship part one of A (cgo SQLCipher-capable driver + GRDB fork, no
   key) for the speed and to keep the door open, and decide on encryption later. Effort: medium. It
   commits us to the forks without the security benefit yet.

**Suggested:** decide the threat model first. If the goal is "a copy of the file, or another
same-user process, must not read Watchtower's data", choose **A**: the measured costs are
acceptable. If FileVault-level protection is enough, choose **B**. The split session-state database
is not recommended in either case.

## Not measured

- **Truly cold disk** (OS page cache dropped): `purge` needs root. Encryption does not change how
  many pages are read, so cold-disk cost ≈ today's I/O plus the decryption measured above
  (~1 ms/MB).
- **A full daemon cycle** on the copy: it needs live accounts and network. It is estimated from the
  pieces above: writes +10–25 %, scans 4–5× at the default cache, otherwise ≈ today.
- **Keychain reads while the screen is locked**, and Keychain sharing across differently signed
  binaries without a prompt.
- **`cipher_use_hmac = OFF` or other cipher tuning.** It would cut the per-page cost but drop tamper
  detection; not tried.
- **Concurrent Go and Swift processes on the encrypted WAL file under load.** Only sequential
  interop was checked. SQLCipher documents multi-process WAL as supported.
- **The SQLCipher 4.19 VACUUM failure on one plaintext copy** (footnote ¹).

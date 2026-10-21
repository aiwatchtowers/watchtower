# Database encryption with a key bound to this Mac — design (board #603)

Date: 2026-10-21. Status: design, no code. Depends on the spike #602
(`docs/superpowers/specs/2026-10-21-sqlcipher-spike.md` on `spike/602-sqlcipher`); the owner chose its
option **A — SQLCipher in stages**. Closes the Slack "strong encryption" requirement and the CASA item on
data at rest. #604 owns the plaintext files around the database; #601 owns revoke/lease purge.

## 1. Goal and threat model

`watchtower.db` and `agentlog.db` become SQLCipher files. Their key is random, wrapped by a Secure Enclave
key, and kept in the data protection Keychain as `AfterFirstUnlockThisDeviceOnly`, readable only by
Watchtower binaries signed by our team.

- **Covered.** A copy of the file — a USB stick, Time Machine, iCloud Drive/Dropbox sync of the folder,
  Migration Assistant to a new Mac, a support bundle, an agent running `cat`/`cp`/`sqlite3` on the file —
  is ciphertext. A wrong or missing key fails with `file is not a database`; nothing is readable.
- **Not covered.** A process that can run our signed CLI as the owner can still read the data through
  it (`watchtower … --json`, `watchtower db shell`). That was true before and stays true: SQLCipher
  protects the file, not the owner's account. FileVault still covers a powered-off disk.
- **History.** Plaintext pages that exist before the switch (Time Machine, APFS snapshots, freed SSD
  blocks, old `.bak` copies) are not scrubbed. The guide says so.

## 2. Lessons carried in

- **#567 (owner's note: no Keychain prompts after every binary update).** I could not find the #567
  record in the repo or on GitHub (the repo's #567 is the session-place board target). I carried over
  the lesson the owner stated, which matches #51 (TCC grants keyed to an ad-hoc cdhash):
  **never use a file-based (legacy) Keychain ACL.** Its trusted-app list pins a binary and prompts again
  when the binary changes, and an ad-hoc build gets a new cdhash on every build. Access in this design
  depends only on an **access group entitlement under our team ID**, which stays the same across
  updates. The code always sets `kSecUseDataProtectionKeychain` and never falls back to the file
  keychain: that fallback would quietly create exactly the item that prompts.
- **The spike.** Hooks pay about 6.5 ms more (6 ms for the key, 0.3 ms for the open) against
  500 ms / 1 s budgets. Full scans run 4–5× slower at the default 2 MiB cache, and a sized
  `cache_size` removes that. The export takes under 2 s for 0.5 GB and needs 2× the disk.
- **Mobile E2E.** The hub's keys are already data protection items, `AfterFirstUnlockThisDeviceOnly`,
  never synchronizable (`SecItemKeychainBackend`, `KeychainHubKeyStore`). We reuse that backend and its
  error mapping (`errSecInteractionNotAllowed` → `locked`, never read as "absent").

## 3. Stages

Each stage can ship on its own and leaves a working product.

| Stage | Ships | User-visible |
|---|---|---|
| **1. Engine swap** | cgo SQLCipher-capable driver in Go, GRDB fork in Desktop/Kit/phone. No key: every file stays plaintext. Idle MCP connections close. | Nothing. Reads are 20–45 % faster. |
| **2. The key** | `internal/dbkey` + Swift twin, signing of the CLI as a helper bundle, `cache_size`, **new** workspaces created encrypted, `watchtower db shell`, transfer export/import, key-loss screen. | New installs are encrypted. Settings → System → Move to another Mac. |
| **3. One-time encryption** | Launch step that encrypts existing `watchtower.db` + `agentlog.db` in place (`sqlcipher_export`), crash-safe, with the 2× disk check. Plaintext leftovers listed. | A one-time "Encrypting your database…" splash (seconds). |
| **4. Around the DB** | Handled by #604 (logs, credential JSONs, memory vault, drafts, MobileHub sidecar). #603 only hands over the list in §9. | — |

Stage 2 includes transfer because a new install encrypted in Stage 2 would otherwise lose its local data
on a move to a new Mac.

## 4. Stage 1 — engine swap

### 4.1 Go driver

- **`internal/sqlcipher`**: a vendored fork of `mattn/go-sqlite3` (pinned tag, BSD/MIT notices kept).
  Its `sqlite3-binding.c/.h` are replaced by the SQLCipher **4.x community amalgamation**, pinned to the
  same version as SQLCipher.swift (4.19.0 at the time of the spike). Nothing links a system or Homebrew
  `libsqlite3`, because two SQLite copies in one process break POSIX locks on the same file.
- **cgo flags:** `SQLITE_HAS_CODEC`, `SQLITE_TEMP_STORE=2`, `SQLITE_ENABLE_FTS5`,
  `SQLITE_EXTRA_INIT=sqlcipher_extra_init`, `SQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown`, plus the
  options mattn sets today.
  - darwin: `SQLCIPHER_CRYPTO_CC` (CommonCrypto), `-framework Security -framework CoreFoundation`.
  - linux (tests and CI only): `SQLCIPHER_CRYPTO_OPENSSL`, `-lcrypto`.
- **Key API:** the fork exposes `sqlcipher.Connector{Path, Params, Key func() ([]byte, error)}`. It calls
  `sqlite3_key_v2(db, "main", "x'<64 hex>'")` right after `sqlite3_open_v2` and before mattn's own
  PRAGMAs. The raw-key form means no PBKDF2. The key never goes into a DSN string, which `sql.DB` keeps in
  memory for the pool's lifetime. `Key == nil` opens a plaintext file (all of Stage 1). The key bytes are
  zeroed after the call.
- **Pinned cipher settings:** each keyed open also runs `PRAGMA cipher_compatibility = 4` (Go and
  Swift), so a later SQLCipher default change cannot split the two sides.
- **What `internal/db` changes:**
  - **DSN.** `_pragma=busy_timeout/foreign_keys/synchronous/query_only` become mattn's
    `_busy_timeout`, `_foreign_keys`, `_synchronous`, `_query_only`; `_txlock=immediate` and `mode=rw`
    stay. `sqliteDSN`'s `?`-in-path rule is re-tested against mattn's split.
  - **Errors.** `*sqlite.Error` / `modernc.org/sqlite/lib` codes in `db.go` (FK check), `busy.go` and
    `lockmetrics/driver.go` move to `sqlite3.Error.ExtendedCode`. The lock-metrics stack-site filter swaps
    the modernc frame prefix for `watchtower/internal/sqlcipher`. The wrapper moves from wrapping a
    `driver.Driver` to wrapping a `driver.Connector`; its pinned `Event` keys stay the same.
  - **Value types.** modernc and mattn differ on `time.Time` binding/scanning (mattn parses declared
    `DATETIME`/`TIMESTAMP` columns and writes its own layout) and on `[]byte` vs `string` for TEXT. A
    parity test (`TestDriverValueParity`) pins what lands on disk for time, text, blob, bool and NULL,
    so Swift readers see the same strings as before. Any `time.Time` passed as an argument is found and
    formatted explicitly.
  - **Imports.** 3 production files and 13 test files. `modernc.org/sqlite` leaves `go.mod`.
- **Idle connections close** (`SetConnMaxIdleTime(30s)` on `watchtower mcp` and other long-lived
  non-daemon processes). An idle MCP server then holds no file handle, so the Stage 3 step and
  `db compact` stop fighting MCP servers (compaction's accepted D6 effects shrink). Shipping this in
  Stage 1 lets sessions that survive updates pick it up before Stage 3.
- **Notices.** The SQLCipher community licence goes into `THIRD_PARTY_NOTICES.md`.

### 4.2 Build, CI, release

- **`scripts/build-app.sh`:** the CLI is already `CGO_ENABLED=1` (arm64, `codegrammars`). The change is
  the C sources; the output is still static C plus system frameworks. Notarization does not change.
- **`.goreleaser.yaml`** builds `CGO_ENABLED=0` for darwin+linux × amd64/arm64. No workflow, Makefile
  target or `/release` step invokes it. **It is deleted.** There is no Linux or Intel release binary any
  more: the CLI is the Mac app's companion, and its key lives in the Mac Keychain. The `brews` tap entry
  goes with it (confirm the tap is unused before deleting).
- **Ubuntu CI jobs** (Go Test, race shards, lint, code index) build the same fork against OpenSSL
  (`libssl-dev` is on the runner image; an explicit `apt-get install` keeps that from breaking quietly).
  CI therefore tests the shipped engine and never a modernc build tag. The amalgamation compiles once
  (about 30 s) and is then cached by the Go build cache, which CI already restores.
- **`go test` locally:** the first build pays the same ~30 s; after that it is cached. No `-count=1`.

### 4.3 Swift: GRDB fork, and the Kit and phone

- **`aiwatchtowers/GRDB.swift`, branch `sqlcipher-7.x`:** GRDB 7.x with GRDB's own SPM SQLCipher recipe
  (the `GRDBSQLite` system-library target replaced by a dependency on `SQLCipher.swift`, pinned exactly),
  plus `SQLITE_ENABLE_FTS5` and `SQLITE_HAS_CODEC` defines. Upgrades: rebase on a GRDB tag, bump
  SQLCipher.swift in lockstep with the Go amalgamation, run the interop test.
- **One GRDB in the graph.** Desktop depends on WatchtowerKit, so SPM resolves one GRDB. The Kit, the
  Desktop and `WatchtowerMobile/project.yml` all point at the fork.
- **The phone does not encrypt its databases (decision).** Its replica holds E2E-sealed records
  (ciphertext replica, mobile E2E spec) under iOS Data Protection file classes in the app group, and
  `pending_actions` are sealed at enqueue. A key would add nothing there and would add an iOS Keychain
  dependency to every phone open. The phone ships SQLCipher only because SPM allows one GRDB in the
  graph, and opens its files with no key, which behaves exactly like SQLite. Expected cost: a few MB of
  binary. The same applies to the Mac hub's own `hubstate.db` / `transport.db` (sealed keys, envelopes);
  §9 lists them for #604.
- **Interop test (macOS CI job, Swift Test):** Go writes a keyed WAL file (FTS rebuild, write burst,
  VACUUM). GRDB opens it in a `DatabasePool` and runs a `kb_fts MATCH … bm25`, then writes. Go reopens
  it and reads the write. The test is repeated plaintext, and it fails on any `cipher_version` or
  `sqlite_version` mismatch between the two sides.

## 5. Stage 2 — the key

### 5.1 Key material

- **DB key:** 32 random bytes (`SecRandomCopyBytes`), one per workspace, used for both `watchtower.db`
  and `agentlog.db` (SQLCipher salts each file).
- **SE key:** a P-256 Secure Enclave key, `kSecClassKey`, `kSecAttrTokenIDSecureEnclave`, permanent,
  `kSecAttrApplicationTag = com.watchtower.dbkey.se.<key_id>`. Access control
  `AfterFirstUnlockThisDeviceOnly` + `.privateKeyUsage`: no user presence, usable while the screen is
  locked.
- **Wrapped DB key:** a generic password, service `com.watchtower.dbkey`, account `<key_id>`,
  value = `SecKeyCreateEncryptedData(SE pub, eciesEncryptionCofactorVariableIVX963SHA256AESGCM, DB key)`,
  `AfterFirstUnlockThisDeviceOnly`, never synchronizable.
- **Both items** sit in the data protection keychain, in one access group (§5.3).
- **Why `SecKey` and not CryptoKit:** Go needs the same operation from C, so both sides call the same
  Security.framework C API. Go (cgo, `internal/dbkey`) and Swift (`DatabaseKeyStore` in WatchtowerCore,
  on the Kit's `SecItemKeychainBackend`) are a dual path. Item names, the algorithm and the sidecar format
  are pinned by a shared fixture test.
- **Sidecar `<workspace>/dbkey.json`** (0600, no secret): `{"format":1,"key_id":"…","kind":"mac"|"dev",
  "created_at":"…"}`. It lets an opener tell "encrypted, key missing" from "wrong key" and "plaintext",
  and lets Desktop show the right screen. A plaintext database has no sidecar (and starts with the
  `SQLite format 3` header).
- **Read path** (each new connection; the result is cached for the process's life): stat the
  sidecar → `SecItemCopyMatching` (wrapped key) → `SecItemCopyMatching` (SE key ref) →
  `SecKeyCreateDecryptedData` → `sqlite3_key_v2`. About 6 ms in total; the daemon pays it once.

### 5.2 Who creates the key

The first Watchtower process that needs an encrypted database that does not exist creates it, under the
flock `<workspace>/dbkey.lock`, and re-reads after taking the lock so two racing processes never mint two
keys. In practice that is `db.Open` on a fresh workspace (onboarding's `workspace init`) or the Stage 3
step. **No process ever creates a new key while an encrypted database with a sidecar exists**: that is
the key-loss path (§8), never an automatic re-key.

### 5.3 Access without prompts: app, CLI, daemon, MCP, hooks

Every opener is one of two executables: `Watchtower.app` (the Desktop and its GRDB) and the `watchtower`
CLI (daemon, MCP servers, hooks, session host, one-off commands). The session host never opens the
database and needs no key.

- **Data protection keychain access needs a provisioning profile.** It needs a
  `com.apple.application-identifier` entitlement, which a provisioning profile has to authorize. A bare
  Mach-O cannot embed a profile, so **the CLI becomes a helper bundle:**
  `Watchtower.app/Contents/Helpers/Watchtower CLI.app/Contents/MacOS/watchtower`. It embeds the same
  Developer ID profile as the app and carries entitlements `com.apple.application-identifier =
  <TEAM>.com.watchtower.desktop` and `keychain-access-groups = [<TEAM>.com.watchtower.desktop]`, merged
  at sign time the way `app-codesign` already merges them for the app. The team id is never written in
  the repo.
- **One group, already owned.** The app's default group, `<TEAM>.com.watchtower.desktop`, already holds
  the hub's E2E keys. No new App ID, profile or capability is needed. The CLI reading the hub's group is
  within the same trust domain.
- **`CLIBinaryStore`** copies the whole helper bundle to
  `~/Library/Application Support/Watchtower/bin/Watchtower CLI.app`, and makes `bin/watchtower` a
  symlink to the inner executable. Hook and MCP command lines therefore do not change. Its SHA-256 and
  team-ID checks move to the bundle.
- **Updates.** The access check is the entitlement plus the team signature, so an update needs nothing
  and prompts for nothing. This is the #567 rule.
- **Locked screen.** Both items are `AfterFirstUnlock`: readable from the first login after boot until
  shutdown, including while the screen is locked.
  `errSecInteractionNotAllowed` (before the first unlock) maps to `dbkey.ErrLocked`. Callers then react
  as follows:
  - the daemon skips the cycle and retries;
  - hooks fail the way their contracts already say for an unopenable database (fail-open guards);
  - the Desktop does not run before login anyway.
- **Gate before Stage 2 code (prototype on a notarized build).** Each check has a fallback if it fails:
  - **G1.** The helper-bundle CLI reads the group through the symlink, with no prompt.
    Fallback: a second App ID `com.watchtower.cli` with a shared group `<TEAM>.com.watchtower.shared`.
  - **G2.** It also reads the group from a `setsid`-detached process while the screen is locked.
  - **G3.** The SE key created by the app is used by the CLI.
  - **G4.** A re-signed update keeps access with no prompt.
  - **G5.** An ad-hoc build gets `errSecMissingEntitlement`, with no prompt and no file-keychain item.
  - **Last resort if G1/G4 fail outright:** the daemon or session host serves the key over its socket
    to callers whose audit token passes a team-ID code check. It is not designed further unless needed.

### 5.4 Unsigned dev builds

Dev builds (`make app-dev`, `swift run`, `go run`, `go test`, a Developer ID build without the profile)
have no access group. They get the **`dev` key kind**:

- The key is a random 32-byte file `<workspace>/dbkey.dev` (0600). There is no SE wrap and no Keychain.
  The sidecar says `"kind":"dev"`.
- The same code paths run (encrypted file, raw key, `cache_size`), so dev builds exercise encryption.
- **A build without the entitlement never opens a `mac` database.** It fails with: "This database is
  locked to the signed Watchtower app on this Mac. Use the installed app, or point this build at its own
  workspace." This also enforces the existing "no dev CLI on the live DB" rule.
- A signed build opens a `dev` database as it is. `db key status` reports it as "dev key, not bound to
  this Mac". It is never re-keyed automatically, because dev workspaces flip between builds. (Q1)
- **Tests:** `go test` and Swift tests stay mostly plaintext. A small set opens keyed files with a fixed
  test key through the same Connector, plus the dev provider. The phone and the Kit tests are unchanged.

### 5.5 `cache_size` (the 4–5× full-scan penalty)

Encrypted pages served from the OS cache are decrypted again on every read, about 1 ms per MB. Pages in
SQLite's own cache cost the same as plaintext. The cache is allocated lazily, so a large limit costs only
the pages actually touched.

| Connection | `PRAGMA cache_size` |
|---|---|
| Daemon (`sync --daemon`, one-connection pool) | `-min(max(db_bytes, 64 MiB), 512 MiB)` in KiB, set at open |
| `watchtower mcp`, one-off CLI commands | 64 MiB |
| Hooks (`OpenExisting`, point reads) | default 2 MiB (unchanged) |
| Desktop GRDB writer and each reader (`prepareDatabase`) | 64 MiB |

Stage 2 measures the result on a copy of a real install, with one full daemon cycle and the Desktop's
inbox/search screens. The bar is the inbox-mentions, linkscan and channel-stats scans within 1.2× of
today's modernc numbers. If the bar is missed, the hot LIKE scans become incremental (only rows newer
than the last run) as a follow-up, and the cache is not raised further. Plaintext databases in Stage 2
keep today's sizes.

### 5.6 New workspaces are encrypted

From Stage 2, `db.Open` on a path that does not exist creates the key (§5.2) and an encrypted file, and
so does `OpenSidecar` for `agentlog.db`. Existing plaintext files keep opening as plaintext until Stage 3.
The opener decides per file: no sidecar means plaintext, `kind` picks the provider.

### 5.7 `watchtower db shell`

`sqlite3` cannot read the file any more, so the CLI gets a small shell. It is not a full `sqlite3`
clone.

- `watchtower db shell [--write] [--file PATH] [-c SQL | < file.sql] [--json|--tsv]`. It opens the
  workspace database with its key, read-only (`query_only`) unless `--write` is given.
- **Interactive mode:** statements end with `;` and print as an aligned table. Dot-commands: `.tables`,
  `.schema [table]`, `.mode table|tsv|json`, `.timer on|off`, `.quit`.
- **`--file`** opens another Watchtower database. The kind is read from the sidecar next to it, or a
  transfer file asks for its passphrase on the TTY. This covers debugging on a DB copy.
- **Under an agent:** read-only use works (agents debug with it, as they use `sqlite3 -readonly` today).
  `--write` is refused when the automation/agent markers are set, the same rule as `approve` refused
  under an agent.
- **Docs move from `sqlite3 -readonly` to `watchtower db shell`:** CLAUDE.md, `.claude/skills`, the
  dev notes, and `docs/guide` where it mentions the file.

### 5.8 Move to a new Mac: transfer export and import

A `ThisDeviceOnly` key does not travel, by design. Migration Assistant or a Time Machine restore brings
over the ciphertext and the sidecar, but not the key. Data that cannot be synced again (boards, asks,
chats, automations, transcripts, memory) has to move by an **explicit export with re-encryption**.

- **Export:** `watchtower db transfer export [--out PATH]`, and in the Desktop, Settings → System →
  **Move to another Mac…**.
  - It generates a passphrase: 24 base32 characters in groups of four (120 bits), shown once with
    **Copy**.
  - It writes **one file**, `Watchtower-<date>.wttransfer`: a SQLCipher database keyed with that
    passphrase (SQLCipher's own PBKDF2-HMAC-SHA512 KDF).
  - Contents:
    - all of `watchtower.db`, through `ATTACH … KEY` + `sqlcipher_export`, inside one read transaction,
      so it reads a WAL snapshot and the daemon does not need to stop;
    - `transfer_meta` (format 1, CLI version, goose version, Mac name, created_at);
    - `transfer_files(path, mode, mtime, data)`: the workspace files that hold owner data (memory vault,
      automation recipes and drafts, recordings that transcripts point at). One Go list,
      `transfer.Included`, with a guard test against #604's file inventory.
  - Left out:
    - credentials and tokens: the owner reconnects accounts, and cursors are kept, so nothing is synced
      again;
    - logs, caches, `dblock.jsonl`;
    - the MobileHub sidecar: phones re-pair, because the hub identity is device-bound;
    - `agentlog.db`: it is rebuilt from the Claude Code transcripts by `agents scan`.
  - The export checks free disk first (≈ DB size + files).
- **Import:** on the new Mac, onboarding's first screen offers **Moving from another Mac? Import…**, or
  `watchtower db transfer import FILE`.
  1. Refuse if a database exists, unless `--replace`, which moves the existing one aside and never
     deletes it.
  2. Ask for the passphrase. A wrong one fails with `file is not a database`, and the message says
     "wrong passphrase".
  3. Check the format, and that the goose version is not newer than this binary's; otherwise "update
     Watchtower first".
  4. Create this Mac's key (§5.2).
  5. `sqlcipher_export` into `watchtower.db.importing`, verify it (§6.2), and rename it into place.
  6. Write the files.
  7. Run the migrations.
  8. Accounts show the existing "reconnect" state, because their tokens are absent.
  9. Offer to delete the transfer file.
- The same file is also the owner's **manual backup** on the same Mac (§8).

## 6. Stage 3 — one-time encryption of existing installs

### 6.1 Where it runs

The step goes into the Desktop launch sequence, next to compaction:
**migrate → encrypt → compact → open → daemon**. It is `watchtower db encrypt --if-due --json`, with the
same exit-code and JSON-last-line conventions as `db compact` and the same splash with **Skip for now**
at 15 s.

- **Due when:** `watchtower.db` or `agentlog.db` starts with `SQLite format 3\0`, or a crash leftover
  exists (§6.3). It is never due on a dev-kind or an unsigned build (G5 → the step reports
  `skipped: no_keychain`).
- **The daemon stops first** (bounded stop, `databaseCompactionInProgress`-style start gate). The Desktop
  has not opened the database yet.
- **Disk:** at least 2 × (`db_bytes` + `wal_bytes`) must be free on the volume (compaction's
  `freeDiskBytes`). If not, the step is skipped with a notice, as compaction's D3 does, and stays due.
- **No other process may hold the file.** `PRAGMA wal_checkpoint(TRUNCATE)`, then
  `PRAGMA journal_mode=DELETE`. Leaving WAL needs exclusive access and fails while any other connection
  is open anywhere. On failure the step is skipped with `skipped: in_use` and a notice: "Some Claude Code
  sessions started before this update keep the database open; restart them to finish encryption."
  Thanks to Stage 1's idle close, current MCP servers hold no handle while idle.
- **SIGTERM** interrupts the export (`sqlite3_interrupt`). The temp file is removed, and the step stays
  due.

### 6.2 Steps (per file: `watchtower.db`, then `agentlog.db`)

1. Hold `locking_mode=EXCLUSIVE` and `BEGIN EXCLUSIVE` on the source. A hook arriving in the next ~2 s
   waits its 500 ms / 1 s and fails open; that is accepted, as in compaction.
2. `ATTACH 'watchtower.db.encrypting' KEY x'…'` → `sqlcipher_export('enc')` → `user_version` copied →
   `DETACH`.
3. Open the new file with the key and verify: `PRAGMA cipher_integrity_check`, `PRAGMA quick_check`,
   the same goose max version, the same `sqlite_master` count, and the same `count(*)` on a few big
   tables. Then set `journal_mode=WAL` and `fsync`.
4. `renameatx_np(RENAME_SWAP)` swaps the two names atomically, then `fsync` the directory.
5. Write `dbkey.json` (only after the swap of `watchtower.db`; the key itself already exists) and delete
   the swapped-out plaintext file and its `-wal`/`-shm`. Record `last_compacted_version` in
   `db_maintenance`: the export is a fresh copy, so compaction is not due straight after.

### 6.3 Crash safety and rollback

Every state is recognisable from the files alone. The step runs again from the state it finds:

| Found | Meaning | Action |
|---|---|---|
| `watchtower.db` plaintext + `.encrypting` | crashed before the swap | delete `.encrypting`, redo |
| `watchtower.db` encrypted + `.encrypting` plaintext | crashed after the swap | delete the plaintext, write the sidecar if missing |
| `watchtower.db` encrypted, no sidecar, key in Keychain | crashed before the sidecar | write the sidecar (key_id from the only `com.watchtower.dbkey` item) |

The plaintext original exists until the verified encrypted file has taken its name, so no state loses
data.

- **Rollback:** a binary from before Stage 2 cannot open an encrypted file. Problems in Stage 3 are fixed
  forward, never by a downgrade. Stage 1 and 2 binaries already carry the SQLCipher engine, so a
  downgrade to them still opens the file once they have the key. The release notes of the Stage 3
  version say that older versions cannot read the database.

## 7. Interaction with #601 (revoke purge, lease)

#601's "Later" note says that with #603 the lease could lock by withholding the key. This design does not
do that in v1:

- **It would be policy, not cryptography.** Any binary in our access group can read the key. "Withholding"
  would only mean our own code refusing to open the database, and our own code can already refuse
  without a key change.
- **It is too coarse.** One key covers the whole database, while a lease is per source account. Locking
  everything because one corp account's lease ran out would also lock owner data (boards, memory).
- **So #601 keeps purge on lease expiry.** A real cryptographic lease (a key share released by a corp
  service) belongs with #608's corporate policy, if it is ever needed. #601's "Later" line should be
  updated to say this.

## 8. Key loss and recovery

**When the key is lost:**

- a new Mac or a Migration Assistant / Time Machine restore to a different Mac;
- an erase or reinstall of macOS;
- the owner deleting the item in Keychain Access;
- a Secure Enclave reset.

A login password change does not lose it.

**What happens then:**

- The opener finds an encrypted file and a `kind: "mac"` sidecar, but no item or no SE key. It returns
  `dbkey.ErrKeyMissing`, which is distinct from `ErrLocked` and from a wrong key.
- The Desktop shows one blocking screen: "Watchtower can't unlock its database on this Mac." It offers:
  - **Import a transfer file…** (§5.8);
  - **Start fresh**, which renames the files to `watchtower.db.unreadable-<date>` (never deleted, in
    case the key comes back) and runs onboarding;
  - **Quit**.
- The daemon and the CLI fail with the same message and exit non-zero. Hooks fail open.
- **Recovery is the transfer file only.** There is no escrow, no iCloud Keychain and no recovery key in
  v1: anything that can recover the key off this Mac weakens "a copy is ciphertext". Whether Watchtower
  should write transfer backups on its own is Q3.

## 9. Plaintext copies around the database (list only — #604 decides)

Owned by #603 (handled in Stage 3):

- **`watchtower.db.bak-*` and other plaintext SQLite copies beside the database.** No code here writes
  them, but installs have them (one held 586 MB). The step finds them by the `SQLite format 3` header
  and does not delete them silently (Q4).
- **The step's own leftovers** (`.encrypting`, the swapped-out plaintext, `-wal`/`-shm`), handled by
  §6.3.
- **`agentlog.db`**, encrypted with the same key in Stage 3. The emptied legacy 00116 tables sit inside
  `watchtower.db` and are therefore encrypted.

For #604 (not designed here):

- `daemon.log`, `watchtower.log`, `sessions.log`, `session-host.log`, `dblock.jsonl`;
- per-account credential and token JSON files;
- the memory vault and automation drafts (`automation-drafts/`);
- recordings and transcript files outside the database;
- the MobileHub sidecar (`hubstate.db`, `transport.db`, `SliceAssets/`);
- the `dbkey.dev` file of dev workspaces;
- the transfer file itself is already encrypted.

Outside our control, said in the guide: Time Machine, APFS local snapshots, freed SSD blocks, and copies
the owner made.

## 10. Test strategy

- **Stage 1 (Go):**
  - the whole existing suite on the new engine, on Linux CI (OpenSSL) and macOS locally;
  - `TestDriverValueParity` (§4.1);
  - lockmetrics `busy`/`tx` event tests with mattn error codes;
  - the `?`-in-path DSN test;
  - FTS5, JSON1 and `bm25` smoke tests;
  - a VACUUM of a plaintext file through SQLCipher, the spike's footnote 1, as a regression test,
    investigated before Stage 1 ships.
- **Stage 1 (Swift):** the whole Desktop and Kit suites on the fork, the Go↔Swift interop test (§4.3)
  in the macOS CI job, and `make mobile-test`.
- **Stage 2:**
  - `internal/dbkey` with a fake Security backend: create under the lock (two racing creators → one
    key), read, `ErrLocked`, `ErrKeyMissing`, no file-keychain fallback (asserted on the query
    dictionary, as `SecItemKeychainBackend.addAttributes` is tested);
  - a Go↔Swift fixture test on item names, the sidecar and ECIES (a blob made on one side opens on the
    other with an in-memory SE stand-in);
  - the dev provider; a refused `mac` DB on a build without the entitlement;
  - `db shell` (`-c`, `--json`, refused `--write` under an agent);
  - a transfer round-trip: export → import into an empty workspace → the same rows and files, a wrong
    passphrase, a newer schema refused, `--replace` keeps the old database;
  - the `cache_size` measurement (§5.5), recorded in the plan;
  - manual G1–G5 checks on a notarized build, kept in the feature note.
- **Stage 3:**
  - `db encrypt` table tests for each crash state in §6.3, done with seams that stop between steps;
  - the disk rule, `in_use` (a second connection open → skipped, nothing written), SIGTERM;
  - the verification failure path (a corrupted export → no swap);
  - rowids preserved (the `TestCompact_PreservesRowids` shape);
  - one run on a copy of a real install (never on the live file).
- **Tests that spawn processes** (the in_use probe holder, hooks during the exclusive window) reap their
  process group, per CLAUDE.md.

## 11. Simplification cuts

- **One key per workspace**, shared by both database files: no per-file keys or derivation.
- **No rotation in v1.** The SE wrap could rotate the wrapping key without rewriting data, but nothing
  asks for it; `PRAGMA rekey` stays unused.
- **No escrow, no recovery key, no iCloud.** The transfer file is the only way out.
- **No plaintext export or `db decrypt`.** Support uses `db shell`, and downgrades are fixed forward.
- **No database split.** Session state stays in `watchtower.db`; the spike showed hooks are fine.
- **The phone and the hub sidecar stay unkeyed**; they already hold sealed data.
- **No Linux or Intel release binary.** goreleaser is deleted rather than ported to cgo cross-builds.
- **No full `sqlite3` clone**: about six dot-commands.
- **No lease lock** (§7).
- **`agentlog.db` is not transferred**; it is rebuilt.
- **No key broker or socket** unless gate G1/G4 fails.
- **Encryption doubles as compaction** on the day it runs.

## 12. Open questions for the owner

**Q1. Dev builds (unsigned / no profile).**

- (a) A `dev` key file in the workspace (0600, no SE), the same encrypted code path, and dev builds
  refused on a `mac` database.
- (b) Dev builds keep plaintext databases.
- (c) Dev builds must be signed with the profile.

**Recommendation: (a).** It tests the real path and keeps dev builds off the live database.

**Q2. Keep the Secure Enclave wrap?** A `ThisDeviceOnly` data protection item is already protected by
class keys held in the Secure Enclave on Apple silicon. The extra SE key adds about 4.5 ms per open and
a second Keychain object.

- (a) Keep it, as #603 says: a stolen copy of the Keychain database is useless off this SE.
- (b) Cut it: the plain `ThisDeviceOnly` item only.

**Recommendation: (a).** It is cheap and is what CASA reviewers expect to read.

**Q3. Automatic backups, given there is no recovery key.**

- (a) Manual only: the transfer file, made when the owner asks.
- (b) A weekly transfer backup to a folder the owner picks, under a passphrase shown once at setup.
- (c) None, and the guide warns.

**Recommendation: (a) in v1, with a one-time notice after Stage 3**: "Your database is now tied to this
Mac. Make a transfer file before you replace it." (b) can come later if asked.

**Q4. Old plaintext `.bak` copies found beside the database.**

- (a) The encryption notice lists them, with **Delete N plaintext backups (size)**.
- (b) Delete them automatically during the step.
- (c) Leave them alone, and only say so in the guide.

**Recommendation: (a).** They hold everything the encryption protects, but they are the owner's files.

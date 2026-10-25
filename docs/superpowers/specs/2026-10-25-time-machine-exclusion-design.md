# Watchtower data stays out of Time Machine — design (board #605)

Part of board group #595 (corporate data on the Mac must not be easy to carry
away). Status: approved by the owner 2026-10-25 (ask #574) with the
recommended answer to every question: Q1 (a) everyone, always, no switch;
Q2 (a) the data folder, Application Support/Watchtower and a custom
recordings folder, settings stay in backups (narrowed at the final-PR review
to two folders: no recorder honours a custom recordings folder, see §2);
Q3 (a) the guide says how to
delete old backups, nothing automatic. New inventory entry BACKUP-01 is
approved with it. Plan:
`docs/superpowers/plans/2026-10-25-time-machine-exclusion.md`. Siblings: #601
(revoke purge, `docs/superpowers/specs/2026-10-21-revoke-purge-design.md`),
#603 (database encryption, `docs/superpowers/specs/2026-10-21-db-encryption-design.md`,
Stage 1 merged: engine only, every file still plaintext), #604 (files outside
the database, `docs/superpowers/specs/2026-10-25-files-outside-db-design.md`).

## Goal

Time Machine copies everything Watchtower writes to a backup disk: the
database and its `-wal`, the memory vault, meeting audio, logs, tokens. That
disk is often unencrypted, gets plugged into other Macs and stays with the
person after they leave the company. After this change Time Machine skips
Watchtower's data folders as a whole, and the app puts the exclusion back by
itself whenever a folder is recreated.

Out of scope: other backup tools (Backblaze, Arq, Carbon Copy Cloner, corporate
backup agents: some honour the same flag, most have their own lists, and #608's
MDM profile can add paths for them), iCloud Drive (none of our folders sits in
it), APFS local
snapshots (whole-volume, on the same FileVault disk, kept ≤ 24 h), and backups
made before this change (see Q3).

## What exclusion adds, before and after #603

- **Now (every file plaintext).** Exclusion is the only thing that keeps a
  readable copy of the company's correspondence off the backup disk. It also
  stops the plaintext history that #603 §1 says it will not scrub from growing
  further, so it should ship before #603 Stage 3, not with it.
- **After #603 Stage 2/3.** `watchtower.db` and `agentlog.db` are ciphertext
  under a `ThisDeviceOnly` key that no backup carries, so their backup copy is
  already useless off this Mac. Exclusion still covers:
  - files outside the database until #604 lands, and #604's permanent
    plaintext exceptions (workchat attachments, target images, the audio file
    while a recording runs, token files if its Q4 is (c));
  - the `*.db.bak-*` plaintext copies beside the database (#603 Q4);
  - defence in depth if a key ever leaks;
  - side benefit: an hourly backup no longer re-copies a 0.5 GB database
    whose WAL changes every sync cycle.
- **What it costs.** A Time Machine copy of the encrypted database restores
  only on the same Mac with the Keychain item intact (rolling one file back).
  A new Mac, an erase or a Migration Assistant restore loses the key (#603 §8)
  and needs the transfer file anyway. Before #603 Stage 2 a personal install
  does lose a real safety net for data that cannot be synced again (boards,
  asks, chats, memory, transcripts); see Q1.

## Where the data lives

`<root>` = `config.DataRoot()` = `~/.local/share/watchtower`, `<as>` =
`~/Library/Application Support/Watchtower`.

| Folder | What is in it | Created by |
|---|---|---|
| `<root>/<workspace>/` | `watchtower.db` + `-wal`/`-shm`, `agentlog.db`, `*.db.bak-*`, `memory/` (+ `.git`), `chat_files/`, `project_files/`, `workchat-attachments/`, `automation-drafts/`, `tmp/extract/`, `watchtower.log`, `daemon.log`, `sessions.log`, `dblock.jsonl`, `*_token.json` and other credential files, stamp/pid files | Go: `workspace init` (`cmd/workspace.go`), `db.Open`/`OpenSidecar` (`MkdirAll`), every writer under it |
| `<as>/recordings/` | Meeting audio, transcript sidecars, `.meta` | Swift: `MeetingRecorderCenter`, `SystemAudioRecorder` |
| `<as>/MobileHub/` | `hubstate.db`, `transport.db`, `SliceAssets/`, `transport-assets/` | Swift: `MobileHubService`, `HubSyncState`, `TransportStore` |
| `<as>/` itself | `session-host.log`, `bin/` (the CLI copy), `code-languages.yaml` | Swift: `SessionHostClient`, `CLIBinaryStore`, `CodeIndexCenter` |
| `~/.config/watchtower/` | `config.yaml` (settings, workspace names; no tokens) | Go: `workspace init` |

Already outside Time Machine by Apple's standard exclusions: `$TMPDIR`
(`wt-*`, `watchtower-*` temp files) and `~/Library/Caches`. Not ours and not
covered: UserDefaults (`~/Library/Preferences/<bundle>.plist`, rewritten by
`cfprefsd` on every change, so an exclusion would not stick; #604 S15/S16 move
its content out), the Claude CLI's `~/.claude/projects` (#604 G11), the owner's
repositories and worktrees, owner exports.

## Design

### 1. Mechanism: the sticky item exclusion, written from Go

Time Machine skips an item that carries the extended attribute
`com.apple.metadata:com_apple_backup_excludeItem` (a binary plist holding the
string `com.apple.backupd`). It is what `tmutil addexclusion <path>` (no `-p`)
and `NSURLIsExcludedFromBackupKey` / `CSBackupSetItemExcluded(url, true,
false)` write. On a folder it covers everything inside, including files created
later. It survives a rename on the same volume; it is lost when the folder is
deleted and recreated, copied by a tool that drops attributes, or restored.

Options weighed:

| Option | Verdict |
|---|---|
| Write the attribute with `unix.Setxattr` (`golang.org/x/sys`, already in `go.mod`) | **Chosen.** No cgo, no subprocess, no root, idempotent, darwin-only file |
| `CSBackupSetItemExcluded` via cgo + CoreServices | Same attribute, one more framework link for one call |
| `tmutil addexclusion <dir>` subprocess | Same attribute; a process spawn and a PATH dependency per start. Kept as the test oracle (`tmutil isexcluded`) |
| `tmutil addexclusion -p` / Time Machine `SkipPaths` | Path-based, needs root; it is the MDM's tool (#608), not ours |
| `URLResourceValues.isExcludedFromBackup` in Swift | Not needed: the Desktop's launch already runs `watchtower db migrate` (`DatabaseManager.runCLIMigrations`) before it opens anything, so Go covers the app launch too. One implementation, no Go↔Swift dual path |

The exact bytes are the ones `tmutil addexclusion` writes, captured once at the
start of the implementation (`xattr -px` on a temp folder) into a test fixture.

### 2. What is excluded

One function, `backupexclude.Apply(dirs []string) []error`
(`internal/backupexclude`, darwin build tag; a no-op elsewhere), over:

1. `<root>` — every workspace, current and future, as a whole;
2. `<as>` — recordings, MobileHub, logs; created `0700` on macOS if missing so
   a recording made before the daemon's first start is covered too.

Two folders only. `transcripts.recordings_dir` is not excluded: the Desktop
recorder (`MeetingRecorderCenter`) never reads it and always writes
`<as>/recordings`, so excluding the configured path would cover nothing real
and add a lexical-path/symlink hole.

`~/.config/watchtower/` stays in backups (Q2): it holds mostly settings (an
unmigrated config can still carry a legacy `slack_token`), and is the one
thing worth restoring on a new Mac.

For each folder: resolve symlinks (`<root>` may be one, see
`TestWorkspaceDirsWithDatabase_FollowsSymlinks`), read the attribute, and set it
only when it is missing or differs. Folders are never created other than `<as>`.

### 3. When it runs

Re-applied on every start, because a recreated folder loses the attribute:

- `watchtower workspace init`, right after it creates the workspace folder;
- `watchtower db migrate` — the Desktop runs it at every launch;
- the daemon's start (`runSyncDaemon`, `cmd/sync.go`), so a CLI-only install is
  covered too.

Hooks, MCP servers and other commands do not call it: three entry points cover
every install, and the check is a `getxattr` per folder (microseconds).

A failure (an exotic filesystem, a folder owned by someone else) never fails
the command: it is logged to stderr as `backup exclusion: <dir>: <err>`
and the next start tries again.

### 4. What the owner sees

Nothing in the app. The guide's privacy page (`docs/guide/concepts/privacy.md`)
gains a short section: Watchtower keeps its data out of Time Machine; backups
made before version X still hold it (how to delete them, Q3); the way to move
to a new Mac is the transfer file (#603 §5.8) once it exists. Users of other
backup tools are told which two folders to exclude by hand.

## Tests

- `TestBackup01_DataRootsExcluded` (darwin): a temp `HOME`; after `Apply` each
  folder reads back the fixture bytes and `tmutil isexcluded` prints
  `[Excluded]` (skipped when `tmutil` is absent); a second `Apply` writes
  nothing; a deleted and recreated folder is excluded again; a symlinked
  `<root>` excludes its target.
- `cmd` tests: `workspace init`, `db migrate` and the daemon start call `Apply`
  with the two folders (a seam, no real attribute); a failing `Apply` does not
  change the command's exit code.
- New inventory entry **BACKUP-01** (the three entry points exclude `<root>` and
  `<as>`; the setting of Q1 if one is chosen).

## Questions for the owner

- **Q1. Who has it on** — (a) everyone, always, no switch (recommended: the
  simplest; after #603 Stage 2 a backup of the database does not restore off
  this Mac anyway, and a personal install's work data is usually company data
  too); (b) on in the corp build and under MDM, opt-in elsewhere through #601's
  `purge.Enabled`-style seam; (c) everyone, with an off switch in Settings →
  System → Privacy that removes the attribute.
- **Q2. Which folders** — (a) the data folder, Application Support/Watchtower
  and a custom recordings folder; settings stay in backups (recommended); (b) as
  (a) plus `~/.config/watchtower`; (c) only the database folder.
- **Q3. Backups made before** — (a) the guide says how to delete Watchtower's
  folders from old backups, nothing automatic (recommended: deleting needs
  root or Full Disk Access); (b) a one-time notice in the app with the same
  steps; (c) nothing.

## Later

- #608: the MDM profile adds the same folders as path exclusions (root-level,
  survives recreation) and covers third-party backup agents.
- If #604 leaves any plaintext exception in a folder outside these two, it
  joins the `Apply` list.
- A configurable recordings folder must first be honoured by the recorder;
  then the exclusion applies to its resolved target.

# Watchtower data out of Time Machine (2026-10-25, board #605)

- **Why.** Time Machine copied everything Watchtower writes — the database and its `-wal`, the memory vault, meeting audio, logs, sign-in files — to a backup disk that is often unencrypted, gets plugged into other Macs and stays with the person after they leave. Part of board group #595 (corporate data must not be easy to carry away). Before #603 Stage 2 this is the only thing keeping a readable copy off that disk; afterwards it still covers files outside the database, the `*.db.bak-*` copies and defence in depth.
- **Who.** Everyone, always, no switch, no setting, no UI (owner, ask #574 Q1 (a)). Inventory: [BACKUP-01](../inventory/backup.md).
- Design: `docs/superpowers/specs/2026-10-25-time-machine-exclusion-design.md`; plan: `docs/superpowers/plans/2026-10-25-time-machine-exclusion.md`.

## Mechanism

`internal/backupexclude.Apply(dirs) []error` writes the sticky item exclusion: the extended attribute `com.apple.metadata:com_apple_backup_excludeItem` (`backupexclude.Attr`), the same one `tmutil addexclusion <path>` (no `-p`) and `NSURLIsExcludedFromBackupKey` write. On a folder it covers everything inside, files created later included. It survives a rename on the same volume and is lost when the folder is deleted and recreated, copied by a tool that drops attributes, or restored.

- **Bytes.** The value is the binary plist `tmutil addexclusion` writes (the string `com.apple.backupd`), captured once with `xattr -px` into `internal/backupexclude/testdata/excludeitem.bin` and embedded: the test fixture is the production value.
- **Per folder:** `filepath.EvalSymlinks` first (a symlinked data root gets the attribute on its target, never on the link); a folder that does not exist is skipped silently and never created; `unix.Getxattr`, then `unix.Setxattr` only when the value is missing or differs (an older tool's value is rewritten once). Each failing folder yields one `"<dir>: <err>"` error; the others still run.
- **darwin only.** `backupexclude_darwin.go` holds the code; `backupexclude_other.go` is a no-op, so Linux CI builds. No cgo, no subprocess, no root. `tmutil isexcluded` is only the test oracle.

## Folders

`cmd/backup_exclude.go` `backupDirs()` — two folders:

1. `config.DataRoot()` = `~/.local/share/watchtower` — every workspace, current and future;
2. `config.AppSupportDir()` = `~/Library/Application Support/Watchtower` — recordings, `MobileHub/`, `session-host.log`, `bin/`; `applyBackupExclusion` creates it `0700` (`fsutil.MakePrivateDir`, on macOS only) so a recording made before the daemon's first start is covered.

`transcripts.recordings_dir` is not excluded: the Desktop recorder (`MeetingRecorderCenter`) does not read it and always writes `<as>/recordings`; only the daemon's orphan cleanup scans it.

`~/.config/watchtower` stays in backups (Q2 (a)): mostly settings and workspace names (an unmigrated config can still hold a legacy `slack_token`), and the one thing worth restoring on a new Mac.

## Entry points

`applyBackupExclusion()` runs on every start (a no-op off macOS: nothing written, no folder created), because a recreated folder loses the attribute:

- `watchtower workspace init` (`initWorkspace`), right after it creates the workspace folder;
- `watchtower db migrate` — the Desktop runs it at every launch (`DatabaseManager.runCLIMigrations`), so no Swift code is needed;
- the daemon start (`runSyncDaemon`), for a CLI-only install.

Hooks, MCP servers and other commands never call it. The check is one `getxattr` per folder.

**Failures** (exFAT/SMB data root answering `ENOTSUP`, a folder owned by someone else) never change the exit code. Each is written to stderr as `backup exclusion: <dir>: <err>` (each process calls it once); the next start tries again. The Desktop reads `db migrate`'s stderr only on a non-zero exit, so a launch failure stays silent there; the daemon start re-applies and logs to `daemon.log` (its stderr). Seams for tests: `backupExcludeApply`, `backupExclusionStderr`, `backupExclusionGOOS`; the cmd `TestMain` stubs the Apply seam so no cmd test writes a real attribute.

## Not covered

- Other backup tools (Backblaze, Arq, Carbon Copy Cloner, corporate agents): some honour the flag, most keep their own lists; the guide tells the owner which two folders to exclude by hand.
- Backups made before this change: the guide gives the deletion steps (Q3 (a)); nothing automatic. Time Machine's **Delete All Backups of "…"** exists only on HFS+ backup disks (`tmutil delete -p` is HFS-only too); an APFS backup disk (the default since macOS 11) deletes whole backups only (`sudo tmutil delete -d <disk> -t <timestamp>`, root and Full Disk Access), so the guide offers that or erasing the disk.
- APFS local snapshots (whole-volume, on the FileVault disk, kept ≤ 24 h), UserDefaults (`cfprefsd` rewrites the plist, so an exclusion would not stick; #604 moves its content out), the Claude CLI's `~/.claude/projects`, the owner's repositories and worktrees.

## Later

- #608: the MDM profile adds the same folders as root-level path exclusions (they survive recreation) and covers third-party backup agents.
- A plaintext folder #604 leaves outside these two joins `backupDirs`.
- A configurable recordings folder must first be honoured by the recorder; then the exclusion applies to its resolved target.

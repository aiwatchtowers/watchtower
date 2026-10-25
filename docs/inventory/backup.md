# Behavior Inventory — Backup exclusion

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when changing where Watchtower writes its data, adding a
> data folder, or touching `workspace init`, `db migrate` or the daemon
> start, read this file first. Any proposed change that would break a guard
> test or remove a contract must be raised as a question before touching
> code.

**Module:** `internal/backupexclude/`, `cmd/backup_exclude.go`, `cmd/workspace.go`, `cmd/db.go`, `cmd/sync.go` (`runSyncDaemon`), `internal/config/config.go` (`AppSupportDir`)
**Last full audit:** 2026-10-25

## BACKUP-01 — Watchtower's data folders stay out of Time Machine

**Status:** Enforced

**Observable:** `watchtower workspace init`, `watchtower db migrate` (the Desktop runs it at every launch) and the daemon start set the Time Machine item exclusion (the `com.apple.metadata:com_apple_backup_excludeItem` attribute `tmutil addexclusion` writes) on `~/.local/share/watchtower`, on `~/Library/Application Support/Watchtower` (created `0700` when missing) and on `transcripts.recordings_dir` when it lies outside the latter. It applies to every install, with no switch. Symlinks are resolved first, so a linked folder's target is excluded. A failure never fails the command: it is logged once per process as `backup exclusion: <dir>: <err>`, and the next start tries again. `~/.config/watchtower` is not excluded (settings stay in backups).

**Test guards:**
- Guard: `internal/backupexclude/backupexclude_darwin_test.go::TestBackup01_DataRootsExcluded`, `cmd/backup_exclude_test.go::TestBackup01_WorkspaceInitApplies`, `TestBackup01_DBMigrateApplies`, `TestBackup01_DaemonStartApplies`
- Supporting: `internal/backupexclude/backupexclude_darwin_test.go::TestApply_SecondRunWritesNothing`, `TestApply_RecreatedFolderExcludedAgain`, `TestApply_SymlinkTargetGetsAttr`, `TestApply_MissingDirSkipped`, `TestApply_OneFailureDoesNotStopOthers`, `TestApply_RewritesForeignValue`; `cmd/backup_exclude_test.go::TestBackupDirs_*`, `TestApplyBackupExclusion_FailureKeepsExitCode`, `TestApplyBackupExclusion_CreatesAS0700`

**Why locked:** A Time Machine disk is often unencrypted, plugged into other Macs and kept after the person leaves the company. Without the exclusion it holds a readable copy of the synced correspondence, recordings and sign-in files. The attribute is lost when a folder is recreated, so it is re-applied at every start; dropping one of the three entry points leaves some installs (CLI-only, or a freshly recreated workspace) backed up again.

**Locked since:** 2026-10-25

## Changelog

- 2026-10-25: file created with BACKUP-01, introduced by the Time Machine exclusion (board #605, owner approval in ask #574).

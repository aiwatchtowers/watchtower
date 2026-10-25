# Watchtower Data Out of Time Machine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Time Machine skips Watchtower's data folders for every install, and the app re-applies the exclusion each time one of those folders is recreated.

**Architecture:** A darwin-only Go package, `internal/backupexclude`, writes the sticky item exclusion (the `com.apple.metadata:com_apple_backup_excludeItem` extended attribute) with `unix.Setxattr` on the data root, on `~/Library/Application Support/Watchtower` and on a custom recordings folder. Three CLI entry points call it on every start: `workspace init`, `db migrate` (the Desktop runs it at every launch) and the daemon start. There is no Swift code, no setting and no UI.

**Tech Stack:** Go 1.26, `golang.org/x/sys/unix` (already in `go.mod`), cobra; `tmutil` serves only as the test oracle.

**Spec:** `docs/superpowers/specs/2026-10-25-time-machine-exclusion-design.md` (approved 2026-10-25, ask #574: Q1 (a), Q2 (a), Q3 (a); new BACKUP-01).

## Global Constraints

- Everyone, always, no switch (Q1 (a)). No config key and no Settings row.
- Folders: `config.DataRoot()` (`~/.local/share/watchtower`), `<as>` = `~/Library/Application Support/Watchtower`, and `cfg.RecordingsDir()` only when it is outside `<as>`. `~/.config/watchtower` stays in backups (Q2 (a)).
- Symlinks are resolved before the attribute is read or written. No folder is created except `<as>`, which is created `0700` when missing.
- Idempotent: the attribute is written only when it is missing or differs from the fixture bytes.
- A failure never changes a command's exit code. It is logged once per process as `backup exclusion: <dir>: <err>`, and the next start tries again.
- The darwin build tag holds the real implementation; every other OS gets a no-op, so Linux CI builds.
- Hooks, MCP servers and other commands never call it.
- Inner loop only per task (`go test ./internal/backupexclude`, `go test ./cmd -run …`, `make lint-diff`); the full gate once, in Task 3.

## Review Focus

1. **`<root>` is a symlink** (the owner moved the data to another volume). The target folder gets the attribute, not the link. Test in Task 1.
2. **A folder is deleted and recreated** (`workspace init` after the owner removed the data folder). It is excluded again at the next entry point. Test in Task 1 (Apply twice around a `RemoveAll`) and Task 2 (`workspace init` calls Apply after it creates the folder).
3. **The custom recordings folder sits inside `<as>`, or is unset, or no longer exists.** No duplicate write, no folder created, no error logged for a missing custom folder. Test in Task 2 (`backupDirs`).
4. **A filesystem refuses extended attributes** (`ENOTSUP` on an exFAT or SMB data root). The command succeeds, one log line is written, and the other folders are still excluded. Test in Task 1 (an injected setxattr that fails for one dir) and Task 2 (exit code unchanged).
5. **The attribute is already present with other bytes** (set by an older tool). Watchtower rewrites it to the fixture bytes once, then stops writing. Test in Task 1.

---

### Task 1: `internal/backupexclude`

**Depends on:** none

**Files:**
- Create: `internal/backupexclude/backupexclude.go` (shared doc, `Attr` const), `backupexclude_darwin.go`, `backupexclude_other.go` (`//go:build !darwin`, `Apply` returns nil), `backupexclude_darwin_test.go`, `testdata/excludeitem.bin`

**Interfaces:**
- Produces: `const Attr = "com.apple.metadata:com_apple_backup_excludeItem"`.
- Produces: `func Apply(dirs []string) []error`. For each dir it runs `filepath.EvalSymlinks`; a dir that does not exist is skipped silently. Then it calls `unix.Getxattr`, and `unix.Setxattr(dir, Attr, fixture, 0)` only when the value is missing or differs. Errors are wrapped as `fmt.Errorf("%s: %w", dir, err)`, one per failing dir; the other dirs still run.
- Produces (test seam, unexported): `var setxattr = unix.Setxattr`, so a test can fail one dir.
- The value bytes are the `tmutil addexclusion` binary plist, embedded with `//go:embed testdata/excludeitem.bin` (the test fixture is also the production value).

- [ ] **Step 0: Capture the bytes.** Run `d=$(mktemp -d) && tmutil addexclusion "$d" && xattr -px com.apple.metadata:com_apple_backup_excludeItem "$d" | xxd -r -p > internal/backupexclude/testdata/excludeitem.bin && tmutil removeexclusion "$d"`. The result is a binary plist holding the string `com.apple.backupd`. Check it with `plutil -p internal/backupexclude/testdata/excludeitem.bin`.
- [ ] **Step 1: Failing tests** (darwin) in `backupexclude_darwin_test.go`:
  - `TestBackup01_DataRootsExcluded`: three `t.TempDir()` folders. After `Apply`, each reads back the fixture bytes. If `exec.LookPath("tmutil")` finds it, `tmutil isexcluded <dir>` output contains `[Excluded]`; otherwise that half is skipped with `t.Skip`-style logging.
  - `TestApply_SecondRunWritesNothing`: count `setxattr` calls through the seam; the second `Apply` makes 0.
  - `TestApply_RecreatedFolderExcludedAgain`: Apply, `RemoveAll`, `Mkdir`, Apply → the attribute is present.
  - `TestApply_SymlinkTargetGetsAttr`: a link pointing at a dir. The target has the attribute; `unix.Lgetxattr` on the link returns `ENOATTR`.
  - `TestApply_MissingDirSkipped`: a nonexistent path → no error, nothing created.
  - `TestApply_OneFailureDoesNotStopOthers`: the seam fails for dir 1 with `unix.ENOTSUP`. `Apply` returns one error naming dir 1, and dirs 0 and 2 are excluded.
  - `TestApply_RewritesForeignValue`: preset the attribute to `[]byte("x")` → after `Apply` it holds the fixture.
- [ ] **Step 2: Run** `go test ./internal/backupexclude` → FAIL (undefined).
- [ ] **Step 3: Implement** the three source files.
- [ ] **Step 4: Run** `go test ./internal/backupexclude` → PASS; `GOOS=linux go vet ./internal/backupexclude` builds the no-op; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(backupexclude): the sticky Time Machine item exclusion, from Go (BACKUP-01)`.

### Task 2: The three entry points

**Depends on:** Task 1

**Files:**
- Create: `cmd/backup_exclude.go`, `cmd/backup_exclude_test.go`
- Modify: `internal/config/config.go`: `func AppSupportDir() (string, error)` = `~/Library/Application Support/Watchtower`, and `RecordingsDir()`'s default built from it (same path as today)
- Modify: `cmd/workspace.go` (`runWorkspaceInit`, right after `os.MkdirAll(cfg.WorkspaceDir(), 0o700)`), `cmd/db.go` (`dbMigrateCmd.RunE`, before `openDBFromConfig`, using the loaded config), `cmd/sync.go` (`runSyncDaemon`, at its start)
- Test: `cmd/backup_exclude_test.go`, `internal/config/config_test.go`

**Interfaces:**
- Consumes: `backupexclude.Apply` (Task 1).
- Produces: `func backupDirs(cfg *config.Config) []string` returns `[DataRoot, AppSupportDir]`, plus `cfg.RecordingsDir()` when it is not `AppSupportDir` itself or a path inside it (by `filepath.Rel` after cleaning). `func applyBackupExclusion(cfg *config.Config)` creates `AppSupportDir` with `fsutil.MakePrivateDir` (`0700`), calls `backupExcludeApply(backupDirs(cfg))`, and logs each error once per process (`sync.Once` per dir) to stderr as `backup exclusion: <err>`. Seam: `var backupExcludeApply = backupexclude.Apply`.

- [ ] **Step 1: Failing tests** in `cmd/backup_exclude_test.go` (temp `HOME`; the seam records its calls):
  - `TestBackupDirs_DefaultRecordingsNotDuplicated`: `[root, as]`.
  - `TestBackupDirs_CustomRecordingsOutside`: `recordings_dir = <tmp>/rec` → three dirs, `<tmp>/rec` last.
  - `TestBackupDirs_CustomRecordingsInsideAS`: `<as>/sub` → two dirs.
  - `TestBackup01_WorkspaceInitApplies`, `TestBackup01_DBMigrateApplies`, `TestBackup01_DaemonStartApplies`: each entry point calls the seam once with `backupDirs(cfg)`. For workspace init, the workspace folder already exists when the seam runs.
  - `TestApplyBackupExclusion_FailureKeepsExitCode`: the seam returns an error. `db migrate` exits 0, and stderr has one `backup exclusion:` line even when the command is run twice in the same process.
  - `TestApplyBackupExclusion_CreatesAS0700`.
  - `TestAppSupportDir` in `internal/config`; `RecordingsDir()` default unchanged.
- [ ] **Step 2: Run** `go test ./cmd -run 'BackupDirs|Backup01|ApplyBackupExclusion' && go test ./internal/config -run 'AppSupportDir|RecordingsDir'` → FAIL.
- [ ] **Step 3: Implement.** Hooks, `mcp` and other commands are not touched (check with `grep -rn applyBackupExclusion cmd/` → exactly three call sites outside tests).
- [ ] **Step 4: Run** the same commands → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(cmd): workspace init, db migrate and the daemon start keep Watchtower's folders out of Time Machine (BACKUP-01)`.

### Task 3: Inventory, feature note, guide, CLAUDE.md, gate

**Depends on:** Task 2

**Files:**
- Create: `docs/inventory/backup.md`: **BACKUP-01** (Enforced). `workspace init`, `db migrate` and the daemon start set the Time Machine item exclusion on `<root>`, `<as>` and a custom recordings folder outside `<as>`, for every install, with no switch. A failure never fails the command. `~/.config/watchtower` is not excluded. Guards: `TestBackup01_DataRootsExcluded`, `TestBackup01_WorkspaceInitApplies`, `TestBackup01_DBMigrateApplies`, `TestBackup01_DaemonStartApplies`.
- Modify: `docs/inventory/README.md` (a Backup row: `internal/backupexclude/`, `cmd/backup_exclude.go`, `cmd/workspace.go`, `cmd/db.go`, `cmd/sync.go` (`runSyncDaemon`), `internal/config/config.go` (`AppSupportDir`))
- Create: `docs/features/time-machine-exclusion.md`: the mechanism (attribute, bytes from `tmutil`, symlinks resolved), the folders, the three entry points, the failure log, what it does not cover (other backup tools, old backups, APFS snapshots, UserDefaults), and #608 as the follow-up.
- Modify: `CLAUDE.md`: one Feature Notes line for the note, in the house style.
- Modify: `docs/guide/concepts/privacy.md`: a section "Watchtower stays out of Time Machine", per `docs/guide/WRITING.md`. It says which folders are skipped and that settings are still backed up. It gives the steps to delete those folders from older backups (Q3 (a): open Time Machine, select the folder, **Delete All Backups of "…"**, or `sudo tmutil delete -p <path>`; Full Disk Access is needed). For other backup tools, it lists the two folders to exclude by hand. It notes that moving to a new Mac uses the transfer file once that exists, but only if that is on `main` when the task runs (rule 7: no roadmap); otherwise that line is left out. The page stays under 8 KB.

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Run** `go test ./docs/guide/ ./internal/kb/ ./internal/chat/`. If a guide heading changed, regenerate with `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update`. Check the size with `wc -c docs/guide/concepts/privacy.md`.
- [ ] **Step 3: Full gate:** `bash scripts/dev-health.sh`, then `make test` and `make lint-all` → pass. No Swift changed, so `make test-swift` is not needed. Manual check on a dev Mac: run `watchtower db migrate`, then `tmutil isexcluded ~/.local/share/watchtower "$HOME/Library/Application Support/Watchtower"` → both `[Excluded]`.
- [ ] **Step 4: Commit** `docs: #605 Time Machine exclusion — BACKUP-01, feature note, guide`.

package devpack

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testHookCmd = "/tmp/acme bin/watchtower project brief --project 7"

func settingsFile(dir string) string {
	return filepath.Join(dir, ".claude", "settings.local.json")
}

func writeTestFile(t *testing.T, file, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", file, err)
	}
}

func readTestFile(t *testing.T, file string) string {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatalf("read %s: %v", file, err)
	}
	return string(b)
}

func decodeSettings(t *testing.T, dir string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(readTestFile(t, settingsFile(dir))), &m); err != nil {
		t.Fatalf("settings are not valid JSON after the merge: %v", err)
	}
	return m
}

// sessionStartGroups digs out hooks.SessionStart as decoded JSON.
func sessionStartGroups(t *testing.T, m map[string]any) []any {
	t.Helper()
	hooks, ok := m["hooks"].(map[string]any)
	if !ok {
		t.Fatalf("hooks is missing or not an object: %#v", m["hooks"])
	}
	groups, ok := hooks["SessionStart"].([]any)
	if !ok {
		t.Fatalf("hooks.SessionStart is missing or not an array: %#v", hooks["SessionStart"])
	}
	return groups
}

// countCommand counts hook objects running exactly command, across groups.
func countCommand(groups []any, command string) int {
	n := 0
	for _, g := range groups {
		gm, _ := g.(map[string]any)
		hs, _ := gm["hooks"].([]any)
		for _, h := range hs {
			if hm, _ := h.(map[string]any); hm["command"] == command {
				n++
			}
		}
	}
	return n
}

func TestInstallSessionStartHookCreatesTheSettingsFile(t *testing.T) {
	dir := t.TempDir()
	changed, err := InstallSessionStartHook(dir, testHookCmd)
	if err != nil || !changed {
		t.Fatalf("install on a fresh folder: changed=%v err=%v", changed, err)
	}
	groups := sessionStartGroups(t, decodeSettings(t, dir))
	if len(groups) != 1 {
		t.Fatalf("expected one group, got %d", len(groups))
	}
	g := groups[0].(map[string]any)
	if _, hasMatcher := g["matcher"]; hasMatcher {
		t.Fatalf("our group must omit the matcher so it fires on every SessionStart source")
	}
	h := g["hooks"].([]any)[0].(map[string]any)
	if h["type"] != "command" || h["command"] != testHookCmd || h["timeout"] != float64(10) {
		t.Fatalf("unexpected hook object: %#v", h)
	}
}

func TestProj04_InstallKeepsOwnerSettingsKeysAndHooks(t *testing.T) {
	dir := t.TempDir()
	owner := `{
  "permissions": {"allow": ["Bash(make test)"], "deny": []},
  "env": {"RATIO": 1.50, "NOTE": "<b>&</b> ünïcode"},
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "echo owner-start"}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo guard"}]}
    ]
  },
  "model": "sonnet"
}`
	writeTestFile(t, settingsFile(dir), owner)

	changed, err := InstallSessionStartHook(dir, testHookCmd)
	if err != nil || !changed {
		t.Fatalf("install: changed=%v err=%v", changed, err)
	}

	raw := readTestFile(t, settingsFile(dir))
	for _, verbatim := range []string{`1.50`, `<b>&</b> ünïcode`} {
		if !strings.Contains(raw, verbatim) {
			t.Fatalf("owner value %q was rewritten; file now:\n%s", verbatim, raw)
		}
	}
	got := decodeSettings(t, dir)
	var want map[string]any
	if err := json.Unmarshal([]byte(owner), &want); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	for _, key := range []string{"permissions", "env", "model"} {
		gb, _ := json.Marshal(got[key])
		wb, _ := json.Marshal(want[key])
		if string(gb) != string(wb) {
			t.Fatalf("PROJ-04: owner key %q changed: got %s want %s", key, gb, wb)
		}
	}
	hooks := got["hooks"].(map[string]any)
	pb, _ := json.Marshal(hooks["PreToolUse"])
	wpb, _ := json.Marshal(want["hooks"].(map[string]any)["PreToolUse"])
	if string(pb) != string(wpb) {
		t.Fatalf("PROJ-04: the owner's PreToolUse hooks changed: %s", pb)
	}
	groups := sessionStartGroups(t, got)
	if len(groups) != 2 || countCommand(groups, "echo owner-start") != 1 || countCommand(groups, testHookCmd) != 1 {
		t.Fatalf("expected the owner's SessionStart group kept and ours appended, got %#v", groups)
	}
}

func TestInstallSessionStartHookTwiceKeepsOneEntry(t *testing.T) {
	dir := t.TempDir()
	if _, err := InstallSessionStartHook(dir, testHookCmd); err != nil {
		t.Fatalf("first install: %v", err)
	}
	before := readTestFile(t, settingsFile(dir))

	changed, err := InstallSessionStartHook(dir, testHookCmd)
	if err != nil {
		t.Fatalf("second install: %v", err)
	}
	if changed {
		t.Fatalf("a second install must report no change")
	}
	if after := readTestFile(t, settingsFile(dir)); after != before {
		t.Fatalf("a second install must not rewrite the file")
	}
	if n := countCommand(sessionStartGroups(t, decodeSettings(t, dir)), testHookCmd); n != 1 {
		t.Fatalf("expected exactly one entry after two installs, got %d", n)
	}
}

func TestProj04_MalformedSettingsLeftByteIdentical(t *testing.T) {
	cases := map[string]string{
		"invalid JSON":             `{"permissions": {"allow": [}`,
		"trailing garbage":         `{"model": "sonnet"} {"x": 1}`,
		"top level is an array":    `[{"hooks": {}}]`,
		"hooks is a string":        `{"hooks": "none"}`,
		"SessionStart is a object": `{"hooks": {"SessionStart": {"hooks": []}}}`,
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			writeTestFile(t, settingsFile(dir), content)

			if _, err := InstallSessionStartHook(dir, testHookCmd); !errors.Is(err, ErrMalformedSettings) {
				t.Fatalf("install: expected ErrMalformedSettings, got %v", err)
			}
			if _, err := RemoveSessionStartHook(dir, testHookCmd); !errors.Is(err, ErrMalformedSettings) {
				t.Fatalf("remove: expected ErrMalformedSettings, got %v", err)
			}
			if _, err := HasSessionStartHook(dir, testHookCmd); !errors.Is(err, ErrMalformedSettings) {
				t.Fatalf("has: expected ErrMalformedSettings, got %v", err)
			}
			if got := readTestFile(t, settingsFile(dir)); got != content {
				t.Fatalf("PROJ-04: a malformed settings file was modified:\n%s", got)
			}
		})
	}
}

func TestProj04_RemoveDeletesOnlyOurHook(t *testing.T) {
	dir := t.TempDir()
	// The owner has their own SessionStart group, and has also added a hook
	// of theirs to the group we wrote. Only our hook object may go.
	writeTestFile(t, settingsFile(dir), `{
  "model": "sonnet",
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "echo owner-start"}]},
      {"hooks": [
        {"type": "command", "command": "`+testHookCmd+`", "timeout": 10},
        {"type": "command", "command": "echo owner-added"}
      ]}
    ]
  }
}`)

	changed, err := RemoveSessionStartHook(dir, testHookCmd)
	if err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	got := decodeSettings(t, dir)
	if got["model"] != "sonnet" {
		t.Fatalf("PROJ-04: an unrelated key was lost: %#v", got)
	}
	groups := sessionStartGroups(t, got)
	if countCommand(groups, testHookCmd) != 0 {
		t.Fatalf("our hook is still there: %#v", groups)
	}
	if countCommand(groups, "echo owner-start") != 1 || countCommand(groups, "echo owner-added") != 1 {
		t.Fatalf("PROJ-04: an owner hook was removed: %#v", groups)
	}
	if len(groups) != 2 {
		t.Fatalf("a group still holding an owner hook must survive, got %d groups", len(groups))
	}

	again, err := RemoveSessionStartHook(dir, testHookCmd)
	if err != nil || again {
		t.Fatalf("a second remove must be a no-op: changed=%v err=%v", again, err)
	}
}

func TestRemoveSessionStartHookDeletesAFileItLeavesEmpty(t *testing.T) {
	dir := t.TempDir()
	if _, err := InstallSessionStartHook(dir, testHookCmd); err != nil {
		t.Fatalf("install: %v", err)
	}
	if changed, err := RemoveSessionStartHook(dir, testHookCmd); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	if _, err := os.Stat(settingsFile(dir)); !os.IsNotExist(err) {
		t.Fatalf("a settings file holding nothing but our hook must be deleted, stat err=%v", err)
	}
}

func TestRemoveSessionStartHookWithoutAFileIsANoop(t *testing.T) {
	dir := t.TempDir()
	changed, err := RemoveSessionStartHook(dir, testHookCmd)
	if err != nil || changed {
		t.Fatalf("remove with no file: changed=%v err=%v", changed, err)
	}
	if _, err := os.Stat(filepath.Join(dir, ".claude")); !os.IsNotExist(err) {
		t.Fatalf("remove must not create .claude/")
	}
}

func TestProj04_InstallAndRemovePreserveTheSettingsFileMode(t *testing.T) {
	dir := t.TempDir()
	file := settingsFile(dir)
	writeTestFile(t, file, `{"model": "sonnet"}`)
	if err := os.Chmod(file, 0o600); err != nil {
		t.Fatalf("chmod: %v", err)
	}

	if _, err := InstallSessionStartHook(dir, testHookCmd); err != nil {
		t.Fatalf("install: %v", err)
	}
	info, err := os.Stat(file)
	if err != nil {
		t.Fatalf("stat after install: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("install must preserve the file mode, got %v", info.Mode().Perm())
	}

	if _, err := RemoveSessionStartHook(dir, testHookCmd); err != nil {
		t.Fatalf("remove: %v", err)
	}
	info2, err := os.Stat(file)
	if err != nil {
		t.Fatalf("stat after remove: %v", err)
	}
	if info2.Mode().Perm() != 0o600 {
		t.Fatalf("remove must preserve the file mode, got %v", info2.Mode().Perm())
	}
}

// PROJ-04: a settings file managed as a symlink (e.g. by a dotfiles tool)
// must stay a symlink after install/remove — the write lands on its target,
// never replacing the link with a plain file.
func TestProj04_InstallAndRemoveThroughASymlinkKeepTheLink(t *testing.T) {
	dir := t.TempDir()
	realSettings := filepath.Join(t.TempDir(), "real-settings.json")
	writeTestFile(t, realSettings, `{"model": "sonnet"}`)
	link := settingsFile(dir)
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.Symlink(realSettings, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	changed, err := InstallSessionStartHook(dir, testHookCmd)
	if err != nil || !changed {
		t.Fatalf("install: changed=%v err=%v", changed, err)
	}
	info, err := os.Lstat(link)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the settings symlink must survive the install, lstat mode=%v err=%v", info.Mode(), err)
	}
	targetContent := readTestFile(t, realSettings)
	if !strings.Contains(targetContent, `"model": "sonnet"`) || !strings.Contains(targetContent, testHookCmd) {
		t.Fatalf("the symlink target must hold both the owner's key and our hook:\n%s", targetContent)
	}

	if _, err := RemoveSessionStartHook(dir, testHookCmd); err != nil {
		t.Fatalf("remove: %v", err)
	}
	info2, err := os.Lstat(link)
	if err != nil || info2.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the settings symlink must survive the remove, lstat mode=%v err=%v", info2.Mode(), err)
	}
	after := readTestFile(t, realSettings)
	if !strings.Contains(after, `"model": "sonnet"`) || strings.Contains(after, testHookCmd) {
		t.Fatalf("remove must drop our hook from the linked target: %s", after)
	}
}

// A dangling symlink can never be safely written through: resolution fails
// before any write, so the link is left exactly as it was.
func TestProj04_InstallThroughADanglingSymlinkErrorsWithoutTouchingIt(t *testing.T) {
	dir := t.TempDir()
	link := settingsFile(dir)
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	missing := filepath.Join(t.TempDir(), "gone.json")
	if err := os.Symlink(missing, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	if _, err := InstallSessionStartHook(dir, testHookCmd); err == nil {
		t.Fatalf("expected an error installing through a dangling symlink")
	}
	info, err := os.Lstat(link)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("a dangling symlink must be left untouched, lstat mode=%v err=%v", info.Mode(), err)
	}
	if target, err := os.Readlink(link); err != nil || target != missing {
		t.Fatalf("the dangling symlink's target must be unchanged: target=%q err=%v", target, err)
	}
}

func TestHasSessionStartHook(t *testing.T) {
	dir := t.TempDir()
	if ok, err := HasSessionStartHook(dir, testHookCmd); err != nil || ok {
		t.Fatalf("before install: ok=%v err=%v", ok, err)
	}
	if _, err := InstallSessionStartHook(dir, testHookCmd); err != nil {
		t.Fatalf("install: %v", err)
	}
	if ok, err := HasSessionStartHook(dir, testHookCmd); err != nil || !ok {
		t.Fatalf("after install: ok=%v err=%v", ok, err)
	}
	if ok, _ := HasSessionStartHook(dir, testHookCmd+" --other"); ok {
		t.Fatalf("recognition must be by the exact command string")
	}
}

// --- git exclude ---

// fakeRepo makes dir look like a git work tree: .git/info exists, nothing
// is exec'd.
func fakeRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".git", "info"), 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
	}
	return dir
}

var testExcludeLines = []string{".claude/skills/watchtower-project/", ".claude/settings.local.json"}

func TestEnsureGitExcludeAddsAnchoredBlockOnce(t *testing.T) {
	dir := fakeRepo(t)
	added, err := EnsureGitExclude(dir, testExcludeLines)
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	want := []string{"/.claude/skills/watchtower-project/", "/.claude/settings.local.json"}
	if strings.Join(added, "|") != strings.Join(want, "|") {
		t.Fatalf("added = %v, want %v", added, want)
	}
	exclude := filepath.Join(dir, ".git", "info", "exclude")
	content := readTestFile(t, exclude)
	wantContent := excludeBegin + "\n" + want[0] + "\n" + want[1] + "\n" + excludeEnd + "\n"
	if content != wantContent {
		t.Fatalf("exclude file:\n%s\nwant:\n%s", content, wantContent)
	}

	again, err := EnsureGitExclude(dir, testExcludeLines)
	if err != nil || len(again) != 0 {
		t.Fatalf("a second ensure must add nothing: added=%v err=%v", again, err)
	}
	if readTestFile(t, exclude) != wantContent {
		t.Fatalf("a second ensure must not rewrite the file")
	}
}

func TestEnsureGitExcludeKeepsOwnerLinesAndSkipsWhatTheOwnerHas(t *testing.T) {
	dir := fakeRepo(t)
	exclude := filepath.Join(dir, ".git", "info", "exclude")
	owner := "# git ls-files --others --exclude-from=.git/info/exclude\n*.swp\n/.claude/settings.local.json\n"
	writeTestFile(t, exclude, owner)

	added, err := EnsureGitExclude(dir, testExcludeLines)
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	if len(added) != 1 || added[0] != "/.claude/skills/watchtower-project/" {
		t.Fatalf("only the line the owner lacks may be added, got %v", added)
	}
	content := readTestFile(t, exclude)
	if !strings.HasPrefix(content, owner) {
		t.Fatalf("owner lines must be kept first and verbatim:\n%s", content)
	}

	// Removing ours must not take the owner's identical line with it.
	if err := RemoveGitExclude(dir, testExcludeLines); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if got := readTestFile(t, exclude); got != owner {
		t.Fatalf("after remove the file must be exactly the owner's again:\n%s", got)
	}
}

func TestRemoveGitExcludeRemovesOnlyTheGivenLines(t *testing.T) {
	dir := fakeRepo(t)
	if _, err := EnsureGitExclude(dir, testExcludeLines); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	if err := RemoveGitExclude(dir, testExcludeLines[:1]); err != nil {
		t.Fatalf("remove one: %v", err)
	}
	exclude := filepath.Join(dir, ".git", "info", "exclude")
	want := excludeBegin + "\n/.claude/settings.local.json\n" + excludeEnd + "\n"
	if got := readTestFile(t, exclude); got != want {
		t.Fatalf("exclude file:\n%s\nwant:\n%s", got, want)
	}
	if err := RemoveGitExclude(dir, testExcludeLines); err != nil {
		t.Fatalf("remove rest: %v", err)
	}
	if got := readTestFile(t, exclude); got != "" {
		t.Fatalf("an emptied block must lose its markers, got:\n%s", got)
	}
}

// A CRLF-authored exclude file (some owner editors normalize this way) must
// still be recognised: a pre-existing pattern is skipped, not duplicated,
// and the owner's CRLF lines are kept byte-for-byte rather than rewritten.
func TestEnsureGitExcludeRecognizesACRLFOwnerLine(t *testing.T) {
	dir := fakeRepo(t)
	exclude := filepath.Join(dir, ".git", "info", "exclude")
	owner := "*.swp\r\n/.claude/settings.local.json\r\n"
	writeTestFile(t, exclude, owner)

	added, err := EnsureGitExclude(dir, testExcludeLines)
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	if len(added) != 1 || added[0] != "/.claude/skills/watchtower-project/" {
		t.Fatalf("the CRLF-authored owner line must be recognised as already present, got %v", added)
	}
	content := readTestFile(t, exclude)
	if !strings.HasPrefix(content, owner) {
		t.Fatalf("the owner's CRLF lines must be kept byte-for-byte:\n%q", content)
	}
}

func TestEnsureGitExcludeOutsideAWorkTreeIsANoop(t *testing.T) {
	dir := t.TempDir()
	added, err := EnsureGitExclude(dir, testExcludeLines)
	if err != nil || added != nil {
		t.Fatalf("outside a work tree: added=%v err=%v", added, err)
	}
	if err := RemoveGitExclude(dir, testExcludeLines); err != nil {
		t.Fatalf("remove outside a work tree: %v", err)
	}
}

// A linked worktree's .git is a file; git reads info/exclude from the
// common dir named by the worktree's gitdir/commondir.
func TestEnsureGitExcludeInALinkedWorktreeUsesTheCommonDir(t *testing.T) {
	main := fakeRepo(t)
	wtGitDir := filepath.Join(main, ".git", "worktrees", "wt")
	writeTestFile(t, filepath.Join(wtGitDir, "commondir"), "../..\n")
	wt := t.TempDir()
	writeTestFile(t, filepath.Join(wt, ".git"), "gitdir: "+wtGitDir+"\n")

	if _, err := EnsureGitExclude(wt, testExcludeLines); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	content := readTestFile(t, filepath.Join(main, ".git", "info", "exclude"))
	if !strings.Contains(content, "/.claude/settings.local.json") {
		t.Fatalf("the common dir's exclude was not written:\n%s", content)
	}
}

// A project folder below the work tree's top gets patterns anchored from
// the top, with glob characters in its path escaped.
func TestEnsureGitExcludeInASubfolderAnchorsFromTheTop(t *testing.T) {
	top := fakeRepo(t)
	sub := filepath.Join(top, "apps", "acme [beta] ü")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	added, err := EnsureGitExclude(sub, testExcludeLines[1:])
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	want := `/apps/acme \[beta] ü/.claude/settings.local.json`
	if len(added) != 1 || added[0] != want {
		t.Fatalf("added = %v, want [%s]", added, want)
	}
}

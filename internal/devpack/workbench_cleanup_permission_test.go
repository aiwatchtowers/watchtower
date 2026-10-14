package devpack

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

const (
	testCleanupBin  = "/tmp/acme bin/watchtower"
	testCleanupRule = "Bash('/tmp/acme bin/watchtower' workbench cleanup:*)"
)

// allowList digs out permissions.allow as decoded JSON (nil when absent).
func allowList(t *testing.T, dir string) []any {
	t.Helper()
	perms, _ := decodeSettings(t, dir)["permissions"].(map[string]any)
	allow, _ := perms["allow"].([]any)
	return allow
}

func TestCleanupAllowRuleAndCommandQuoteTheBinaryTheSameWay(t *testing.T) {
	if got := cleanupAllowRule(testCleanupBin); got != testCleanupRule {
		t.Fatalf("rule for a spaced bin: %q", got)
	}
	if got := cleanupAllowRule("/usr/local/bin/watchtower"); got != "Bash(/usr/local/bin/watchtower workbench cleanup:*)" {
		t.Fatalf("rule for a plain bin: %q", got)
	}
	if got := CleanupCommand(testCleanupBin, 42); got != "'/tmp/acme bin/watchtower' workbench cleanup --session 42" {
		t.Fatalf("command: %q", got)
	}
}

// PROJ-04: the install adds exactly one allow string for the cleanup command;
// the owner's allow, deny and ask entries keep their order and every other
// key its value; the removal gives the owner's file back exactly.
func TestProj04_CleanupPermissionKeepsOwnerPermissions(t *testing.T) {
	dir := t.TempDir()
	owner := `{
  "env": {"RATIO": 1.50, "NOTE": "<b>&</b> ünïcode"},
  "model": "sonnet",
  "permissions": {
    "allow": ["Bash(make test)", "Read(*)", "Bash(watchtower workbench cleanup --apply:*)", "Bash(/x/notwatchtower workbench cleanup:*)"],
    "ask": ["Bash(git push:*)"],
    "deny": ["Bash(rm -rf:*)", "WebFetch"],
    "defaultMode": "acceptEdits"
  }
}`
	writeTestFile(t, settingsFile(dir), owner)
	var want map[string]any
	if err := json.Unmarshal([]byte(owner), &want); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	changed, err := InstallCleanupPermission(dir, testCleanupBin)
	if err != nil || !changed {
		t.Fatalf("install: changed=%v err=%v", changed, err)
	}
	assertOwnerSettingsPlusOurRule(t, dir, want)

	if changed, err := RemoveCleanupPermission(dir); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	if got := decodeSettings(t, dir); !reflect.DeepEqual(got, want) {
		t.Fatalf("PROJ-04: the removal must give back exactly the owner's settings, got %#v", got)
	}
	if has, err := HasCleanupPermission(dir); err != nil || has {
		t.Fatalf("after the removal: has=%v err=%v", has, err)
	}
}

// assertOwnerSettingsPlusOurRule checks the installed file against the
// owner's decoded settings: their values kept verbatim, permissions.allow is
// theirs in order plus exactly our rule, every other key unchanged.
func assertOwnerSettingsPlusOurRule(t *testing.T, dir string, want map[string]any) {
	t.Helper()
	raw := readTestFile(t, settingsFile(dir))
	for _, verbatim := range []string{`1.50`, `<b>&</b> ünïcode`} {
		if !strings.Contains(raw, verbatim) {
			t.Fatalf("PROJ-04: owner value %q was rewritten; file now:\n%s", verbatim, raw)
		}
	}
	got := decodeSettings(t, dir)
	wantPerms := want["permissions"].(map[string]any)
	gotPerms := got["permissions"].(map[string]any)
	wantAllow := append(append([]any{}, wantPerms["allow"].([]any)...), testCleanupRule)
	if !reflect.DeepEqual(gotPerms["allow"], wantAllow) {
		t.Fatalf("PROJ-04: allow must be the owner's, in order, plus exactly our rule; got %#v", gotPerms["allow"])
	}
	for _, key := range []string{"ask", "deny", "defaultMode"} {
		if !reflect.DeepEqual(gotPerms[key], wantPerms[key]) {
			t.Fatalf("PROJ-04: permissions.%s changed: %#v", key, gotPerms[key])
		}
	}
	for _, key := range []string{"env", "model"} {
		if !reflect.DeepEqual(got[key], want[key]) {
			t.Fatalf("PROJ-04: owner key %q changed: %#v", key, got[key])
		}
	}
}

func TestCleanupPermission_IdempotentAndReplacesStaleBin(t *testing.T) {
	dir := t.TempDir()
	if changed, err := InstallCleanupPermission(dir, testCleanupBin); err != nil || !changed {
		t.Fatalf("first install: changed=%v err=%v", changed, err)
	}
	before := readTestFile(t, settingsFile(dir))
	if changed, err := InstallCleanupPermission(dir, testCleanupBin); err != nil || changed {
		t.Fatalf("a repeat install must be a no-op: changed=%v err=%v", changed, err)
	}
	if after := readTestFile(t, settingsFile(dir)); after != before {
		t.Fatalf("a repeat install rewrote the file:\n%s", after)
	}
	if got := allowList(t, dir); !reflect.DeepEqual(got, []any{testCleanupRule}) {
		t.Fatalf("expected exactly our rule, got %#v", got)
	}

	// A stale bin's rule is replaced in place; a duplicate of ours goes.
	writeTestFile(t, settingsFile(dir), `{"permissions": {"allow": [
  "Bash(make test)",
  "Bash('/old dir/watchtower' workbench cleanup:*)",
  "Read(*)",
  "Bash(/usr/bin/watchtower workbench cleanup:*)"
]}}`)
	if changed, err := InstallCleanupPermission(dir, testCleanupBin); err != nil || !changed {
		t.Fatalf("stale install: changed=%v err=%v", changed, err)
	}
	want := []any{"Bash(make test)", testCleanupRule, "Read(*)"}
	if got := allowList(t, dir); !reflect.DeepEqual(got, want) {
		t.Fatalf("stale rule not replaced in place: got %#v want %#v", got, want)
	}
}

// A file the install cannot read as the documented shape is refused and
// left byte-identical by install, removal and status alike (PROJ-04).
func TestCleanupPermission_MalformedSettingsIsAnErrorNotAnOverwrite(t *testing.T) {
	for _, content := range []string{
		`{"permissions": [`,
		`{"permissions": "allow everything"}`,
		`{"permissions": {"allow": "Bash(watchtower workbench cleanup:*)"}}`,
		`["permissions"]`,
	} {
		dir := t.TempDir()
		writeTestFile(t, settingsFile(dir), content)
		if _, err := InstallCleanupPermission(dir, testCleanupBin); !errors.Is(err, ErrMalformedSettings) {
			t.Fatalf("%s: install: expected ErrMalformedSettings, got %v", content, err)
		}
		if _, err := RemoveCleanupPermission(dir); !errors.Is(err, ErrMalformedSettings) {
			t.Fatalf("%s: remove: expected ErrMalformedSettings, got %v", content, err)
		}
		if _, err := HasCleanupPermission(dir); !errors.Is(err, ErrMalformedSettings) {
			t.Fatalf("%s: has: expected ErrMalformedSettings, got %v", content, err)
		}
		if got := readTestFile(t, settingsFile(dir)); got != content {
			t.Fatalf("PROJ-04: a malformed file was modified: %q", got)
		}
	}
}

// The removal on a folder without a settings file, or without our rule,
// writes nothing; once only our rule was there, the file goes.
func TestCleanupPermission_RemoveLeavesNoFileOrOnlyTheOwners(t *testing.T) {
	dir := t.TempDir()
	if changed, err := RemoveCleanupPermission(dir); err != nil || changed {
		t.Fatalf("no file: changed=%v err=%v", changed, err)
	}
	if _, err := os.Stat(settingsFile(dir)); !os.IsNotExist(err) {
		t.Fatalf("the removal created a settings file (stat err=%v)", err)
	}
	if _, err := InstallCleanupPermission(dir, testCleanupBin); err != nil {
		t.Fatalf("install: %v", err)
	}
	if changed, err := RemoveCleanupPermission(dir); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	if _, err := os.Stat(settingsFile(dir)); !os.IsNotExist(err) {
		t.Fatalf("a file holding only our rule must go (stat err=%v)", err)
	}
	const ownerOnly = `{"permissions": {"allow": ["Bash(make test)"]}}`
	writeTestFile(t, settingsFile(dir), ownerOnly)
	if changed, err := RemoveCleanupPermission(dir); err != nil || changed {
		t.Fatalf("owner-only file: changed=%v err=%v", changed, err)
	}
	if got := readTestFile(t, settingsFile(dir)); got != ownerOnly {
		t.Fatalf("the owner's file was rewritten: %q", got)
	}
}

// A malformed permissions shape is refused by the whole workbench setup like
// a malformed hooks shape: no step writes, so the file stays byte-identical
// (PROJ-04), and the status reports it as one error.
func TestProj04_MalformedPermissionsRefusedByEveryWorkbenchStep(t *testing.T) {
	for _, content := range []string{
		`{"permissions":"x"}`,
		`{"permissions":{"allow":"x"}}`,
	} {
		folder := fakeRepo(t)
		writeTestFile(t, settingsFile(folder), content)
		o := workbenchOpts(folder, newFakeClaude())
		rep, err := InstallWorkbench(context.Background(), o)
		if !errors.Is(err, ErrMalformedSettings) {
			t.Fatalf("%s: install: expected ErrMalformedSettings, got %v", content, err)
		}
		if rep.HookChanged || rep.CleanupPermissionChanged {
			t.Fatalf("%s: install reported a change on a refused file: %+v", content, rep)
		}
		if got := readTestFile(t, settingsFile(folder)); got != content {
			t.Fatalf("%s: PROJ-04: install modified the file: %q", content, got)
		}
		if _, err := StatusWorkbench(context.Background(), o); !errors.Is(err, ErrMalformedSettings) {
			t.Fatalf("%s: status: expected ErrMalformedSettings, got %v", content, err)
		} else if n := strings.Count(err.Error(), ErrMalformedSettings.Error()); n != 1 {
			t.Fatalf("%s: status must report the malformed file once, got %d times: %v", content, n, err)
		}
		if got := readTestFile(t, settingsFile(folder)); got != content {
			t.Fatalf("%s: PROJ-04: status modified the file: %q", content, got)
		}
	}
}

// An entry the owner (or Claude Code) adds between our first read and the
// write survives: the edit is applied to a fresh read.
func TestCleanupPermission_WriteKeepsAnEntryAddedMeanwhile(t *testing.T) {
	for _, tc := range []struct {
		name string
		op   func(dir string) (bool, error)
		seed string
		want []any
	}{
		{"install", func(dir string) (bool, error) { return InstallCleanupPermission(dir, testCleanupBin) },
			`{"permissions": {"allow": ["Read(*)"]}}`, []any{"Read(*)", "Bash(make test)", testCleanupRule}},
		{"remove", RemoveCleanupPermission,
			`{"permissions": {"allow": ["Read(*)", "` + testCleanupRule + `"]}}`, []any{"Read(*)", "Bash(make test)"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			writeTestFile(t, settingsFile(dir), tc.seed)
			prev := beforeCleanupRuleWrite
			t.Cleanup(func() { beforeCleanupRuleWrite = prev })
			beforeCleanupRuleWrite = func() {
				var s map[string]any
				if err := json.Unmarshal([]byte(readTestFile(t, settingsFile(dir))), &s); err != nil {
					t.Fatalf("seam read: %v", err)
				}
				perms := s["permissions"].(map[string]any)
				allow := perms["allow"].([]any)
				perms["allow"] = append(allow[:1:1], append([]any{"Bash(make test)"}, allow[1:]...)...)
				b, _ := json.Marshal(s)
				writeTestFile(t, settingsFile(dir), string(b))
			}
			if changed, err := tc.op(dir); err != nil || !changed {
				t.Fatalf("changed=%v err=%v", changed, err)
			}
			if got := allowList(t, dir); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("an entry added meanwhile was lost: got %#v want %#v", got, tc.want)
			}
		})
	}
}

// Only an absolute watchtower bin's rule is ours: the owner's bare or
// relative form is never rewritten by the install nor taken by the removal.
func TestCleanupPermission_OwnerBareOrRelativeRuleIsNeverOurs(t *testing.T) {
	owners := []any{
		"Bash(watchtower workbench cleanup:*)",
		"Bash(./bin/watchtower workbench cleanup:*)",
		"Bash('bin dir/watchtower' workbench cleanup:*)",
	}
	dir := t.TempDir()
	b, _ := json.Marshal(map[string]any{"permissions": map[string]any{"allow": owners}})
	writeTestFile(t, settingsFile(dir), string(b))
	if has, err := HasCleanupPermission(dir); err != nil || has {
		t.Fatalf("an owner's rule counted as ours: has=%v err=%v", has, err)
	}
	if changed, err := InstallCleanupPermission(dir, testCleanupBin); err != nil || !changed {
		t.Fatalf("install: changed=%v err=%v", changed, err)
	}
	if got, want := allowList(t, dir), append(slices.Clone(owners), testCleanupRule); !reflect.DeepEqual(got, want) {
		t.Fatalf("install touched an owner's rule: got %#v want %#v", got, want)
	}
	if changed, err := RemoveCleanupPermission(dir); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	if got := allowList(t, dir); !reflect.DeepEqual(got, owners) {
		t.Fatalf("remove took an owner's rule: got %#v", got)
	}
}

// PROJ-04: a settings.local.json linking outside the folder is refused by the
// cleanup-rule install and removal alike, before anything is read or
// written: the outside target stays byte-identical, the link untouched, and
// the refusal's hint names the allow rule, not hooks.
func TestProj04_CleanupPermissionRefusesASymlinkOutsideTheFolder(t *testing.T) {
	dir := t.TempDir()
	outside := filepath.Join(t.TempDir(), "settings.json")
	link := settingsFile(dir)
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.Symlink(outside, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	content := `{"model": "sonnet", "permissions": {"allow": ["` + testCleanupRule + `"]}}`
	writeTestFile(t, outside, content)
	ops := map[string]func() (bool, error){
		"install": func() (bool, error) { return InstallCleanupPermission(dir, testCleanupBin) },
		"remove":  func() (bool, error) { return RemoveCleanupPermission(dir) },
	}
	for name, op := range ops {
		changed, err := op()
		if !errors.Is(err, ErrSymlinkOutsideFolder) || changed {
			t.Fatalf("%s through a link leaving the folder: changed=%v err=%v", name, changed, err)
		}
		if got := readTestFile(t, outside); got != content {
			t.Fatalf("%s: the outside target must stay byte-identical, got %s", name, got)
		}
		if target, err := os.Readlink(link); err != nil || target != outside {
			t.Fatalf("%s: the link must be untouched: target=%q err=%v", name, target, err)
		}
		hints := OutsideFolderHints(err)
		if len(hints) != 1 || !strings.Contains(hints[0], "cleanup allow rule") || strings.Contains(hints[0], "hooks") {
			t.Fatalf("%s: the hint must name the allow rule: %q", name, hints)
		}
	}
}

// A settings.local.json linking to a file inside the folder is followed: the
// rule lands in, and is removed from, the link's target, and the link
// survives both.
func TestCleanupPermission_SymlinkInsideTheFolderIsFollowed(t *testing.T) {
	dir := t.TempDir()
	realSettings := filepath.Join(dir, "dotfiles", "real-settings.json")
	writeTestFile(t, realSettings, `{"model": "sonnet"}`)
	link := settingsFile(dir)
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.Symlink(realSettings, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	assertLink := func(step string) {
		t.Helper()
		if info, err := os.Lstat(link); err != nil || info.Mode()&os.ModeSymlink == 0 {
			t.Fatalf("the settings symlink must survive the %s: err=%v", step, err)
		}
	}

	if changed, err := InstallCleanupPermission(dir, testCleanupBin); err != nil || !changed {
		t.Fatalf("install: changed=%v err=%v", changed, err)
	}
	assertLink("install")
	if got := readTestFile(t, realSettings); !strings.Contains(got, `"model": "sonnet"`) || !strings.Contains(got, "workbench cleanup:*") {
		t.Fatalf("the target must hold the owner's key and our rule:\n%s", got)
	}

	if changed, err := RemoveCleanupPermission(dir); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	assertLink("remove")
	if got := readTestFile(t, realSettings); !strings.Contains(got, `"model": "sonnet"`) || strings.Contains(got, "workbench cleanup") {
		t.Fatalf("the removal must drop our rule from the target: %s", got)
	}
}

// With .claude linked outside the folder and no settings file, there is
// nothing to remove: the removal succeeds, as the hook removals do, and
// creates nothing outside. The install is still refused.
func TestCleanupPermission_DirectoryLinkOutsideWithNoFile(t *testing.T) {
	dir := t.TempDir()
	outsideDir := t.TempDir()
	if err := os.Symlink(outsideDir, filepath.Join(dir, ".claude")); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	if changed, err := RemoveCleanupPermission(dir); err != nil || changed {
		t.Fatalf("remove with no settings file: changed=%v err=%v", changed, err)
	}
	if changed, err := InstallCleanupPermission(dir, testCleanupBin); !errors.Is(err, ErrSymlinkOutsideFolder) || changed {
		t.Fatalf("install through a .claude link leaving the folder: changed=%v err=%v", changed, err)
	}
	if _, err := os.Stat(filepath.Join(outsideDir, "settings.local.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("nothing may be created outside the folder, stat err=%v", err)
	}
}

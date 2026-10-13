package devpack

import (
	"encoding/json"
	"errors"
	"os"
	"reflect"
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

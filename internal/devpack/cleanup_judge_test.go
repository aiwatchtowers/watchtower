package devpack

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var timeoutAsString = regexp.MustCompile(`"timeout": (\d+)`)

func installAllHooks(t *testing.T, dir, bin string, id int64) {
	t.Helper()
	if _, _, err := installWorkbenchHooks(WorkbenchInstallOptions{WorkbenchID: id, Folder: dir, Bin: bin}); err != nil {
		t.Fatal(err)
	}
}

func TestSettingsOnlyOurs(t *testing.T) {
	t.Parallel()
	edit := func(old, repl string) func(string) string {
		return func(s string) string { return strings.Replace(s, old, repl, 1) }
	}
	for name, tc := range map[string]struct {
		change func(string) string
		want   bool
	}{
		"as installed":         {func(s string) string { return s }, true},
		"claude code rules":    {edit(`"allow": [`, `"deny": ["Bash(rm:*)"], "allow": ["Bash(go test:*)", `), true},
		"another workbench id": {edit(" --workbench 7", " --workbench 8"), false},
		"another binary path": {func(s string) string {
			return strings.ReplaceAll(s, "'/opt/a b/watchtower'", "/usr/local/bin/watchtower")
		}, true},
		"owner command before": {edit(`"command": "'/opt/a b/watchtower'`, `"command": "./mine.sh; '/opt/a b/watchtower'`), false},
		"owner command after":  {edit(` --workbench 7"`, ` --workbench 7; ./mine.sh"`), false},
		"changed matcher":      {edit(`"matcher": "`, `"matcher": "Bash|`), false},
		"changed timeout":      {edit(`"timeout": `, `"timeout": 9`), false},
		"timeout as a string":  {func(s string) string { return timeoutAsString.ReplaceAllString(s, `"timeout": "$1"`) }, false},
		"async as a string":    {edit(`"async": true`, `"async": "true"`), false},
		"prompt hook":          {edit(`"type": "command"`, `"type": "prompt", "prompt": "[watchtower-workbench ask-guard 7]\nedited"`), false},
		"another program":      {edit("/opt/a b/watchtower", "/opt/a b/other"), false},
		"extra hook field":     {edit(`"type": "command"`, `"type": "command", "statusMessage": "mine"`), false},
		"extra key":            {edit(`"hooks": {`, `"model": "x", "hooks": {`), false},
		"permission mode":      {edit(`"allow": [`, `"defaultMode": "plan", "allow": [`), false},
		"non-string rule":      {edit(`"allow": [`, `"allow": [1, `), false},
		"unparseable":          {func(string) string { return "{nope" }, false},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			dir := t.TempDir()
			installAllHooks(t, dir, "/opt/a b/watchtower", 7)
			file := settingsLocalPath(dir)
			b, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			changed := tc.change(string(b))
			if name != "as installed" && changed == string(b) {
				t.Fatalf("the change did not apply to %s", b)
			}
			if err := os.WriteFile(file, []byte(changed), 0o600); err != nil {
				t.Fatal(err)
			}
			got, err := SettingsOnlyOurs(file, 7)
			if err != nil || got != tc.want {
				t.Fatalf("SettingsOnlyOurs = %v, %v; want %v", got, err, tc.want)
			}
		})
	}
}

func TestWorkbenchSkillCopyUnedited(t *testing.T) {
	t.Parallel()
	shipped := func(content string) string {
		sum := sha256.Sum256([]byte(content))
		return hex.EncodeToString(sum[:]) + "\n"
	}
	_, current := WorkbenchSkill()
	old := "---\nname: watchtower-workbench\n" + MarkerKey + ": watchtower\n---\nv1\n"
	for name, tc := range map[string]struct {
		dir, content, sidecar, extra string
		want                         bool
	}{
		"current, no sidecar": {WorkbenchSkillName, string(current), "", "", true},
		"older version":       {WorkbenchSkillName, old, shipped(old), "", true},
		"edited":              {WorkbenchSkillName, old + "mine\n", shipped(old), "", false},
		"extra file":          {WorkbenchSkillName, string(current), "", "notes.md", false},
		"legacy, untouched":   {LegacySkillName, old, shipped(old), "", true},
		"legacy, no sidecar":  {LegacySkillName, old, "", "", false},
		"another name":        {"watchtower-mine", string(current), "", "", false},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			dir := filepath.Join(t.TempDir(), tc.dir)
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			write := func(n, s string) {
				if err := os.WriteFile(filepath.Join(dir, n), []byte(s), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			write("SKILL.md", tc.content)
			if tc.sidecar != "" {
				write(shippedDigestFile, tc.sidecar)
			}
			if tc.extra != "" {
				write(tc.extra, "x\n")
			}
			got, err := WorkbenchSkillCopyUnedited(dir)
			if err != nil || got != tc.want {
				t.Fatalf("WorkbenchSkillCopyUnedited = %v, %v; want %v", got, err, tc.want)
			}
		})
	}
}

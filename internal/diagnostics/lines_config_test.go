package diagnostics

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/providers"
)

// canary stands in for a raw value that must never reach the report.
const canary = "zzcanaryzz"

// testInstall points HOME at a temp dir (config.Load and config.DataRoot
// read it), clears the provider override and returns the config path and
// the data root.
func testInstall(t *testing.T) (cfgPath, root string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WATCHTOWER_AI_PROVIDER", "")
	return filepath.Join(home, "config.yaml"), filepath.Join(home, ".local", "share", "watchtower")
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// addWorkspace creates <root>/<name>, with a watchtower.db when withDB.
func addWorkspace(t *testing.T, root, name string, withDB bool) {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if withDB {
		writeFile(t, filepath.Join(dir, "watchtower.db"), "")
	}
}

func skipIfRoot(t *testing.T) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("permission bits do not stop root")
	}
}

// unreadable makes path mode 000 and restores it in cleanup.
func unreadable(t *testing.T, path string) {
	t.Helper()
	skipIfRoot(t)
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o600) })
}

func TestDiagnostics_NoConfig(t *testing.T) {
	cfgPath, _ := testInstall(t)
	env := Env{ConfigPath: cfgPath}
	r := Resolve(env)
	if r.ConfigLine != ConfigNone || r.ConfigState != ConfigStateNone {
		t.Fatalf("config line %q state %v", r.ConfigLine, r.ConfigState)
	}
	if r.WorkspaceLine != "" || r.WorkspaceReason != UnknownNoConfig {
		t.Errorf("workspace line %q reason %q", r.WorkspaceLine, r.WorkspaceReason)
	}
	if got := FeaturesLine(r, env); got != UnknownNoConfig {
		t.Errorf("features %q", got)
	}
	if _, err := os.Stat(cfgPath); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a config file appeared: %v", err)
	}
}

func TestDiagnostics_BrokenConfig(t *testing.T) {
	cfgPath, _ := testInstall(t)
	writeFile(t, cfgPath, "ai: [unclosed\n  "+canary+"\n")
	r := Resolve(Env{ConfigPath: cfgPath})
	if r.ConfigLine != ConfigUnreadableParse || r.ConfigState != ConfigStateUnreadable {
		t.Fatalf("config line %q", r.ConfigLine)
	}
	if r.WorkspaceReason != UnknownNoConfig || r.WorkspaceLine != "" {
		t.Errorf("workspace line %q reason %q", r.WorkspaceLine, r.WorkspaceReason)
	}
}

func TestDiagnostics_UnreadableConfig(t *testing.T) {
	cfgPath, _ := testInstall(t)
	writeFile(t, cfgPath, "active_workspace: acme\n")
	unreadable(t, cfgPath)
	r := Resolve(Env{ConfigPath: cfgPath})
	if r.ConfigLine != ConfigUnreadablePermission {
		t.Fatalf("config line %q", r.ConfigLine)
	}
}

// TestDiagnostics_InputFailures covers the config and workspace rows of the
// spec's Inputs table; the e2e cases repeat in cmd (Task 11).
func TestDiagnostics_InputFailures(t *testing.T) {
	type want struct {
		config, workspace, reason, name string
	}
	cases := []struct {
		name  string
		setup func(t *testing.T, cfgPath, root string) Env
		want  want
	}{
		{"config_is_directory", func(t *testing.T, cfgPath, _ string) Env {
			if err := os.MkdirAll(cfgPath, 0o755); err != nil {
				t.Fatal(err)
			}
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigUnreadableOther, reason: UnknownNoConfig}},
		{"config_symlink_loop", func(t *testing.T, cfgPath, _ string) Env {
			if err := os.Symlink(cfgPath, cfgPath); err != nil {
				t.Fatal(err)
			}
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigUnreadableOther, reason: UnknownNoConfig}},
		{"config_invalid_value", func(t *testing.T, cfgPath, _ string) Env {
			writeFile(t, cfgPath, "ai:\n  provider: "+canary+"\n")
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigUnreadableInvalidValue, reason: UnknownNoConfig}},
		{"workspace_not_chosen", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "digest:\n  enabled: true\n")
			addWorkspace(t, root, "alpha", true)
			addWorkspace(t, root, "beta", true)
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigOK, workspace: "not chosen (2 found)", reason: UnknownNoWorkspace}},
		{"workspace_none_yet", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "digest:\n  enabled: true\n")
			addWorkspace(t, root, "alpha", false)
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigOK, workspace: WorkspaceNoneYet, reason: UnknownNoWorkspace}},
		{"workspace_lookup_failed", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "digest:\n  enabled: true\n")
			writeFile(t, root, "not a directory")
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigOK, workspace: WorkspaceLookupFailed, reason: UnknownNoWorkspace}},
		{"workspace_single_resolved", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "digest:\n  enabled: true\n")
			addWorkspace(t, root, "alpha", true)
			addWorkspace(t, root, "beta", false)
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigOK, name: "alpha"}},
		{"workspace_flag_wins", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "active_workspace: alpha\n")
			addWorkspace(t, root, "alpha", true)
			addWorkspace(t, root, "beta", true)
			return Env{ConfigPath: cfgPath, WorkspaceFlag: "beta"}
		}, want{config: ConfigOK, name: "beta"}},
		{"workspace_flag_invalid", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "active_workspace: alpha\n")
			addWorkspace(t, root, "alpha", true)
			return Env{ConfigPath: cfgPath, WorkspaceFlag: "../x"}
		}, want{config: ConfigOK, workspace: WorkspaceInvalidName, reason: UnknownNoWorkspace}},
		{"workspace_flag_not_found", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "active_workspace: alpha\n")
			addWorkspace(t, root, "alpha", true)
			return Env{ConfigPath: cfgPath, WorkspaceFlag: canary}
		}, want{config: ConfigOK, workspace: WorkspaceNotFound, reason: UnknownNoWorkspace}},
		{"workspace_config_invalid_name", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "active_workspace: \"../"+canary+"\"\n")
			addWorkspace(t, root, "alpha", true)
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigOK, workspace: WorkspaceInvalidName, reason: UnknownNoWorkspace}},
		{"workspace_config_not_found", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "active_workspace: "+canary+"\n")
			addWorkspace(t, root, "alpha", true)
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigOK, workspace: WorkspaceNotFound, reason: UnknownNoWorkspace}},
		{"workspace_config_names_a_file", func(t *testing.T, cfgPath, root string) Env {
			writeFile(t, cfgPath, "active_workspace: alpha\n")
			writeFile(t, filepath.Join(root, "alpha"), "")
			return Env{ConfigPath: cfgPath}
		}, want{config: ConfigOK, workspace: WorkspaceNotFound, reason: UnknownNoWorkspace}},
		{"no_home_dir", func(t *testing.T, _, _ string) Env {
			t.Setenv("HOME", "")
			return Env{ConfigPath: ""}
		}, want{config: UnknownNoHome, reason: UnknownNoHome}},
		{"no_home_dir_config_path_set", func(t *testing.T, cfgPath, _ string) Env {
			writeFile(t, cfgPath, "active_workspace: alpha\n")
			t.Setenv("HOME", "")
			return Env{ConfigPath: cfgPath, DataRoot: func() (string, error) {
				return "", errors.New("could not determine home directory")
			}}
		}, want{config: ConfigOK, workspace: UnknownNoHome, reason: UnknownNoHome}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfgPath, root := testInstall(t)
			env := c.setup(t, cfgPath, root)
			r := Resolve(env)
			if r.ConfigLine != c.want.config {
				t.Errorf("config line %q, want %q", r.ConfigLine, c.want.config)
			}
			if r.WorkspaceLine != c.want.workspace {
				t.Errorf("workspace line %q, want %q", r.WorkspaceLine, c.want.workspace)
			}
			if r.WorkspaceReason != c.want.reason {
				t.Errorf("workspace reason %q, want %q", r.WorkspaceReason, c.want.reason)
			}
			if r.Workspace != c.want.name {
				t.Errorf("workspace %q, want %q", r.Workspace, c.want.name)
			}
			for _, s := range []string{r.ConfigLine, r.WorkspaceLine, r.WorkspaceReason} {
				if strings.Contains(s, canary) || strings.Contains(s, "alpha") || strings.Contains(s, "beta") {
					t.Errorf("a name reached the report: %q", s)
				}
			}
		})
	}
}

func TestDiagnostics_AILine(t *testing.T) {
	cases := []struct {
		name, yaml, env  string
		setup            func(t *testing.T, cfgPath string) // replaces yaml when set
		configPath       string                             // "-" = no home directory
		wantText, wantJS string
	}{
		{name: "provider_absent_default", yaml: "digest:\n  enabled: true\n",
			wantText: "Claude Code (default, not chosen)", wantJS: "Claude Code"},
		{name: "provider_empty_string", yaml: "ai:\n  provider: \"\"\n",
			wantText: "Claude Code (default, not chosen)", wantJS: "Claude Code"},
		{name: "provider_claude_set", yaml: "ai:\n  provider: claude\n",
			wantText: "Claude Code", wantJS: "Claude Code"},
		{name: "provider_codex", yaml: "ai:\n  provider: codex\n",
			wantText: "Codex", wantJS: "Codex"},
		{name: "provider_ollama", yaml: "ai:\n  provider: ollama\n",
			wantText: "Ollama", wantJS: "Ollama (or another local server)"},
		{name: "provider_env_only", yaml: "digest:\n  enabled: true\n", env: "codex",
			wantText: "Codex (from environment)", wantJS: "Codex"},
		{name: "provider_env_overrides_file", yaml: "ai:\n  provider: ollama\n", env: "codex",
			wantText: "Codex (from environment)", wantJS: "Codex"},
		{name: "provider_unknown_value", yaml: "ai:\n  provider: " + canary + "\n",
			wantText: "unknown (not a known provider)", wantJS: ""},
		{name: "provider_unknown_env", yaml: "ai:\n  provider: claude\n", env: canary,
			wantText: "unknown (not a known provider)", wantJS: ""},
		{name: "reserve_automatic", yaml: "ai:\n  provider: claude\n  fallback:\n    enabled: true\n    provider: codex\n",
			wantText: "Claude Code · reserve Codex, automatic", wantJS: "Claude Code"},
		{name: "reserve_off", yaml: "ai:\n  provider: codex\n  fallback:\n    enabled: false\n    provider: claude\n",
			wantText: "Codex · reserve Claude Code, off", wantJS: "Codex"},
		{name: "reserve_none", yaml: "ai:\n  provider: codex\n",
			wantText: "Codex", wantJS: "Codex"},
		{name: "fallback_unknown", yaml: "ai:\n  provider: claude\n  fallback:\n    provider: " + canary + "\n",
			wantText: "Claude Code · reserve invalid", wantJS: "Claude Code"},
		{name: "fallback_same_as_preferred", yaml: "ai:\n  provider: codex\n  fallback:\n    provider: codex\n",
			wantText: "Codex · reserve invalid", wantJS: "Codex"},
		{name: "fallback_not_a_pair", yaml: "ai:\n  provider: claude\n  fallback:\n    provider: ollama\n",
			wantText: "Claude Code · reserve invalid", wantJS: "Claude Code"},
		{name: "fallback_enabled_without_pair", yaml: "ai:\n  provider: ollama\n  fallback:\n    enabled: true\n",
			wantText: "Ollama · reserve invalid", wantJS: "Ollama (or another local server)"},
		{name: "bucket_unknown", yaml: "ai:\n  provider: claude\n  providers:\n    " + canary + ":\n      models:\n        light: x\n",
			wantText: "Claude Code · provider settings invalid", wantJS: "Claude Code"},
		{name: "bucket_unknown_valid_reserve", yaml: "ai:\n  fallback:\n    provider: codex\n  providers:\n    " + canary + ": {}\n",
			wantText: "Claude Code (default, not chosen) · reserve Codex, off · provider settings invalid", wantJS: "Claude Code"},
		{name: "unknown_provider_and_bucket", yaml: "ai:\n  provider: " + canary + "\n  providers:\n    " + canary + ": {}\n",
			wantText: "unknown (not a known provider) · provider settings invalid", wantJS: ""},
		{name: "config_missing",
			wantText: "not set up (no config)", wantJS: "Not set up yet"},
		{name: "config_parse_error", yaml: "ai: [unclosed\n",
			wantText: "unknown (no config)", wantJS: ""},
		{name: "config_permission", setup: func(t *testing.T, cfgPath string) {
			writeFile(t, cfgPath, "ai:\n  provider: codex\n")
			unreadable(t, cfgPath)
		}, wantText: "unknown (no config)", wantJS: ""},
		{name: "no_home_dir", configPath: "-",
			wantText: "unknown (no home directory)", wantJS: ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfgPath, _ := testInstall(t)
			switch {
			case c.setup != nil:
				c.setup(t, cfgPath)
			case c.yaml != "":
				writeFile(t, cfgPath, c.yaml)
			}
			if c.configPath == "-" {
				cfgPath = ""
			}
			if c.env != "" {
				t.Setenv("WATCHTOWER_AI_PROVIDER", c.env)
			}
			env := Env{ConfigPath: cfgPath}
			text, js := AILine(env, Resolve(env))
			if text != c.wantText || js != c.wantJS {
				t.Errorf("AI line %q / json %q, want %q / %q", text, js, c.wantText, c.wantJS)
			}
			if strings.Contains(text, canary) || strings.Contains(js, canary) {
				t.Errorf("raw value printed: %q / %q", text, js)
			}
		})
	}
}

// legacyGated are the features ApplyLegacyDigestOff turns off, plus
// slack-digests (digest.enabled itself is false on a legacy config).
var legacyGated = []string{
	"secretary-inbox", "slack-digests", "stream-digests", "tracks", "people-cards",
	"ideas", "memory", "briefing", "day-plan", "next-step",
}

const legacyGatesOn = "inbox:\n  enabled: true\nstreams:\n  enabled: true\ntracks:\n  enabled: true\n" +
	"people:\n  enabled: true\nideas:\n  enabled: true\nmemory:\n  enabled: true\n" +
	"briefing:\n  enabled: true\nday_plan:\n  enabled: true\ntargets:\n  next_step:\n    enabled: true\n"

func featureIDs(line string) map[string]bool {
	out := map[string]bool{}
	for _, id := range strings.Split(strings.TrimSuffix(line, FeaturesNotMigrated), ", ") {
		out[id] = true
	}
	return out
}

func TestDiagnostics_FeaturesLine(t *testing.T) {
	cfgPath, _ := testInstall(t)
	writeFile(t, cfgPath, "features:\n  migrated: true\ndigest:\n  enabled: true\n"+legacyGatesOn+
		"knowledge:\n  enabled: false\nreaction_commands:\n  enabled: false\n")
	env := Env{ConfigPath: cfgPath}
	got := FeaturesLine(Resolve(env), env)
	if strings.HasSuffix(got, FeaturesNotMigrated) {
		t.Errorf("migrated config marked unmigrated: %q", got)
	}
	ids := featureIDs(got)
	for _, id := range legacyGated {
		if !ids[id] {
			t.Errorf("%s missing from %q", id, got)
		}
	}
	for _, id := range []string{"knowledge-search", "reaction-commands", "targets", "chat"} {
		if ids[id] {
			t.Errorf("%s listed in %q", id, got)
		}
	}
	// Registry order: secretary-inbox comes before briefing, briefing before day-plan.
	if a, b, c := strings.Index(got, "secretary-inbox"), strings.Index(got, "briefing"), strings.Index(got, "day-plan"); a >= b || b >= c {
		t.Errorf("not in registry order: %q", got)
	}
}

func TestDiagnostics_FeaturesLegacyNotMigrated(t *testing.T) {
	cfgPath, _ := testInstall(t)
	body := "digest:\n  enabled: false\n" + legacyGatesOn
	writeFile(t, cfgPath, body)
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(cfgPath, old, old); err != nil {
		t.Fatal(err)
	}
	env := Env{ConfigPath: cfgPath}
	got := FeaturesLine(Resolve(env), env)
	if !strings.HasSuffix(got, FeaturesNotMigrated) {
		t.Errorf("legacy config not marked: %q", got)
	}
	ids := featureIDs(got)
	for _, id := range legacyGated {
		if ids[id] {
			t.Errorf("%s listed on a legacy config: %q", id, got)
		}
	}
	data, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, []byte(body)) {
		t.Errorf("config rewritten:\n%s", data)
	}
	if info, err := os.Stat(cfgPath); err != nil || !info.ModTime().Equal(old) {
		t.Errorf("config mtime changed: %v %v", info, err)
	}
}

func TestDiagnostics_FeaturesConfigGoneUnreadable(t *testing.T) {
	cfgPath, _ := testInstall(t)
	writeFile(t, cfgPath, "digest:\n  enabled: true\n")
	env := Env{ConfigPath: cfgPath}
	r := Resolve(env)
	unreadable(t, cfgPath)
	if got := FeaturesLine(r, env); got != UnknownNoConfig {
		t.Errorf("features %q, want %q", got, UnknownNoConfig)
	}
}

// TestDiagnostics_ProviderNamesPinned pins the registry's report names to
// the report's vocabulary in text.go, and requires every registered
// provider to have both (a new provider must fill them).
func TestDiagnostics_ProviderNamesPinned(t *testing.T) {
	want := map[string][2]string{
		"claude": {ProviderClaude, ProviderClaude},
		"codex":  {ProviderCodex, ProviderCodex},
		"ollama": {ProviderOllama, ProviderOllamaOption},
	}
	for _, p := range providers.All() {
		w, ok := want[p.ID]
		if !ok {
			t.Errorf("provider %q has no pinned report name here", p.ID)
			continue
		}
		if p.ReportName != w[0] || p.ReportOption != w[1] {
			t.Errorf("provider %q: report name %q / option %q, want %q / %q", p.ID, p.ReportName, p.ReportOption, w[0], w[1])
		}
	}
	if len(providers.All()) != len(want) {
		t.Errorf("registry has %d providers, pinned %d", len(providers.All()), len(want))
	}
}

func TestDiagnostics_ConfigWrongType(t *testing.T) {
	cfgPath, _ := testInstall(t)
	writeFile(t, cfgPath, "ai: 5\n")
	env := Env{ConfigPath: cfgPath}
	r := Resolve(env)
	if r.ConfigLine != ConfigUnreadableOther || r.ConfigState != ConfigStateUnreadable {
		t.Fatalf("config line %q state %v", r.ConfigLine, r.ConfigState)
	}
	if text, js := AILine(env, r); text != UnknownNoConfig || js != "" {
		t.Errorf("AI line %q / %q", text, js)
	}
}

// TestDiagnostics_WorkspaceStatFailed: a data root without search
// permission makes the workspace folder's stat fail with EACCES, not
// "not exist" → lookup failed.
func TestDiagnostics_WorkspaceStatFailed(t *testing.T) {
	cfgPath, root := testInstall(t)
	writeFile(t, cfgPath, "active_workspace: alpha\n")
	addWorkspace(t, root, "alpha", true)
	skipIfRoot(t)
	if err := os.Chmod(root, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(root, 0o755) })
	r := Resolve(Env{ConfigPath: cfgPath})
	if r.WorkspaceLine != WorkspaceLookupFailed || r.WorkspaceReason != UnknownNoWorkspace {
		t.Errorf("workspace line %q reason %q", r.WorkspaceLine, r.WorkspaceReason)
	}
}

func TestDiagnostics_AILineRawReadFails(t *testing.T) {
	t.Run("config_ok", func(t *testing.T) {
		cfgPath, _ := testInstall(t)
		writeFile(t, cfgPath, "digest:\n  enabled: true\n")
		env := Env{ConfigPath: cfgPath}
		r := Resolve(env)
		unreadable(t, cfgPath)
		// The origin note is dropped rather than guessed.
		if text, js := AILine(env, r); text != ProviderClaude || js != ProviderClaude {
			t.Errorf("AI line %q / %q", text, js)
		}
	})
	t.Run("config_invalid", func(t *testing.T) {
		cfgPath, _ := testInstall(t)
		writeFile(t, cfgPath, "ai:\n  provider: codex\n  fallback:\n    provider: codex\n")
		env := Env{ConfigPath: cfgPath}
		r := Resolve(env)
		if r.ConfigState != ConfigStateInvalid {
			t.Fatalf("state %v", r.ConfigState)
		}
		unreadable(t, cfgPath)
		if text, js := AILine(env, r); text != UnknownNoConfig || js != "" {
			t.Errorf("AI line %q / %q", text, js)
		}
	})
}

func TestDiagnostics_FeaturesNone(t *testing.T) {
	cases := []struct{ name, yaml, want string }{
		{"migrated", "features:\n  migrated: true\n", FeaturesNone},
		{"legacy", "digest:\n  enabled: false\n", FeaturesNone + FeaturesNotMigrated},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfgPath, _ := testInstall(t)
			writeFile(t, cfgPath, c.yaml)
			// A zero Config has every gate off.
			r := Resolved{Cfg: &config.Config{}, ConfigState: ConfigStateOK, ConfigLine: ConfigOK}
			if got := FeaturesLine(r, Env{ConfigPath: cfgPath}); got != c.want {
				t.Errorf("features %q, want %q", got, c.want)
			}
		})
	}
}

func TestDiagnostics_FeaturesWithoutConfig(t *testing.T) {
	cases := []struct{ name, yaml string }{
		{"none", ""},
		{"invalid", "ai:\n  provider: " + canary + "\n"},
		{"unreadable", "ai: [unclosed\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfgPath, _ := testInstall(t)
			if c.yaml != "" {
				writeFile(t, cfgPath, c.yaml)
			}
			env := Env{ConfigPath: cfgPath}
			if got := FeaturesLine(Resolve(env), env); got != UnknownNoConfig {
				t.Errorf("features %q, want %q", got, UnknownNoConfig)
			}
		})
	}
}

func TestDiagnostics_FeaturesNoHome(t *testing.T) {
	r := Resolve(Env{})
	if got := FeaturesLine(r, Env{}); got != UnknownNoHome {
		t.Errorf("features %q", got)
	}
}

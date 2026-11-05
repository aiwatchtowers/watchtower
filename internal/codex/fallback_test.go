package codex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

func TestFailureEnvelopeIdentity(t *testing.T) {
	output := []byte(`{"type":"item.completed","item":{"type":"agent_message","text":"ok"},"error":{"message":"usage limit reached"}}` + "\n" + `{"type":"turn.completed"}`)
	if err := failedTurn("m", output); err != nil {
		t.Fatalf("content established CLI failure: %v", err)
	}
	if text, _, err := parseJSONLOutput(output); err != nil || text != "ok" {
		t.Fatalf("text=%q err=%v", text, err)
	}
}
func TestBatchIsolationOverrides(t *testing.T) {
	t.Setenv("CODEX_HOME", t.TempDir())
	args, _, path, err := buildArgs("codex", "m", "", "prompt")
	if path != "" {
		t.Fatal("unexpected prompt file")
	}
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, " ")
	for _, flag := range []string{`web_search="disabled"`, "mcp_servers={", "features.hooks=false", "features.codex_hooks=false", "features.multi_agent=false", "features.code_mode=false", "features.code_mode_host=false", "features.goals=false"} {
		if !strings.Contains(joined, flag) {
			t.Errorf("missing %s: %s", flag, joined)
		}
	}
}

func TestGeneratorQuotaTypedAcrossExitCodes(t *testing.T) {
	for _, code := range []int{0, 1} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			body := `{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":429,\"error\":{\"type\":\"usage_limit_reached\",\"resets_at\":1700003600,\"message\":\"limit\"}}"}}`
			bin := fakeCodexRun(t, body, "", code)
			g := NewCodexGenerator("m", "m", bin)
			g.SetIsolatedChild()
			_, _, _, err := g.Generate(context.Background(), "", "prompt", "")
			var failure *providers.Failure
			if !errors.As(err, &failure) || failure.Category != providers.Quota || failure.ResetAt.Unix() != 1700003600 {
				t.Fatalf("failure=%+v err=%v", failure, err)
			}
			var exit *exec.ExitError
			if code != 0 && !errors.As(err, &exit) {
				t.Fatal("lost CLI exit cause")
			}
			client := NewClient("m", "", bin)
			client.SetProcessGroup(true)
			_, _, err = client.QuerySync(context.Background(), "", "prompt", "")
			if !errors.As(err, &failure) || failure.Category != providers.Quota {
				t.Fatalf("client failure=%+v err=%v", failure, err)
			}
		})
	}
}
func TestSuccessfulTurnClearsEarlierError(t *testing.T) {
	body := []byte(`{"type":"error","message":"You’ve hit your usage limit. Try again later."}` + "\n" + `{"type":"turn.started"}` + "\n" + `{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}` + "\n" + `{"type":"turn.completed"}`)
	if err := failedTurn("m", body); err != nil {
		t.Fatal(err)
	}
	if text, _, err := parseJSONLOutput(body); text != "ok" || err != nil {
		t.Fatalf("text=%q err=%v", text, err)
	}
}

func TestBatchDisablesMergedConfigAndPreservesTransport(t *testing.T) {
	home := t.TempDir()
	system := t.TempDir()
	work := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	previous := systemConfigDir
	systemConfigDir = system
	t.Cleanup(func() { systemConfigDir = previous })
	owner := `model_provider="custom"
[model_providers.custom]
base_url="https://models.example.com/v1"
[mcp_servers.personal]
command="owner-server"
`
	for path, content := range map[string]string{
		filepath.Join(home, "config.toml"):           owner,
		filepath.Join(system, "managed_config.toml"): "[mcp_servers.managed]\ncommand=\"managed-server\"\n",
		filepath.Join(work, ".codex", "config.toml"): "[mcp_servers.project]\ncommand=\"project-server\"\n",
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	args, err := noToolsArgs(providers.BatchText, "m", work)
	if err != nil {
		t.Fatal(err)
	}
	var override string
	for i, a := range args {
		if a == "-c" && i+1 < len(args) && strings.HasPrefix(args[i+1], "mcp_servers=") {
			override = args[i+1]
		}
	}
	servers := overrideServers(t, override)
	for _, name := range []string{"personal", "managed", "project"} {
		if servers[name]["enabled"] != false {
			t.Fatalf("server %s inherited: %s", name, override)
		}
	}
	contents, err := os.ReadFile(filepath.Join(home, "config.toml"))
	if err != nil || string(contents) != owner {
		t.Fatal("changed owner transport config")
	}
	// Both historical bool-map and current bool-or-object feature schemas
	// accept scalar false. Never emit a nested .enabled setting for these keys.
	joined := strings.Join(args, " ")
	for _, key := range []string{"code_mode", "code_mode_host", "goals", "codex_hooks"} {
		if !strings.Contains(joined, "features."+key+"=false") || strings.Contains(joined, "features."+key+".enabled") {
			t.Fatalf("incompatible feature override %s: %s", key, joined)
		}
	}
	if os.Getenv("CODEX_HOME") != home {
		t.Fatal("changed authentication home")
	}
}
func TestUnreadableBatchConfigFailsClosed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read permission-denied files")
	}
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	path := filepath.Join(home, "config.toml")
	if err := os.WriteFile(path, []byte("[mcp_servers.hidden]\ncommand=\"owner-server\"\n"), 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o600) })
	_, err := noToolsArgs(providers.BatchText, "m", t.TempDir())
	var failure *providers.Failure
	if !errors.As(err, &failure) || failure.Category != providers.Capability || !errors.Is(err, os.ErrPermission) {
		t.Fatalf("unreadable inherited MCP config accepted: %v", err)
	}
}

func TestBatchEnumeratesProjectServersWithConflictingRootMarkers(t *testing.T) {
	home, system, repo := t.TempDir(), t.TempDir(), t.TempDir()
	t.Setenv("CODEX_HOME", home)
	old := systemConfigDir
	systemConfigDir = system
	t.Cleanup(func() { systemConfigDir = old })
	write := func(path, content string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(home, "config.toml"), "project_root_markers=[\".user-root\"]\n")
	write(filepath.Join(system, "config.toml"), "project_root_markers=[\".system-root\"]\n")
	write(filepath.Join(repo, ".user-root"), "")
	write(filepath.Join(repo, ".codex", "config.toml"), "[mcp_servers.parent]\ncommand=\"parent-server\"\n")
	work := filepath.Join(repo, "child")
	write(filepath.Join(work, ".system-root"), "")
	args, err := noToolsArgs(providers.BatchText, "m", work)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(args, " "), `"parent"={enabled=false}`) {
		t.Fatalf("system marker hid a user-selected parent MCP server: %v", args)
	}
}

func TestBatchChildKeepsAuthAndTransportWithoutTools(t *testing.T) {
	home, capture := t.TempDir(), t.TempDir()
	t.Setenv("CODEX_HOME", home)
	t.Setenv("WT_PROFILE_CAPTURE", capture)
	t.Setenv("OPENAI_BASE_URL", "https://models.example.com/v1")
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte("[mcp_servers.personal]\ncommand=\"owner-server\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(t.TempDir(), "codex")
	script := `#!/bin/sh
printf '%s\n' "$@" >"$WT_PROFILE_CAPTURE/args"
printf '%s' "$CODEX_HOME" >"$WT_PROFILE_CAPTURE/home"
printf '%s' "$OPENAI_BASE_URL" >"$WT_PROFILE_CAPTURE/transport"
cat >"$WT_PROFILE_CAPTURE/stdin"
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}' '{"type":"turn.completed"}'
`
	if err := os.WriteFile(bin, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	gen := NewCodexGenerator("m", "m", bin)
	gen.SetIsolatedChild()
	if _, _, _, err := gen.Generate(context.Background(), "system-marker", "user-marker", ""); err != nil {
		t.Fatal(err)
	}
	read := func(name string) string {
		t.Helper()
		b, err := os.ReadFile(filepath.Join(capture, name))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	args := read("args")
	for _, flag := range []string{`"personal"={enabled=false}`, `web_search="disabled"`, "features.shell_tool=false", "features.hooks=false", "features.codex_hooks=false", "features.apps=false", "features.plugins=false", "features.code_mode=false"} {
		if !strings.Contains(args, flag) {
			t.Errorf("missing %s: %s", flag, args)
		}
	}
	if strings.Contains(args, "system-marker") || strings.Contains(args, "user-marker") {
		t.Fatal("prompt reached argv")
	}
	if read("home") != home || read("transport") != "https://models.example.com/v1" || read("stdin") != "user-marker" {
		t.Fatal("authentication/transport/stdin changed")
	}
}

// The generator's normalized quota cause and the timeout decorator's legacy
// retry marker have different consumers. Keep both for the actual 429 CLI
// envelope, including older envelopes without the redundant nested type.
func TestQuotaStatus429RetainsHistoricalMarker(t *testing.T) {
	for _, tc := range []struct {
		name        string
		includeType bool
	}{
		{"legacy_without_inner_type", false},
		{"with_inner_error_type", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := map[string]any{"status": 429, "error": map[string]any{"type": "usage_limit_reached", "message": "quota exhausted"}}
			if tc.includeType {
				body["type"] = "error"
			}
			message, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			event, err := json.Marshal(map[string]any{"type": "turn.failed", "error": map[string]any{"message": string(message)}})
			if err != nil {
				t.Fatal(err)
			}
			leaf := NewCodexGenerator("m", "m", fakeCodexRun(t, string(event), "", 1))
			leaf.SetIsolatedChild()
			_, _, _, err = digest.WithCallTimeout(leaf, 5*time.Second).Generate(context.Background(), "", "request", "")
			if !errors.Is(err, digest.ErrAICall) {
				t.Errorf("lost historical unavailable marker: %v", err)
			}
			if !strings.Contains(logredact.Full(err), "status code 429") {
				t.Errorf("lost structured HTTP diagnostic: %s", logredact.Full(err))
			}
			var failure *providers.Failure
			if !errors.As(err, &failure) || failure.Category != providers.Quota {
				t.Errorf("lost typed subscription quota: %+v", failure)
			}
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 1 {
				t.Errorf("lost CLI exit cause: %v", err)
			}
		})
	}
}

func TestQuotaEnvelopeRejectsNonErrorTypes(t *testing.T) {
	for _, innerType := range []string{"assistant", "tool"} {
		t.Run(innerType, func(t *testing.T) {
			body := map[string]any{"type": innerType, "status": 429, "error": map[string]any{"type": "usage_limit_reached", "message": "quota exhausted"}}
			message, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			event, err := json.Marshal(map[string]any{"type": "turn.failed", "error": map[string]any{"message": string(message)}})
			if err != nil {
				t.Fatal(err)
			}
			leaf := NewCodexGenerator("m", "m", fakeCodexRun(t, string(event), "", 1))
			leaf.SetIsolatedChild()
			_, _, _, err = digest.WithCallTimeout(leaf, 5*time.Second).Generate(context.Background(), "", "request", "")
			var failure *providers.Failure
			if errors.As(err, &failure) && failure.Category == providers.Quota {
				t.Fatalf("non-error payload established quota: %v", err)
			}
		})
	}
}

// Codex rust-v0.166.0 core/src/session/session.rs constructs ShellSnapshot
// with ShellTool off; shell_snapshot.rs::new is lazy, build/try_create can
// launch the shell helper. No-tools profiles must disable both snapshot gates.
func TestNoToolsDisablesIndependentShellSnapshot(t *testing.T) {
	t.Setenv("CODEX_HOME", t.TempDir())
	for _, profile := range []providers.InvocationProfile{providers.BatchText, providers.Image} {
		args, err := noToolsArgs(profile, "m", t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		for _, flag := range []string{"features.shell_snapshot=false", "features.shell_snapshot_v2=false"} {
			found := false
			for _, arg := range args {
				if arg == flag {
					found = true
				}
			}
			if !found {
				t.Errorf("%s lacks independent snapshot disable %s", profile, flag)
			}
		}
	}
}

// This fake models the independent snapshot gate, not a real login shell.
// Source: codex rust-v0.166.0 core/src/session/session.rs:1429-1455 and
// core/src/shell_snapshot.rs (new configures; build/try_create runs helpers).
func TestNoToolsFakeSnapshotHelperCannotRun(t *testing.T) {
	t.Setenv("CODEX_HOME", t.TempDir())
	capture := t.TempDir()
	t.Setenv("WT_SNAPSHOT_CAPTURE", capture)
	bin := filepath.Join(t.TempDir(), "codex")
	script := `#!/bin/sh
snapshot=enabled
snapshot_v2=enabled
for arg in "$@"; do
 case "$arg" in
 features.shell_snapshot=false) snapshot=disabled;;
 features.shell_snapshot_v2=false) snapshot_v2=disabled;;
 esac
done
if [ "$snapshot" = enabled ] || [ "$snapshot_v2" = enabled ]; then
 printf helper >"$WT_SNAPSHOT_CAPTURE/helper"
fi
cat >/dev/null
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}' '{"type":"turn.completed"}'
`
	if err := os.WriteFile(bin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	// Prove the fake catches shell_tool=false without independent snapshot flags.
	// The deadline is only a hang guard over three short stub runs; a tight
	// one fails a correct run on a loaded machine.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "-c", "features.shell_tool=false")
	digest.IsolateChild(cmd, nil)
	if _, err := cmd.Output(); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(capture, "helper")
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("fake did not model the independent helper", err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	gen := NewCodexGenerator("m", "m", bin)
	gen.SetIsolatedChild()
	if _, _, _, err := gen.Generate(ctx, "", "prompt", ""); err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(t.TempDir(), "image.png")
	if err := os.WriteFile(image, []byte("fake-image"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := gen.GenerateWithImage(digest.WithWorkDir(ctx, t.TempDir()), "", "prompt", image, "image/png"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("snapshot helper ran in no-tools profile", err)
	}
}

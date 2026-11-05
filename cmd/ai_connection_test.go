package cmd

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/policy/policytest"
)

func TestAIConnectionStrictUnsavedProbeBothProviders(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		for _, fails := range []bool{false, true} {
			t.Run(provider+map[bool]string{false: "/success", true: "/quota"}[fails], func(t *testing.T) {
				policytest.Set(t, nil)
				t.Setenv("HOME", t.TempDir())
				t.Setenv("CODEX_HOME", t.TempDir())
				var bin string
				if provider == "codex" && !fails {
					bin = nonceEchoCodexCLI(t)
				} else {
					bin = routingCLI(t, provider, fails)
				}
				capture := filepath.Join(t.TempDir(), "arguments")
				source, err := os.ReadFile(bin)
				require.NoError(t, err)
				source = []byte(strings.Replace(string(source), "cat >/dev/null", "printf '%s\\n' \"$@\" > '"+capture+"'\ncat >/dev/null", 1))
				require.NoError(t, os.WriteFile(bin, source, 0700))
				cfg := filepath.Join(t.TempDir(), "config.yaml")
				// A live reserve would mask a failing selected provider. It must not run.
				reserve := "claude"
				if provider == reserve {
					reserve = "codex"
				}
				config := "ai:\n  provider: " + provider + "\n  fallback: {enabled: true, provider: " + reserve + "}\n  providers:\n    " + provider + ": {models: {strong: saved-model}}\n"
				require.NoError(t, os.WriteFile(cfg, []byte(config), 0600))
				before, err := os.ReadFile(cfg)
				require.NoError(t, err)
				p := startCLI(t, "--config", cfg, "--provider", provider, "ai", "test", "--model", "unsaved-model", "--cli-path", bin)
				var lines []string
				for line := range p.lines {
					lines = append(lines, line)
				}
				require.NoError(t, p.wait())
				var result struct {
					OK                     bool `json:"ok"`
					Provider, Model, Error string
				}
				require.NoError(t, json.Unmarshal([]byte(strings.Join(lines, "\n")), &result))
				require.Equal(t, !fails, result.OK)
				require.Equal(t, provider, result.Provider)
				require.Equal(t, "unsaved-model", result.Model)
				args, err := os.ReadFile(capture)
				require.NoError(t, err)
				text := string(args)
				require.Contains(t, text, "unsaved-model")
				require.NotContains(t, text, "\nsaved-model\n")
				if provider == "claude" {
					for _, flag := range []string{"--strict-mcp-config", "--disable-slash-commands", `{"disableAllHooks":true}`, "--setting-sources\nproject,local", "--tools\n\n"} {
						require.Contains(t, text, flag)
					}
				} else {
					for _, flag := range []string{"--ephemeral", `mcp_servers={`, "features.hooks=false", "features.multi_agent=false", `web_search="disabled"`} {
						require.Contains(t, text, flag)
					}
				}
				after, err := os.ReadFile(cfg)
				require.NoError(t, err)
				require.Equal(t, before, after)
				if fails {
					require.Contains(t, result.Error, "subscription_quota")
					require.NotContains(t, result.Error, bin)
				}
			})
		}
	}
}

// nonceEchoCodexCLI is a fake codex that answers with the probe nonce it
// finds in its model_instructions_file — the answer a real codex gives when
// the system prompt reaches the model.
func nonceEchoCodexCLI(t *testing.T) string {
	t.Helper()
	return nonceEchoCodexCLIWith(t, "cat")
}

// nonceEchoCodexCLIWith is nonceEchoCodexCLI with the nonce passed through
// filter (a shell pipeline stage) before it is answered.
func nonceEchoCodexCLIWith(t *testing.T, filter string) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "codex")
	script := `#!/bin/sh
if [ "$1" = --version ]; then echo 'codex-cli 0.166.0'; exit; fi
f=
for a in "$@"; do
 case "$a" in model_instructions_file=*) f=${a#model_instructions_file=}; f=${f#\"}; f=${f%\"};; esac
done
nonce=$(grep -o 'wt-probe-[A-Z2-7]*' "$f" | head -1 | ` + filter + `)
cat >/dev/null
printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\n' "$nonce"
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":3}}'
`
	require.NoError(t, os.WriteFile(bin, []byte(script), 0o700))
	return bin
}

// The codex connection test goes through the real system-prompt path: the
// prompt names a nonce, delivered as the model_instructions_file, and an
// answer without it fails the test (#669 shipped with a green Test
// Connection because the probe sent no system prompt at all).
func TestAIConnectionCodexChecksSystemPromptNonce(t *testing.T) {
	// A model that lowercases the nonce still proves the prompt arrived.
	for name, filter := range map[string]string{"nonce": "cat", "lowercased nonce": "tr A-Z a-z", "no nonce": ""} {
		nonceEcho := filter != ""
		t.Run(name, func(t *testing.T) {
			policytest.Set(t, nil)
			t.Setenv("HOME", t.TempDir())
			t.Setenv("CODEX_HOME", t.TempDir())
			bin := routingCLI(t, "codex", false) // answers "ok"
			if nonceEcho {
				bin = nonceEchoCodexCLIWith(t, filter)
			}
			cfg := filepath.Join(t.TempDir(), "config.yaml")
			require.NoError(t, os.WriteFile(cfg, []byte("ai: {provider: codex}"), 0o600))
			p := startCLI(t, "--config", cfg, "--provider", "codex", "ai", "test", "--model", "form-model", "--cli-path", bin)
			line, ok := p.next(t, 10*time.Second)
			require.True(t, ok)
			require.NoError(t, p.wait())
			var result map[string]any
			require.NoError(t, json.Unmarshal([]byte(line), &result))
			require.Equal(t, nonceEcho, result["ok"], line)
			if !nonceEcho {
				require.Equal(t, "invalid_output", result["error_code"], line)
				// The owner reads what went wrong and what to do; the code
				// stays the classification the Desktop switches on.
				require.Equal(t, "Codex answered but ignored Watchtower's instructions. Update the Codex CLI, or check its config, and test again.", result["error"], line)
			}
		})
	}
}

func TestAIConnectionOllamaCompatibility(t *testing.T) {
	policytest.Set(t, nil)
	t.Setenv("HOME", t.TempDir())
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/v1/chat/completions", r.URL.Path)
		var body struct {
			Model string `json:"model"`
		}
		require.NoError(t, json.NewDecoder(r.Body).Decode(&body))
		require.Equal(t, "local-form-model", body.Model)
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":2,"completion_tokens":1}}`))
	}))
	defer server.Close()
	cfg := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(cfg, []byte("ai: {provider: ollama, ollama_url: '"+server.URL+"'}"), 0600))
	p := startCLI(t, "--config", cfg, "--provider", "ollama", "ai", "test", "--model", "local-form-model")
	line, ok := p.next(t, 10*time.Second)
	require.True(t, ok)
	require.NoError(t, p.wait())
	require.Contains(t, line, `"ok":true`)
	require.Equal(t, int32(1), calls.Load())
}

func TestConnectionErrorNeverExposesRawChildData(t *testing.T) {
	require.NotContains(t, connectionTestError(context.Canceled), "secret")
}

func TestAIConnectionCancellationKillsAndReapsCanonicalChild(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			policytest.Set(t, nil)
			t.Setenv("HOME", t.TempDir())
			t.Setenv("CODEX_HOME", t.TempDir())
			dir := t.TempDir()
			bin := filepath.Join(dir, provider)
			pidfile := filepath.Join(dir, "child.pid")
			script := "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli 0.166.0'; exit; fi\necho $$ > '" + pidfile + "'\nexec /bin/sleep 60\n"
			require.NoError(t, os.WriteFile(bin, []byte(script), 0700))
			cfg := filepath.Join(dir, "config.yaml")
			require.NoError(t, os.WriteFile(cfg, []byte("ai: {provider: "+provider+"}"), 0600))
			p := startCLI(t, "--config", cfg, "--provider", provider, "ai", "test", "--model", "cancel-model", "--cli-path", bin)
			child := 0
			t.Cleanup(func() {
				if child > 0 {
					_ = syscall.Kill(-child, syscall.SIGKILL)
				}
			})
			require.Eventually(t, func() bool {
				data, err := os.ReadFile(pidfile)
				if err != nil {
					return false
				}
				child, _ = strconv.Atoi(strings.TrimSpace(string(data)))
				return child > 0
			}, 10*time.Second, 10*time.Millisecond)
			require.NoError(t, p.cmd.Process.Signal(syscall.SIGTERM))
			var result string
			for line := range p.lines {
				result += line
			}
			require.NoError(t, p.wait())
			require.Contains(t, result, `"ok":false`)
			require.Equal(t, syscall.ESRCH, syscall.Kill(child, 0), "the leaf must be waited, not left as a zombie")
		})
	}
}

func TestAIConnectionTypedAuthDoesNotLeakChildDetails(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			policytest.Set(t, nil)
			t.Setenv("HOME", t.TempDir())
			t.Setenv("CODEX_HOME", t.TempDir())
			dir := t.TempDir()
			bin := filepath.Join(dir, provider)
			cfg := filepath.Join(dir, "config.yaml")
			response := `{"type":"result","subtype":"error_during_execution","is_error":true,"error":{"type":"authentication_error"},"result":"private account detail"}`
			if provider == "codex" {
				response = `{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":401,\"error\":{\"type\":\"authentication_error\",\"message\":\"private account detail\"}}"}}`
			}
			script := "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli 0.166.0'; exit; fi\ncat >/dev/null\nprintf '%s\\n' '" + response + "'\n"
			require.NoError(t, os.WriteFile(bin, []byte(script), 0700))
			require.NoError(t, os.WriteFile(cfg, []byte("ai: {provider: "+provider+"}"), 0600))
			p := startCLI(t, "--config", cfg, "--provider", provider, "ai", "test", "--model", "form-model", "--cli-path", bin)
			line, ok := p.next(t, 10*time.Second)
			require.True(t, ok)
			require.NoError(t, p.wait())
			require.Contains(t, line, `"error_code":"auth"`)
			require.NotContains(t, line, "private account detail")
		})
	}
}

func TestAIConnectionPolicyRefusesBeforeChildStart(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedAIProviders": []string{}})
	dir := t.TempDir()
	marker := filepath.Join(dir, "started")
	bin := filepath.Join(dir, "claude")
	cfg := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(bin, []byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0700))
	require.NoError(t, os.WriteFile(cfg, []byte("ai: {provider: claude}"), 0600))
	oldConfig, oldPath, oldModel, oldProvider := flagConfig, aiTestCLIPath, aiFlagModel, flagProvider
	t.Cleanup(func() {
		flagConfig, aiTestCLIPath, aiFlagModel, flagProvider = oldConfig, oldPath, oldModel, oldProvider
	})
	flagConfig, aiTestCLIPath, aiFlagModel, flagProvider = cfg, bin, "form-model", "claude"
	output := captureStdout(t, func() { require.NoError(t, runAITest(aiTestCmd, nil)) })
	require.Contains(t, output, `"error_code":"policy"`)
	_, err := os.Stat(marker)
	require.ErrorIs(t, err, os.ErrNotExist)
}

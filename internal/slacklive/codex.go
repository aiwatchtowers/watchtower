package slacklive

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"watchtower/internal/codex"
)

const codexListTool = "slack_list_workspaces"

const codexProbePrompt = `Call the slack_list_workspaces tool exactly once, then reply with the single word done. Do not call any other tool.`

var teamIDPattern = regexp.MustCompile(`\bT[A-Z0-9]{7,}\b`)

func hasDigit(s string) bool { return strings.ContainsAny(s, "0123456789") }

// codexHome is the CODEX_HOME the child will see: from env, else the
// process's, else ~/.codex.
func codexHome(env []string) string {
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "CODEX_HOME="); ok && v != "" {
			return v
		}
	}
	if v := os.Getenv("CODEX_HOME"); v != "" && env == nil {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex")
}

// codexAPIKeyLogin reports a present auth.json whose auth_mode is set and not a ChatGPT
// account (an API key never has the account's apps). A missing or unreadable
// file, or one with no auth_mode, is not a verdict: the call itself decides.
func codexAPIKeyLogin(home string) bool {
	b, err := os.ReadFile(filepath.Join(home, "auth.json"))
	if err != nil {
		return false
	}
	var a struct {
		AuthMode string `json:"auth_mode"`
	}
	if json.Unmarshal(b, &a) != nil {
		return false
	}
	return a.AuthMode != "" && a.AuthMode != "chatgpt"
}

// slackConnectorID reads the Slack app's connector id from Codex's own apps
// cache (<home>/cache/codex_apps_tools/*.json). Codex-internal and may change:
// "" means unknown, and Live then stays off.
func slackConnectorID(home string) string {
	files, _ := filepath.Glob(filepath.Join(home, "cache", "codex_apps_tools", "*.json"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var cache struct {
			Tools []struct {
				ConnectorID   string `json:"connector_id"`
				ConnectorName string `json:"connector_name"`
				ToolName      string `json:"tool_name"`
			} `json:"tools"`
		}
		if json.Unmarshal(b, &cache) != nil {
			continue
		}
		for _, t := range cache.Tools {
			if t.ConnectorName == "Slack" && t.ToolName == codexListTool && t.ConnectorID != "" {
				return t.ConnectorID
			}
		}
	}
	return ""
}

// workspaceTeamIDs reads the team ids of a slack_list_workspaces result:
// structured_content.teams[].id; only when structured_content is absent does
// it fall back to scanning the raw result for team-id-shaped tokens.
func workspaceTeamIDs(result json.RawMessage) []string {
	var r struct {
		Structured *struct {
			Teams []struct {
				ID string `json:"id"`
			} `json:"teams"`
		} `json:"structured_content"`
	}
	if json.Unmarshal(result, &r) == nil && r.Structured != nil {
		var ids []string
		for _, t := range r.Structured.Teams {
			if t.ID != "" {
				ids = append(ids, t.ID)
			}
		}
		return ids
	}
	var ids []string
	for _, id := range teamIDPattern.FindAllString(string(result), -1) {
		if hasDigit(id) {
			ids = append(ids, id)
		}
	}
	return ids
}

type codexEvent struct {
	Type    string          `json:"type"`
	Message string          `json:"message"`
	Error   json.RawMessage `json:"error"`
	Item    struct {
		Type   string          `json:"type"`
		Tool   string          `json:"tool"`
		Status string          `json:"status"`
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	} `json:"item"`
}

const codexWarmupPrompt = `Reply with the single word ok. Do not call any tool.`

// codexExecArgs is the exec shape every probe run uses; apps is the app
// section: the read-only allow-list, or the warm-up's "no tool callable".
func codexExecArgs(apps []string) []string {
	args := []string{"exec", "--json", "--ephemeral", "--skip-git-repo-check",
		"-c", "approval_policy=never", "-c", "sandbox_mode=read-only"}
	return append(append(args, apps...), "-")
}

// runCodex runs one exec with prompt on stdin until handle says stop, the
// turn completes or the child closes its output. It returns the child's
// stderr.
func runCodex(ctx context.Context, bin string, args, env []string, prompt string, handle func(codexEvent)) (stderr string, err error) {
	c, err := startChild(ctx, bin, args, env, nil)
	if err != nil {
		return "", err
	}
	defer c.stop()
	_ = c.write(prompt)
	_ = c.stdin.Close()
	for {
		select {
		case <-ctx.Done():
			return c.stderr.String(), nil
		case line, ok := <-c.lines:
			if !ok {
				return c.stderr.String(), nil
			}
			var ev codexEvent
			if json.Unmarshal([]byte(line), &ev) != nil {
				continue
			}
			handle(ev)
			if ev.Type == "turn.completed" {
				return c.stderr.String(), nil
			}
		}
	}
}

// ProbeCodex runs the real read call through the Codex Slack app, with only
// slack_list_workspaces callable. The app's connector id comes from Codex's
// own cache; when it is not cached yet one warm-up run (no tool callable)
// fills it, and a still-missing id fails closed. A cancelled ctx returns a
// zero-status Result.
func ProbeCodex(ctx context.Context, codexBin string, env []string) Result {
	res := Result{Provider: "codex"}
	home := codexHome(env)
	if codexAPIKeyLogin(home) {
		res.Status, res.ErrorClass = Classify("codex", SentinelAPIKeyLogin, false, false)
		return res
	}
	pctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	cancelled := func() bool { return ctx.Err() != nil }
	failed := func(stderr, tool string, connected, readOK bool) Result {
		if pctx.Err() != nil {
			tool += " timeout"
		}
		res.Status, res.ErrorClass = classify(tool, stderr, connected, readOK)
		return res
	}

	id := slackConnectorID(home)
	if id == "" {
		warm := codexExecArgs([]string{"-c", "features.apps=true", "-c", "apps._default.default_tools_enabled=false"})
		var tool strings.Builder
		stderr, err := runCodex(pctx, codexBin, warm, env, codexWarmupPrompt, func(ev codexEvent) {
			if ev.Type == "error" {
				tool.WriteString(" " + ev.Message)
			}
		})
		if cancelled() {
			return Result{Provider: "codex"}
		}
		if err != nil {
			res.Status, res.ErrorClass = StatusNotConnected, "cli_missing"
			return res
		}
		if id = slackConnectorID(home); id == "" {
			if pctx.Err() != nil {
				return failed(stderr, tool.String(), false, false)
			}
			res.Status, res.ErrorClass = StatusNotConnected, "connector_id_unknown"
			return res
		}
	}
	apps, err := codex.ReadOnlyAppOverrides(home, id, []string{codexListTool})
	if err != nil {
		res.Status, res.ErrorClass = StatusUnavailable, "config_unreadable"
		return res
	}

	connected, readOK := false, false
	var tool strings.Builder
	seen := map[string]bool{}
	stderr, err := runCodex(pctx, codexBin, codexExecArgs(apps), env, codexProbePrompt, func(ev codexEvent) {
		switch {
		case ev.Type == "item.completed" && ev.Item.Type == "mcp_tool_call" &&
			strings.HasSuffix(ev.Item.Tool, codexListTool):
			connected = true
			if ev.Item.Status == "completed" {
				readOK = true
				for _, tid := range workspaceTeamIDs(ev.Item.Result) {
					if !seen[tid] {
						seen[tid] = true
						res.Teams = append(res.Teams, tid)
					}
				}
			} else {
				tool.WriteString(" " + string(ev.Item.Error) + " " + string(ev.Item.Result))
			}
		case ev.Type == "error":
			tool.WriteString(" " + ev.Message)
		case ev.Type == "turn.failed":
			tool.WriteString(" " + string(ev.Error))
		}
	})
	if cancelled() {
		return Result{Provider: "codex"}
	}
	if err != nil {
		res.Status, res.ErrorClass = StatusNotConnected, "cli_missing"
		return res
	}
	res = failed(stderr, tool.String(), connected, readOK)
	if res.Status == StatusOK {
		res.ConnectorID = id
	}
	return res
}

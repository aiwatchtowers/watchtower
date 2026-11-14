package slacklive

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const codexListTool = "slack_list_workspaces"

const codexProbePrompt = `Call the slack_list_workspaces tool exactly once, then reply with the single word done. Do not call any other tool.`

var teamIDPattern = regexp.MustCompile(`\bT[A-Z0-9]{7,}\b`)

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

// codexAPIKeyLogin reports a present auth.json whose login is not a ChatGPT
// account (an API key never has the account's apps). A missing or unreadable
// file is not a verdict: the call itself decides.
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
	return a.AuthMode != "chatgpt"
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
	return teamIDPattern.FindAllString(string(result), -1)
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

// ProbeCodex runs the real read call through the Codex Slack app. A
// cancelled ctx returns a zero-status Result.
func ProbeCodex(ctx context.Context, codexBin string, env []string) Result {
	res := Result{Provider: "codex"}
	home := codexHome(env)
	if codexAPIKeyLogin(home) {
		res.Status, res.ErrorClass = Classify("codex", SentinelAPIKeyLogin, false, false)
		return res
	}
	pctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	c, err := startChild(pctx, codexBin, []string{"exec", "--json", "--ephemeral", "--skip-git-repo-check",
		"-c", "approval_policy=never", "-c", "sandbox_mode=read-only", "-c", "features.apps=true", "-"}, env, nil)
	if err != nil {
		res.Status, res.ErrorClass = StatusNotConnected, "cli_missing"
		return res
	}
	defer c.stop()
	_ = c.write(codexProbePrompt)
	_ = c.stdin.Close()

	connected, readOK := false, false
	var text strings.Builder
	seen := map[string]bool{}
loop:
	for {
		select {
		case <-pctx.Done():
			break loop
		case line, ok := <-c.lines:
			if !ok {
				break loop
			}
			var ev codexEvent
			if json.Unmarshal([]byte(line), &ev) != nil {
				continue
			}
			switch {
			case ev.Type == "item.completed" && ev.Item.Type == "mcp_tool_call" &&
				strings.HasSuffix(ev.Item.Tool, codexListTool):
				connected = true
				if ev.Item.Status == "completed" {
					readOK = true
					for _, id := range workspaceTeamIDs(ev.Item.Result) {
						if !seen[id] {
							seen[id] = true
							res.Teams = append(res.Teams, id)
						}
					}
				} else {
					text.WriteString(" " + string(ev.Item.Error) + " " + string(ev.Item.Result))
				}
			case ev.Type == "error":
				text.WriteString(" " + ev.Message)
			case ev.Type == "turn.failed":
				text.WriteString(" " + string(ev.Error))
			case ev.Type == "turn.completed":
				break loop
			}
		}
	}
	if ctx.Err() != nil {
		return Result{Provider: "codex"}
	}
	if pctx.Err() != nil {
		text.WriteString(" timeout")
	}
	text.WriteString(" " + c.stderr.String())
	res.Status, res.ErrorClass = Classify("codex", text.String(), connected, readOK)
	if res.Status == StatusOK {
		if res.ConnectorID = slackConnectorID(home); res.ConnectorID == "" {
			res.Status, res.ErrorClass = StatusNotConnected, "connector_id_unknown"
		}
	}
	return res
}

package ai

import (
	"encoding/json"
	"strings"
)

// Claude in Chrome on the connect surface (agent connect spec §5.2, §10
// "Task 0 outcome" S1–S3). Checked with Claude Code 2.1.330.
const (
	// BrowserToolsToken allows every Claude in Chrome tool, the probe's
	// list_connected_browsers among them (S1, S3.argv).
	BrowserToolsToken = "mcp__claude-in-chrome__*"
	// BrowserNavigateTool is the tool the host guard hook watches (S2).
	BrowserNavigateTool = "mcp__claude-in-chrome__navigate"
	// BrowserDeniedTools are hidden from a browser run (S2's deny list):
	// browser_batch can nest navigate calls the hook does not see,
	// javascript_tool could set location, and the uploads have no place in
	// a connect run.
	BrowserDeniedTools = "mcp__claude-in-chrome__browser_batch,mcp__claude-in-chrome__javascript_tool," +
		"mcp__claude-in-chrome__file_upload,mcp__claude-in-chrome__upload_image"
	// BrowserGuardCommand is the watchtower verb the navigate hook runs
	// (cmd's `ai connect-guard`), one --host per allowed host.
	BrowserGuardCommand = "ai connect-guard"
)

// withBrowserTools appends extra to a comma-separated tool list on a
// browser run only.
func (c *Client) withBrowserTools(list, extra string) string {
	if !c.browser {
		return list
	}
	if list == "" {
		return extra
	}
	return list + "," + extra
}

// browserSettings is the --settings JSON of a browser run: a PreToolUse
// hook on navigate that runs this binary's connect guard over hosts (S2).
// It holds no secret, so it goes inline. A host reached by a click, a form
// post or a redirect is not seen by the hook; that stays the prompt's rule.
func browserSettings(hosts []string) string {
	cmd := shellQuote(watchtowerBinary()) + " " + BrowserGuardCommand
	for _, h := range hosts {
		cmd += " --host " + shellQuote(h)
	}
	settings := map[string]any{
		"hooks": map[string]any{
			"PreToolUse": []any{map[string]any{
				"matcher": BrowserNavigateTool,
				"hooks":   []any{map[string]any{"type": "command", "command": cmd}},
			}},
		},
	}
	data, _ := json.Marshal(settings) // strings and maps only: it cannot fail
	return string(data)
}

// shellQuote quotes s for /bin/sh, which runs a hook's command.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

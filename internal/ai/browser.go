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

// BrowserProbeTool is the probe turn's one allowed tool (S1): the run
// asks Claude in Chrome which browsers are connected, nothing else.
const BrowserProbeTool = "mcp__claude-in-chrome__list_connected_browsers"

// browserToolNames are Claude in Chrome's tools (the 20 the S1/S3 init
// events listed, Claude Code 2.1.330), list_connected_browsers among them.
var browserToolNames = []string{
	"browser_batch", "computer", "file_upload", "find", "form_input", "get_page_text", "gif_creator",
	"javascript_tool", "list_connected_browsers", "navigate", "read_console_messages", "read_network_requests",
	"read_page", "resize_window", "select_browser", "switch_browser", "tabs_close_mcp", "tabs_context_mcp",
	"tabs_create_mcp", "upload_image",
}

// BrowserProbeDeniedTools hides every Claude in Chrome tool but
// BrowserProbeTool from the probe: --allowedTools alone would leave them in
// the model's list (and navigate there has no host guard). A tool a later
// extension adds is still not allowed, only not hidden.
var BrowserProbeDeniedTools = func() string {
	var denied []string
	for _, name := range browserToolNames {
		if tool := "mcp__claude-in-chrome__" + name; tool != BrowserProbeTool {
			denied = append(denied, tool)
		}
	}
	return strings.Join(denied, ",")
}()

// browserDeniedTools is what a browser run (S2's list) or the probe (every
// browser tool but its own) adds to --disallowedTools.
func (c *Client) browserDeniedTools() string {
	if c.browserProbe {
		return BrowserProbeDeniedTools
	}
	return BrowserDeniedTools
}

// allowedToolsArg is the --allowedTools value: BrowserProbeTool alone on a
// probe; otherwise the run's tools, the browser's on a browser run.
func (c *Client) allowedToolsArg() string {
	if c.browserProbe {
		return BrowserProbeTool
	}
	return c.withStreamTools(c.withBrowserTools(c.allowedToolsFlag(), BrowserToolsToken), c.streamHooks.ExtraAllowed)
}

// withBrowserTools appends extra to a comma-separated tool list on a
// browser run (or the probe) only.
func (c *Client) withBrowserTools(list, extra string) string {
	if !c.browser && !c.browserProbe {
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

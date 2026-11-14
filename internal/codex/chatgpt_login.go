package codex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// ChatGPTLogin reports whether the codex home at codexHome is signed in with
// a ChatGPT account (auth.json auth_mode "chatgpt"): the only login whose
// apps (connectors) reach the owner's workspace. Any read or parse failure,
// and an API-key login, is false. Only the mode is read, never a token.
func ChatGPTLogin(codexHome string) bool {
	b, err := os.ReadFile(filepath.Join(codexHome, "auth.json"))
	if err != nil {
		return false
	}
	var a struct {
		Mode string `json:"auth_mode"`
	}
	if json.Unmarshal(b, &a) != nil {
		return false
	}
	return strings.EqualFold(a.Mode, "chatgpt")
}

// SlackReadOnlyOverrides is the `-c` pairs that leave exactly the listed
// tools of one connector visible to a codex run: every app off by default,
// the connector (by its id, not its namespace) on with its default tools off,
// then one `tools.<t>.enabled=true` per allowed tool. A write tool is simply
// not listed. Empty connectorID returns nil (apps stay off).
func SlackReadOnlyOverrides(connectorID string, tools []string) []string {
	if connectorID == "" {
		return nil
	}
	args := []string{
		"-c", "apps._default.enabled=false",
		"-c", "apps." + connectorID + ".enabled=true",
		"-c", "apps." + connectorID + ".default_tools_enabled=false",
	}
	for _, t := range tools {
		args = append(args, "-c", "apps."+connectorID+".tools."+t+".enabled=true")
	}
	return args
}

// SetChatApps lets this client's runs use the apps feature, restricted to
// overrides (SlackReadOnlyOverrides). Used by the chat session only; every
// other client keeps `apps` off (disabledFeatures).
func (c *Client) SetChatApps(overrides []string) {
	if len(overrides) > 0 {
		c.appsOverrides = overrides
	}
}

package codex

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"watchtower/internal/ai"
)

// OwnerHome is the owner's own codex home: CODEX_HOME, else ~/.codex.
func OwnerHome() string {
	if v := os.Getenv("CODEX_HOME"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex")
}

// newRunHome is the CODEX_HOME of one run that mounts the watchtower
// server: a fresh 0700 temp folder the caller removes after the run. Its
// 0600 config.toml turns web search off and declares only the watchtower
// server (dbPath, extra, envVars as in WatchtowerServerTOML) and the owner's
// enabled Quick Connections (external) — so no MCP server of the owner's own
// ~/.codex/config.toml and no web search reach a child that reads synced
// content, the twin of the claude chat's --strict-mcp-config. A connection's
// secret (env, headers) sits only in this 0600 file, never on argv (QC-03).
// The owner's auth.json is linked, never copied, so codex can sign in;
// removing the folder removes only the link.
func newRunHome(dbPath string, extra, envVars []string, external []ai.ExternalMCPServer) (string, error) {
	dir, err := os.MkdirTemp("", "wt-codex-home-*")
	if err != nil {
		return "", fmt.Errorf("creating the codex home: %w", err)
	}
	config := "web_search = \"disabled\"\n\n" + WatchtowerServerTOML(dbPath, extra, envVars) + externalServersTOML(external)
	if err := os.WriteFile(filepath.Join(dir, "config.toml"), []byte(config), 0o600); err != nil {
		_ = os.RemoveAll(dir)
		return "", fmt.Errorf("writing the codex config: %w", err)
	}
	auth := filepath.Join(OwnerHome(), "auth.json")
	if _, err := os.Stat(auth); err == nil {
		if err := os.Symlink(auth, filepath.Join(dir, "auth.json")); err != nil {
			_ = os.RemoveAll(dir)
			return "", fmt.Errorf("linking the codex sign-in: %w", err)
		}
	}
	return dir, nil
}

// externalServersTOML is one [mcp_servers.<name>] table per Quick
// Connection. enabled_tools is the QC-02 allow list: codex runs with
// approvals off, so every other tool of the server — denied, or listed after
// the last tools/list — stays hidden rather than callable. Names are
// [A-Za-z0-9_-] (connectionNamePattern), so they need no quoting.
func externalServersTOML(servers []ai.ExternalMCPServer) string {
	var b strings.Builder
	for _, s := range servers {
		fmt.Fprintf(&b, "\n[mcp_servers.%s]\n", s.Name)
		if s.Kind == "http" {
			fmt.Fprintf(&b, "url = %s\n", tomlString(s.URL))
			if len(s.Headers) > 0 {
				fmt.Fprintf(&b, "http_headers = %s\n", tomlInlineTable(s.Headers))
			}
		} else {
			fmt.Fprintf(&b, "command = %s\n", tomlString(s.Command))
			fmt.Fprintf(&b, "args = %s\n", tomlArray(s.Args))
			if len(s.Env) > 0 {
				fmt.Fprintf(&b, "env = %s\n", tomlInlineTable(s.Env))
			}
		}
		fmt.Fprintf(&b, "enabled_tools = %s\n", tomlArray(s.AllowTools))
	}
	return b.String()
}

// tomlString is s as a TOML basic string. strconv.Quote is not TOML (it
// emits \x and \a escapes), so control characters become \uXXXX and invalid
// UTF-8 the replacement character.
func tomlString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i, r := range s {
		if r == utf8.RuneError {
			if _, size := utf8.DecodeRuneInString(s[i:]); size == 1 {
				b.WriteString(`�`)
				continue
			}
		}
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\u%04X`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func tomlArray(items []string) string {
	quoted := make([]string, 0, len(items))
	for _, it := range items {
		quoted = append(quoted, tomlString(it))
	}
	return "[" + strings.Join(quoted, ", ") + "]"
}

// tomlInlineTable is m as a TOML inline table, keys quoted and sorted.
func tomlInlineTable(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, tomlString(k)+" = "+tomlString(m[k]))
	}
	return "{ " + strings.Join(parts, ", ") + " }"
}

// quotedList is items as the inside of a TOML string array.
func quotedList(items []string) string {
	quoted := make([]string, 0, len(items))
	for _, a := range items {
		quoted = append(quoted, strconv.Quote(a))
	}
	return strings.Join(quoted, ", ")
}

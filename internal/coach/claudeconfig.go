package coach

import (
	"encoding/json"
	"errors"
	"io/fs"
	"path/filepath"
	"sort"
)

// The context proposer reads the owner's Claude Code config for names only:
// plugin ids, server names, the projects that install them and the one
// connectors switch. Server entries, headers, env values and tokens are never
// kept (FILES-01, AGENTLOG-01): the decoders below take keys, not values.

// The connectors switch: Claude Code loads the claude.ai connectors unless
// this env key of the user settings says otherwise.
const connectorsEnvKey = "ENABLE_CLAUDEAI_MCP_SERVERS"

var (
	errClaudeJSONNotRegular = errors.New(".claude.json is a symlink or not a regular file")
	errClaudeJSONInvalid    = errors.New(".claude.json is not a JSON object")
	errClaudeJSONChanged    = errors.New(".claude.json changed while it was being written")
	errSettingsNotObject    = errors.New("settings.json is not a JSON object")
	errInstalledNotRegular  = errors.New("installed_plugins.json is a symlink or not a regular file")
	errInstalledInvalid     = errors.New("installed_plugins.json is not a JSON object")
)

// claudeJSONPath is <home>/.claude.json, Claude Code's own state file: the
// user-scope MCP servers and the per-project ones.
func claudeJSONPath(home string) string { return filepath.Join(home, ".claude.json") }

// installedPluginsPath is <home>/.claude/plugins/installed_plugins.json.
func installedPluginsPath(home string) string {
	return filepath.Join(home, ".claude", "plugins", "installed_plugins.json")
}

func readClaudeJSONFile(path string) ([]byte, fs.FileMode, bool, error) {
	return readRegularFile(".claude.json", errClaudeJSONNotRegular, path)
}

var claudeJSONKind = atomicKind{label: ".claude.json", tmp: ".claude.json.coach-*",
	read: readClaudeJSONFile, changed: errClaudeJSONChanged}

// PluginState is one plugin as the owner's config has it: Enabled is its
// user-scope enabledPlugins value; Scopes are where it is installed ("user",
// or the project folders of a project or local install), sorted.
type PluginState struct {
	Enabled bool
	Scopes  []string
}

// ClaudeConfig is the names-only read of the owner's Claude Code config.
// ProjectServers maps a project folder to its own servers' names;
// ConnectorsEnv is env.ENABLE_CLAUDEAI_MCP_SERVERS of the user settings (""
// when unset).
type ClaudeConfig struct {
	Plugins        map[string]PluginState
	UserServers    []string
	ProjectServers map[string][]string
	ConnectorsEnv  string
}

// ReadClaudeConfig reads <home>/.claude/settings.json (enabledPlugins and the
// connectors switch), <home>/.claude/plugins/installed_plugins.json (where
// each plugin is installed) and <home>/.claude.json (the user-scope and
// per-project MCP servers). A missing file reads as empty; a file that is not
// JSON of the expected shape is an error naming its label, never its path.
func ReadClaudeConfig(home string) (ClaudeConfig, error) {
	cfg := ClaudeConfig{Plugins: map[string]PluginState{}, ProjectServers: map[string][]string{}}
	if err := readUserSettingsNames(home, &cfg); err != nil {
		return ClaudeConfig{}, err
	}
	if err := readInstalledPlugins(home, &cfg); err != nil {
		return ClaudeConfig{}, err
	}
	if err := readServerNames(home, &cfg); err != nil {
		return ClaudeConfig{}, err
	}
	return cfg, nil
}

// objectKeys decodes raw, which must be a JSON object, into its keys and raw
// values; a missing (nil) raw is an empty object.
func objectKeys(raw json.RawMessage, invalid error) (map[string]json.RawMessage, error) {
	m := map[string]json.RawMessage{}
	if raw == nil {
		return m, nil
	}
	if !isJSON(raw, '{') || json.Unmarshal(raw, &m) != nil {
		return nil, invalid
	}
	return m, nil
}

func readUserSettingsNames(home string, cfg *ClaudeConfig) error {
	raw, _, ok, err := readSettingsFile(claudeSettingsPath(home))
	if err != nil || !ok {
		return err
	}
	top, err := objectKeys(raw, errSettingsNotObject)
	if err != nil {
		return err
	}
	plugins, err := objectKeys(top["enabledPlugins"], errSettingsNotObject)
	if err != nil {
		return err
	}
	for name, v := range plugins {
		var on bool
		_ = json.Unmarshal(v, &on) // a value of another shape counts as off
		st := cfg.Plugins[name]
		st.Enabled = on
		cfg.Plugins[name] = st
	}
	env, err := objectKeys(top["env"], errSettingsNotObject)
	if err != nil {
		return err
	}
	if v, ok := env[connectorsEnvKey]; ok {
		var s string
		if json.Unmarshal(v, &s) != nil {
			s = compactJSON(v)
		}
		cfg.ConnectorsEnv = s
	}
	return nil
}

func readInstalledPlugins(home string, cfg *ClaudeConfig) error {
	raw, _, ok, err := readRegularFile("installed_plugins.json", errInstalledNotRegular, installedPluginsPath(home))
	if err != nil || !ok {
		return err
	}
	top, err := objectKeys(raw, errInstalledInvalid)
	if err != nil {
		return err
	}
	plugins, err := objectKeys(top["plugins"], errInstalledInvalid)
	if err != nil {
		return err
	}
	for name, v := range plugins {
		var installs []struct {
			Scope       string `json:"scope"`
			ProjectPath string `json:"projectPath"`
		}
		scopes := map[string]bool{}
		if json.Unmarshal(v, &installs) != nil {
			// The first format kept one user install per plugin.
			scopes["user"] = true
		}
		for _, in := range installs {
			switch {
			case in.Scope == "user":
				scopes["user"] = true
			case in.ProjectPath != "":
				scopes[in.ProjectPath] = true
			}
		}
		st := cfg.Plugins[name]
		for s := range scopes {
			st.Scopes = append(st.Scopes, s)
		}
		sort.Strings(st.Scopes)
		cfg.Plugins[name] = st
	}
	return nil
}

func readServerNames(home string, cfg *ClaudeConfig) error {
	raw, _, ok, err := readClaudeJSONFile(claudeJSONPath(home))
	if err != nil || !ok {
		return err
	}
	top, err := objectKeys(raw, errClaudeJSONInvalid)
	if err != nil {
		return err
	}
	servers, err := objectKeys(top["mcpServers"], errClaudeJSONInvalid)
	if err != nil {
		return err
	}
	cfg.UserServers = sortedKeys(servers)
	projects, err := objectKeys(top["projects"], errClaudeJSONInvalid)
	if err != nil {
		return err
	}
	for folder, v := range projects {
		p, err := objectKeys(v, errClaudeJSONInvalid)
		if err != nil {
			return err
		}
		ps, err := objectKeys(p["mcpServers"], errClaudeJSONInvalid)
		if err != nil {
			return err
		}
		if len(ps) > 0 {
			cfg.ProjectServers[folder] = sortedKeys(ps)
		}
	}
	return nil
}

func sortedKeys(m map[string]json.RawMessage) []string {
	if len(m) == 0 {
		return nil
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

package codex

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"

	"github.com/pelletier/go-toml/v2"
)

// ReadOnlyAppOverrides returns the `-c key=value` argument pairs that leave
// exactly the named tools of one Codex app (connector) callable in a
// `codex exec` run: apps on, every app and every tool off by default, then
// the app and the listed tools on. The owner's own <codexHome>/config.toml is
// read too: every other app it configures is switched off and every tool it
// configures on this app that is not listed is switched off, so a config that
// enables a write tool cannot widen the allow-list. A missing config.toml adds
// nothing; an unreadable or invalid one is an error (fail closed).
func ReadOnlyAppOverrides(codexHome, connectorID string, tools []string) ([]string, error) {
	if err := checkKeys(append([]string{connectorID}, tools...)...); err != nil {
		return nil, err
	}
	apps, err := configuredApps(codexHome)
	if err != nil {
		return nil, err
	}
	var kv []string
	kv = append(kv,
		"features.apps=true",
		"apps._default.enabled=false",
		"apps._default.default_tools_enabled=false",
		"apps."+connectorID+".enabled=true",
		"apps."+connectorID+".default_tools_enabled=false",
	)
	for _, id := range sortedAppIDs(apps) {
		if id == "_default" || id == connectorID {
			continue
		}
		kv = append(kv, "apps."+id+".enabled=false")
	}
	for _, t := range sortedSet(apps[connectorID]) {
		if !slices.Contains(tools, t) {
			kv = append(kv, "apps."+connectorID+".tools."+t+".enabled=false")
		}
	}
	for _, t := range tools {
		kv = append(kv, "apps."+connectorID+".tools."+t+".enabled=true")
	}
	return cPairs(kv), nil
}

// keyPattern is what an app id or tool name may look like in a `-c` key.
// Anything else (a quoted TOML key with a dot, a space, an equals sign)
// could rewrite another key's path, so it is refused outright.
var keyPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

func checkKeys(keys ...string) error {
	for _, k := range keys {
		if !keyPattern.MatchString(k) {
			return fmt.Errorf("codex app allow-list: unsafe app or tool key %q", k)
		}
	}
	return nil
}

// WarmUpAppOverrides returns the `-c` pairs for the run that only lets Codex
// fill its apps cache: apps on and no tool callable. Per-app keys in the
// owner's config.toml beat `_default`, so every configured app and tool is
// switched off one by one (an unreadable or invalid config is an error).
// apps._default.enabled is left alone: switching whole apps off may stop the
// cache from filling.
func WarmUpAppOverrides(codexHome string) ([]string, error) {
	apps, err := configuredApps(codexHome)
	if err != nil {
		return nil, err
	}
	kv := []string{"features.apps=true", "apps._default.default_tools_enabled=false"}
	for _, id := range sortedAppIDs(apps) {
		if id == "_default" {
			continue
		}
		kv = append(kv, "apps."+id+".default_tools_enabled=false")
		for _, t := range sortedSet(apps[id]) {
			kv = append(kv, "apps."+id+".tools."+t+".enabled=false")
		}
	}
	return cPairs(kv), nil
}

// NoMCPServerArgs is the `-c mcp_servers={…}` pair that disables every MCP
// server the owner's codex config layers declare (as the chat's tool-less
// runs do), for a run started in cwd with the given CODEX_HOME.
func NoMCPServerArgs(codexHome, cwd string) ([]string, error) {
	owner, err := ownerServerNames(codexHome, cwd)
	if err != nil {
		return nil, err
	}
	override, _, _ := mcpOverride("", nil, nil, nil, owner, nil)
	return []string{"-c", override}, nil
}

func cPairs(kv []string) []string {
	args := make([]string, 0, 2*len(kv))
	for _, s := range kv {
		args = append(args, "-c", s)
	}
	return args
}

func sortedAppIDs(apps map[string]map[string]bool) []string {
	ids := make([]string, 0, len(apps))
	for id := range apps {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func sortedSet(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// configuredApps maps each [apps.<id>] table of config.toml to the names of
// the tools configured under it.
func configuredApps(codexHome string) (map[string]map[string]bool, error) {
	b, err := os.ReadFile(filepath.Join(codexHome, "config.toml"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("codex app allow-list: reading config.toml: %w", err)
	}
	var cfg struct {
		Apps map[string]struct {
			Tools map[string]any `toml:"tools"`
		} `toml:"apps"`
	}
	if err := toml.Unmarshal(b, &cfg); err != nil {
		return nil, fmt.Errorf("codex app allow-list: invalid config.toml: %w", err)
	}
	out := make(map[string]map[string]bool, len(cfg.Apps))
	for id, app := range cfg.Apps {
		if err := checkKeys(id); err != nil {
			return nil, err
		}
		tools := make(map[string]bool, len(app.Tools))
		for t := range app.Tools {
			if err := checkKeys(t); err != nil {
				return nil, err
			}
			tools[t] = true
		}
		out[id] = tools
	}
	return out, nil
}

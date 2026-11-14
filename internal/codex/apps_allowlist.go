package codex

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
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
	if connectorID == "" {
		return nil, errors.New("codex app allow-list: empty connector id")
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
	ids := make([]string, 0, len(apps))
	for id := range apps {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if id == "_default" || id == connectorID {
			continue
		}
		kv = append(kv, "apps."+id+".enabled=false")
	}
	configured := make([]string, 0, len(apps[connectorID]))
	for t := range apps[connectorID] {
		configured = append(configured, t)
	}
	sort.Strings(configured)
	for _, t := range configured {
		if !slices.Contains(tools, t) {
			kv = append(kv, "apps."+connectorID+".tools."+t+".enabled=false")
		}
	}
	for _, t := range tools {
		kv = append(kv, "apps."+connectorID+".tools."+t+".enabled=true")
	}
	args := make([]string, 0, 2*len(kv))
	for _, s := range kv {
		args = append(args, "-c", s)
	}
	return args, nil
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
		tools := make(map[string]bool, len(app.Tools))
		for t := range app.Tools {
			tools[t] = true
		}
		out[id] = tools
	}
	return out, nil
}

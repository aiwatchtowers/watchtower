package media

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/doclinks"
	"watchtower/internal/media/linkrule"
)

// BuildDenyHosts is the build's seed of hosts whose links are never fetched,
// comma-separated, set by ldflags (`-X watchtower/internal/media.BuildDenyHosts=…`
// from WATCHTOWER_LINK_FETCH_DENY_HOSTS; the purge.BuildDefault precedent).
// Empty in the public build; the corp build seeds its own domains.
var BuildDenyHosts = ""

// DenyHosts is the build seed united with the config's
// knowledge.link_fetch_deny_hosts: a config list only adds hosts, it never
// drops the seed. Normalize the result with NormalizeHostSet.
func DenyHosts(cfg *config.Config) []string {
	var out []string
	add := func(h string) {
		if h = strings.TrimSpace(h); h != "" {
			out = append(out, h)
		}
	}
	for _, h := range strings.Split(BuildDenyHosts, ",") {
		add(h)
	}
	if cfg != nil {
		for _, h := range cfg.Knowledge.LinkFetchDenyHosts {
			add(h)
		}
	}
	return out
}

// RefusedHosts is the refused-host set Fetchable takes, read afresh: the
// synced sources, the connected Jira/Confluence sites and deny (DenyHosts).
// Discovery and the pass build it the same way.
func RefusedHosts(ctx context.Context, q doclinks.Queryer, deny []string) (map[string]bool, error) {
	sites, err := doclinks.SiteHosts(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("media: %w", err)
	}
	hosts := append([]string{}, linkrule.SyncedHosts...)
	for h := range sites {
		hosts = append(hosts, h)
	}
	return linkrule.NormalizeHostSet(append(hosts, deny...)), nil
}

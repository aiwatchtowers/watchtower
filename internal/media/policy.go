package media

import (
	"strings"

	"watchtower/internal/config"
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

package hub

import (
	"os"

	"watchtower/internal/hub/state"
)

// DisplayName is the name the hub in dir shows phones, as the running hub
// picks it (supervisor.hostName): hub_meta.display_name, else the short host
// name. Read only; a dir with no sidecar yet, or one that cannot be read,
// gives the host name. `hub status --json` reports it as "name"
// (Settings → Mobile's Mac name row, plan 3 Task 23).
func DisplayName(dir string) string {
	if dir != "" {
		if st, err := state.OpenReadOnly(dir); err == nil {
			v, ok, err := st.Meta(state.MetaDisplayName)
			_ = st.Close()
			if err == nil && ok && v != "" {
				return v
			}
		}
	}
	return shortHostName(os.Hostname)
}

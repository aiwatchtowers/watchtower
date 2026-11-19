package hostkind

import (
	"os"
	"runtime"

	"watchtower/internal/config"
)

// System is this host's probe. An unknown home or app support folder is
// left empty (Detect skips what needs it; the live hub dir needs the home
// folder too, so such a host never starts a live hub).
func System() Probe {
	home, err := os.UserHomeDir()
	if err != nil {
		home = ""
	}
	support, err := config.AppSupportDir()
	if err != nil {
		support = ""
	}
	return Probe{GOOS: runtime.GOOS, Home: home, AppSupport: support, Stat: os.Stat, ReadFile: os.ReadFile}
}

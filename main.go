package main

import (
	"os"

	"watchtower/cmd"
	"watchtower/internal/policy"
)

func main() {
	// The organization policy comes from this Mac's managed preferences; only
	// the shipped binary reads them, never a test binary.
	policy.UseSystemReader()
	os.Exit(cmd.Execute())
}

package cmd

import (
	"os"

	"watchtower/internal/linear"
)

// resolveLinearOAuthConfig returns the Linear OAuth config: the client id from
// WATCHTOWER_LINEAR_CLIENT_ID, else the built-in public default.
func resolveLinearOAuthConfig() linear.OAuthConfig {
	id := os.Getenv("WATCHTOWER_LINEAR_CLIENT_ID")
	if id == "" {
		id = linear.DefaultLinearClientID
	}
	return linear.OAuthConfig{ClientID: id}
}

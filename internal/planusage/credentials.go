package planusage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

// ErrNoCredentials means Claude Code's credentials were found nowhere.
var ErrNoCredentials = errors.New("planusage: no Claude Code credentials")

const keychainService = "Claude Code-credentials"

// Credentials is the part of Claude Code's OAuth record the poller needs.
type Credentials struct {
	AccessToken string
	ExpiresAt   time.Time
	Plan        string
}

// CommandRunner runs an external command and returns its stdout.
type CommandRunner func(ctx context.Context, name string, args ...string) ([]byte, error)

// CredentialSource reads Claude Code's OAuth credentials read-only: the
// Keychain item first (macOS), then ~/.claude/.credentials.json. It never
// refreshes or writes them — a refresh rotates the refresh token and would sign
// Claude Code out (spec "Credentials").
type CredentialSource struct {
	Run CommandRunner
	// KeychainTimeout bounds the `security` call; zero means 5 s.
	KeychainTimeout time.Duration
	HomeDir         string
	UseKeychain     bool
}

// DefaultCredentialSource reads the real Keychain (macOS) and home directory.
func DefaultCredentialSource() CredentialSource {
	home, _ := os.UserHomeDir()
	return CredentialSource{
		Run: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return exec.CommandContext(ctx, name, args...).Output()
		},
		HomeDir:     home,
		UseKeychain: runtime.GOOS == "darwin",
	}
}

// Load returns the credentials or ErrNoCredentials.
func (s CredentialSource) Load(ctx context.Context) (Credentials, error) {
	if s.UseKeychain && s.Run != nil {
		timeout := s.KeychainTimeout
		if timeout <= 0 {
			timeout = 5 * time.Second
		}
		kctx, cancel := context.WithTimeout(ctx, timeout)
		out, err := s.Run(kctx, "/usr/bin/security", "find-generic-password", "-s", keychainService, "-w")
		cancel()
		if err == nil {
			return decodeCredentials(out)
		}
		if ctx.Err() != nil {
			return Credentials{}, ctx.Err()
		}
	}
	if s.HomeDir != "" {
		b, err := os.ReadFile(filepath.Join(s.HomeDir, ".claude", ".credentials.json"))
		if err == nil {
			return decodeCredentials(b)
		}
	}
	return Credentials{}, ErrNoCredentials
}

// decodeCredentials never wraps the JSON error: its text can quote the input.
func decodeCredentials(b []byte) (Credentials, error) {
	var raw struct {
		OAuth *struct {
			AccessToken      string `json:"accessToken"`
			ExpiresAt        int64  `json:"expiresAt"`
			SubscriptionType string `json:"subscriptionType"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(bytes.TrimSpace(b), &raw) != nil {
		return Credentials{}, errors.New("planusage: credentials are not valid JSON")
	}
	if raw.OAuth == nil || raw.OAuth.AccessToken == "" {
		return Credentials{}, ErrNoCredentials
	}
	c := Credentials{AccessToken: raw.OAuth.AccessToken, Plan: raw.OAuth.SubscriptionType}
	if raw.OAuth.ExpiresAt > 0 {
		c.ExpiresAt = time.UnixMilli(raw.OAuth.ExpiresAt).UTC()
	}
	return c, nil
}

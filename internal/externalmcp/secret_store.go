// Package externalmcp stores the per-connection secret (env vars for stdio
// servers, headers for http servers) backing an owner-added Quick Connection
// as its own 0600 file, never in the database or on argv.
package externalmcp

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// OAuthGrant is the OAuth 2.1 grant behind an http connection signed in via
// `watchtower connections oauth`. The bearer header is derived from
// AccessToken at chat launch and is never persisted into Headers.
type OAuthGrant struct {
	AccessToken        string    `json:"access_token"`
	RefreshToken       string    `json:"refresh_token,omitempty"`
	ExpiresAt          time.Time `json:"expires_at"` // zero = unknown, never proactively refreshed
	TokenEndpoint      string    `json:"token_endpoint"`
	ClientID           string    `json:"client_id"`
	ClientSecret       string    `json:"client_secret,omitempty"`
	Scope              string    `json:"scope,omitempty"`
	Resource           string    `json:"resource,omitempty"` // the MCP server URL (RFC 8707)
	RevocationEndpoint string    `json:"revocation_endpoint,omitempty"`
}

// Expiring reports whether the access token is already expired or expires
// within skew of now. A zero ExpiresAt is treated as not expiring.
func (g *OAuthGrant) Expiring(now time.Time, skew time.Duration) bool {
	return !g.ExpiresAt.IsZero() && !now.Add(skew).Before(g.ExpiresAt)
}

type Secret struct {
	Env     map[string]string `json:"env,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
	OAuth   *OAuthGrant       `json:"oauth,omitempty"`
}

type SecretStore struct {
	path string
}

func NewSecretStore(workspaceDir string, connectionID int64) *SecretStore {
	return &SecretStore{
		path: filepath.Join(workspaceDir, fmt.Sprintf("mcp_secret_%d.json", connectionID)),
	}
}

func (s *SecretStore) Load() (*Secret, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading mcp secret: %w", err)
	}
	var sec Secret
	if err := json.Unmarshal(data, &sec); err != nil {
		return nil, fmt.Errorf("parsing mcp secret: %w", err)
	}
	return &sec, nil
}

// Save writes sec atomically: it writes to path+".tmp" and renames that
// over the destination (same directory, so the rename is on one
// filesystem and atomic). A crash or failure mid-write leaves the previous
// file (or none) intact rather than a half-written one — load-bearing for
// callers persisting a just-rotated OAuth token, where a torn write would
// burn both the old and new refresh token.
func (s *SecretStore) Save(sec *Secret) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating secret directory: %w", err)
	}
	data, err := json.MarshalIndent(sec, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling mcp secret: %w", err)
	}

	tmpPath := s.path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0o600); err != nil {
		return fmt.Errorf("writing temp secret file: %w", err)
	}
	if err := os.Rename(tmpPath, s.path); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("renaming temp secret file into place: %w", err)
	}
	return nil
}

func (s *SecretStore) Delete() error {
	err := os.Remove(s.path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func (s *SecretStore) Exists() bool {
	_, err := os.Stat(s.path)
	return err == nil
}

func (s *SecretStore) Path() string {
	return s.path
}

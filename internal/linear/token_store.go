package linear

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/fsutil"
)

// Token is a Linear OAuth2 token response plus its computed expiry.
type Token struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	Scope        string `json:"scope"`
	Expiry       string `json:"expiry,omitempty"` // RFC 3339, calculated from ExpiresIn
}

// IsExpired reports whether the token has expired or will within 60 seconds.
// An empty or unparseable Expiry counts as expired.
func (t *Token) IsExpired() bool {
	if t.Expiry == "" {
		return true
	}
	exp, err := time.Parse(time.RFC3339, t.Expiry)
	if err != nil {
		return true
	}
	return time.Now().After(exp.Add(-60 * time.Second))
}

// TokenStore persists and loads the OAuth2 token of one Linear account.
type TokenStore struct {
	path string // <workspace>/linear_token_<accountID>.json
}

// NewTokenStore creates a TokenStore for one Linear account in the given
// workspace directory.
func NewTokenStore(workspaceDir string, accountID int64) *TokenStore {
	return &TokenStore{
		path: filepath.Join(workspaceDir, fmt.Sprintf("linear_token_%d.json", accountID)),
	}
}

// Path returns the token file path.
func (s *TokenStore) Path() string {
	return s.path
}

// Load reads the token from disk.
func (s *TokenStore) Load() (*Token, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, err
	}
	var token Token
	if err := json.Unmarshal(data, &token); err != nil {
		return nil, fmt.Errorf("parsing token: %w", err)
	}
	return &token, nil
}

// Save writes the token atomically (fsutil.WriteFileAtomic, 0600), so readers
// without the lock never see a half-written token mid-refresh.
func (s *TokenStore) Save(token *Token) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating token directory: %w", err)
	}
	data, err := json.MarshalIndent(token, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling token: %w", err)
	}
	if err := fsutil.WriteFileAtomic(s.path, data, 0o600); err != nil {
		return fmt.Errorf("saving token: %w", err)
	}
	return nil
}

// Lock takes the cross-process lock serializing this account's
// load→refresh→save: Linear rotates the refresh token on every refresh, so two
// concurrent refreshes would make the loser's invalid_grant read as a revoked
// account.
func (s *TokenStore) Lock(ctx context.Context) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return nil, fmt.Errorf("creating token directory: %w", err)
	}
	unlock, err := fsutil.LockFile(ctx, s.path+".lock")
	if err != nil {
		return nil, fmt.Errorf("locking linear token: %w", err)
	}
	return unlock, nil
}

// Delete removes the token file; a missing file is not an error.
func (s *TokenStore) Delete() error {
	err := os.Remove(s.path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// Exists checks whether a token file is present.
func (s *TokenStore) Exists() bool {
	_, err := os.Stat(s.path)
	return err == nil
}

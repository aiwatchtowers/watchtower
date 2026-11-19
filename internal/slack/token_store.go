package slack

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/fsutil"
)

type Token struct {
	AccessToken string `json:"access_token"`
	TeamID      string `json:"team_id"`
	TeamName    string `json:"team_name"`
	UserID      string `json:"user_id"`
	// Scope is the comma-separated user scopes Slack granted (authed_user.scope).
	// Empty on a token saved before scopes were recorded: unknown, not none.
	Scope string `json:"scope,omitempty"`
	// RefreshToken, ExpiresAt and RefreshExpiresAt are set only for a token
	// with rotation; a token without them (the retired shared app, a company
	// app without rotation, files written earlier) is used as is.
	RefreshToken     string    `json:"refresh_token,omitempty"`
	ExpiresAt        time.Time `json:"expires_at,omitzero"`
	RefreshExpiresAt time.Time `json:"refresh_expires_at,omitzero"`
	// RefreshedAt is when slackauth last refreshed the token (zero: never);
	// a refresh that left an expiry inside its window is not repeated.
	RefreshedAt time.Time `json:"refreshed_at,omitzero"`
	// ClientID and AppID name the Slack app the token was issued through.
	// When they differ from the account row, the file is the truth (A6);
	// empty on files written before they were recorded.
	ClientID string `json:"client_id,omitempty"`
	AppID    string `json:"app_id,omitempty"`
}

// SendScope is the user scope chat.postMessage needs.
const SendScope = "chat:write"

// HasScope reports whether the token's recorded grant includes scope. A token
// without a recorded grant answers false — callers that must still try such a
// token (it may predate recording) check Scope == "" themselves.
func (t *Token) HasScope(scope string) bool {
	if t == nil {
		return false
	}
	for s := range strings.SplitSeq(t.Scope, ",") {
		if strings.TrimSpace(s) == scope {
			return true
		}
	}
	return false
}

type TokenStore struct {
	path string
}

func NewTokenStore(workspaceDir string, accountID int64) *TokenStore {
	return &TokenStore{
		path: filepath.Join(workspaceDir, fmt.Sprintf("slack_token_%d.json", accountID)),
	}
}

func (s *TokenStore) Load() (*Token, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading slack token: %w", err)
	}
	var token Token
	if err := json.Unmarshal(data, &token); err != nil {
		return nil, fmt.Errorf("parsing slack token: %w", err)
	}
	return &token, nil
}

func (s *TokenStore) Save(t *Token) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating token directory: %w", err)
	}
	data, err := json.MarshalIndent(t, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling slack token: %w", err)
	}
	return fsutil.WriteFileAtomic(s.path, data, 0o600)
}

// Lock takes the per-account flock (<token file>.lock) that every token-file
// write and every refresh holds; the returned func releases it. A waiter
// re-reads the file after taking the lock.
func (s *TokenStore) Lock(ctx context.Context) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return nil, fmt.Errorf("creating token directory: %w", err)
	}
	unlock, err := fsutil.LockFile(ctx, s.path+".lock")
	if err != nil {
		return nil, fmt.Errorf("locking slack token: %w", err)
	}
	return unlock, nil
}

func (s *TokenStore) Delete() error {
	err := os.Remove(s.path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func (s *TokenStore) Exists() bool {
	_, err := os.Stat(s.path)
	return err == nil
}

func (s *TokenStore) Path() string {
	return s.path
}

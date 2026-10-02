package slack

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

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
	for _, s := range strings.Split(t.Scope, ",") {
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

package imap

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Credentials is the persisted secret for one email_accounts row: a password
// for provider='imap', or an OAuth2 refresh token for provider='outlook'.
// Only one of Password/RefreshToken is set, matching the account's provider.
type Credentials struct {
	Password     string `json:"password,omitempty"`
	RefreshToken string `json:"refresh_token,omitempty"`
}

// CredentialStore persists one account's IMAP credentials as plaintext JSON,
// 0600 — the same risk model already accepted for gmail_token.json
// (internal/gmail.TokenStore), just keyed per account ID instead of one
// singleton file per workspace.
type CredentialStore struct {
	path string // ~/.local/share/watchtower/{workspace}/imap_credentials_{accountID}.json
}

// NewCredentialStore creates a CredentialStore for the given workspace directory and account ID.
func NewCredentialStore(workspaceDir string, accountID int64) *CredentialStore {
	return &CredentialStore{
		path: filepath.Join(workspaceDir, fmt.Sprintf("imap_credentials_%d.json", accountID)),
	}
}

// Load reads the credentials from disk.
func (s *CredentialStore) Load() (*Credentials, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, err
	}
	var creds Credentials
	if err := json.Unmarshal(data, &creds); err != nil {
		return nil, fmt.Errorf("parsing imap credentials: %w", err)
	}
	return &creds, nil
}

// Save writes the credentials to disk.
func (s *CredentialStore) Save(creds *Credentials) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating credentials directory: %w", err)
	}
	data, err := json.MarshalIndent(creds, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling imap credentials: %w", err)
	}
	return os.WriteFile(s.path, data, 0o600)
}

// Delete removes the credentials file.
func (s *CredentialStore) Delete() error {
	err := os.Remove(s.path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// Exists checks whether a credentials file is present.
func (s *CredentialStore) Exists() bool {
	_, err := os.Stat(s.path)
	return err == nil
}

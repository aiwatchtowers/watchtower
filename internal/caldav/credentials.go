package caldav

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Credentials is the persisted secret for one calendar_accounts row: a
// password for provider='caldav', or the secret feed URL for provider='ics'
// (the URL itself grants read access to the calendar, so it is a credential
// and never lands in the DB). Only one field is set, matching the provider.
type Credentials struct {
	Password string `json:"password,omitempty"`
	FeedURL  string `json:"feed_url,omitempty"`
}

// CredentialStore persists one account's calendar credentials as plaintext
// JSON, 0600 — the same risk model already accepted for gmail_token.json and
// imap_credentials_<id>.json, keyed per account ID.
type CredentialStore struct {
	path string // ~/.local/share/watchtower/{workspace}/caldav_credentials_{accountID}.json
}

// NewCredentialStore creates a CredentialStore for the given workspace directory and account ID.
func NewCredentialStore(workspaceDir string, accountID int64) *CredentialStore {
	return &CredentialStore{
		path: filepath.Join(workspaceDir, fmt.Sprintf("caldav_credentials_%d.json", accountID)),
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
		return nil, fmt.Errorf("parsing caldav credentials: %w", err)
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
		return fmt.Errorf("marshaling caldav credentials: %w", err)
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

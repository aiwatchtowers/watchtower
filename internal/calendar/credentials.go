package calendar

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Credentials holds the OAuth2 client credentials for Google API access.
type Credentials struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
}

// CredentialStore persists one account's OAuth2 client credentials as JSON.
// client_id is public, but client_secret is NOT — the struct holds both, so
// this file is stored separately from tokens for organizational clarity, not
// because its contents are non-secret. File mode is 0600 for consistency
// with TokenStore.
type CredentialStore struct {
	path string // ~/.local/share/watchtower/{workspace}/google_credentials_{accountID}.json
}

// NewCredentialStore creates a CredentialStore for the given workspace directory and account ID.
func NewCredentialStore(workspaceDir string, accountID int64) *CredentialStore {
	return &CredentialStore{
		path: filepath.Join(workspaceDir, fmt.Sprintf("google_credentials_%d.json", accountID)),
	}
}

// Path returns the credentials file path.
func (s *CredentialStore) Path() string {
	return s.path
}

// Load reads the credentials from disk.
func (s *CredentialStore) Load() (*Credentials, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, err
	}
	var creds Credentials
	if err := json.Unmarshal(data, &creds); err != nil {
		return nil, fmt.Errorf("parsing credentials: %w", err)
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
		return fmt.Errorf("marshaling credentials: %w", err)
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

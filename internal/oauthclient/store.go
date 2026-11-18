// Package oauthclient keeps one account's own OAuth client
// (<workspace>/<vendor>_client_<accountID>.json, 0600): the client an account
// added from a company bundle signed in with, so its refresh still finds that
// client when the bundle is gone. Written when an account is added from a
// bundle; token refresh never writes it.
package oauthclient

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"watchtower/internal/fsutil"
)

// Client is one OAuth client. TenantID is Microsoft's only.
type Client struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret,omitempty"`
	TenantID     string `json:"tenant_id,omitempty"`
}

// Store is one account's client file.
type Store struct{ path string }

// NewStore returns the client file of vendor's account accountID.
func NewStore(workspaceDir, vendor string, accountID int64) Store {
	return Store{path: filepath.Join(workspaceDir, fmt.Sprintf("%s_client_%d.json", vendor, accountID))}
}

// Path is the file's path.
func (s Store) Path() string { return s.path }

// Load reads the client; a missing file is (Client{}, false, nil). A file
// that does not decode, has unknown fields or no client id is an error.
func (s Store) Load() (Client, bool, error) {
	raw, err := os.ReadFile(s.path)
	if errors.Is(err, fs.ErrNotExist) {
		return Client{}, false, nil
	}
	if err != nil {
		return Client{}, false, fmt.Errorf("reading %s: %w", filepath.Base(s.path), err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var c Client
	if err := dec.Decode(&c); err != nil {
		return Client{}, false, fmt.Errorf("parsing %s: %w", filepath.Base(s.path), err)
	}
	if c.ClientID == "" {
		return Client{}, false, fmt.Errorf("%s has no client id", filepath.Base(s.path))
	}
	return c, true, nil
}

// Save writes c atomically with mode 0600.
func (s Store) Save(c Client) error {
	if c.ClientID == "" {
		return errors.New("oauth client without a client id")
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating client directory: %w", err)
	}
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}
	return fsutil.WriteFileAtomic(s.path, data, 0o600)
}

// Delete removes the file; a missing file is not an error.
func (s Store) Delete() error {
	if err := os.Remove(s.path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

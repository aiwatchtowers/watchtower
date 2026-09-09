package externalmcp

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type Secret struct {
	Env     map[string]string `json:"env,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
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

func (s *SecretStore) Save(sec *Secret) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating secret directory: %w", err)
	}
	data, err := json.MarshalIndent(sec, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling mcp secret: %w", err)
	}
	return os.WriteFile(s.path, data, 0o600)
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

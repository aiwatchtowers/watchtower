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
	ExpiresAt          time.Time `json:"expires_at"` // zero = unknown lifetime; EnsureFresh treats this as "must verify" when a refresh token is present (see mcpoauth.EnsureFresh)
	TokenEndpoint      string    `json:"token_endpoint"`
	ClientID           string    `json:"client_id"`
	ClientSecret       string    `json:"client_secret,omitempty"`
	Scope              string    `json:"scope,omitempty"`
	Resource           string    `json:"resource,omitempty"` // the MCP server URL (RFC 8707)
	RevocationEndpoint string    `json:"revocation_endpoint,omitempty"`
}

// Expiring reports whether the access token is already expired or expires
// within skew of now. A zero ExpiresAt (unknown lifetime) is treated as not
// expiring by THIS predicate — callers that need to distinguish "known
// fresh" from "unknown, must verify" (mcpoauth.EnsureFresh does) check
// ExpiresAt.IsZero() themselves rather than relying on Expiring alone.
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
//
// The temp file is created with O_EXCL rather than via os.WriteFile: a
// leftover tmpPath from a prior interrupted Save (process killed between
// the old WriteFile and Rename) could carry a mode wider than 0600 — say,
// created under a permissive umask by an older build — and os.WriteFile
// does NOT reset an already-existing file's mode, so writing over it would
// silently rename that wider-permission file into place as the live
// secret. A stale *regular file* left at tmpPath is always safe to discard
// (Save always regenerates it from scratch), so it is removed first, then
// O_EXCL guarantees the file this call writes is a fresh one created at
// exactly 0600. Anything else occupying tmpPath (a directory, say) is left
// alone — O_EXCL then fails loudly rather than this method silently
// deleting something unexpected.
func (s *SecretStore) Save(sec *Secret) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating secret directory: %w", err)
	}
	data, err := json.MarshalIndent(sec, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling mcp secret: %w", err)
	}

	tmpPath := s.path + ".tmp"
	if fi, statErr := os.Lstat(tmpPath); statErr == nil {
		if fi.Mode().IsRegular() {
			if err := os.Remove(tmpPath); err != nil {
				return fmt.Errorf("removing stale temp secret file: %w", err)
			}
		}
	} else if !os.IsNotExist(statErr) {
		return fmt.Errorf("checking temp secret file: %w", statErr)
	}
	f, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("creating temp secret file: %w", err)
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		_ = os.Remove(tmpPath)
		return fmt.Errorf("writing temp secret file: %w", err)
	}
	// Sync before rename so the write is durable on disk before the rename
	// makes it visible — without this, a crash right after Save returns
	// could still lose the write despite the rename having "completed",
	// which would defeat the crash-survival contract this method promises
	// for a just-rotated OAuth token.
	if err := f.Sync(); err != nil {
		f.Close()
		_ = os.Remove(tmpPath)
		return fmt.Errorf("syncing temp secret file: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("closing temp secret file: %w", err)
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

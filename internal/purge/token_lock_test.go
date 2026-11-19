package purge

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"watchtower/internal/fsutil"
)

// The Slack token file is deleted under the account's token lock, so a
// refresh in another process cannot write it back (plan B Task 8). A context
// that is already done makes a held lock fail at once instead of waiting.
func TestDeleteTokens_SlackWaitsForTheTokenLock(t *testing.T) {
	dir := t.TempDir()
	token := filepath.Join(dir, "slack_token_1.json")
	if err := os.WriteFile(token, []byte(`{"access_token":"xoxp-a"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	unlock, ok, err := fsutil.TryLockFile(token + ".lock")
	if err != nil || !ok {
		t.Fatalf("taking the lock: ok=%v err=%v", ok, err)
	}
	done, cancel := context.WithCancel(context.Background())
	cancel()
	if err := deleteTokens(done, dir, "slack", 1); err == nil {
		t.Fatal("deleted while another process holds the token lock")
	}
	if _, err := os.Stat(token); err != nil {
		t.Fatalf("the token file must stay while the lock is held: %v", err)
	}
	unlock()
	if err := deleteTokens(done, dir, "slack", 1); err != nil {
		t.Fatalf("delete after the lock is free: %v", err)
	}
	if _, err := os.Stat(token); !os.IsNotExist(err) {
		t.Fatalf("the token file is still there: %v", err)
	}
}

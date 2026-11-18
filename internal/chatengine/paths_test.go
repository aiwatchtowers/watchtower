package chatengine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/platform"
)

// socketPathsFixture is testdata/socket_paths.json, read by Go and by the
// Swift ChatSocketPathsTests.
type socketPathsFixture struct {
	Max   int `json:"max"`
	Cases []struct {
		Name          string `json:"name"`
		Workspace     string `json:"workspace"`
		TempDir       string `json:"temp_dir"`
		Conversation  int64  `json:"conversation"`
		ChatSocket    string `json:"chat_socket"`
		SessionSocket string `json:"session_socket"`
	} `json:"cases"`
}

func TestSocketPath_FixtureCases(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "socket_paths.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f socketPathsFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if f.Max != 103 || len(f.Cases) == 0 {
		t.Fatalf("fixture max = %d, %d cases", f.Max, len(f.Cases))
	}
	for _, c := range f.Cases {
		if got := socketPath(c.Workspace, c.TempDir, f.Max); got != c.ChatSocket {
			t.Errorf("%s: chat socket = %q, want %q", c.Name, got, c.ChatSocket)
		}
		if got := sessionSocketPath(c.Workspace, c.TempDir, c.Conversation, f.Max); got != c.SessionSocket {
			t.Errorf("%s: session socket = %q, want %q", c.Name, got, c.SessionSocket)
		}
	}
}

// The exported rule over this platform's bound: a workspace whose socket
// would be too long gets one under the temp folder, short enough, the same
// for every call; a short one keeps <workspace>/chat.sock.
func TestSocketPath_TooLongFallsBackToTempDir(t *testing.T) {
	tmp := "/tmp"
	short := "/Users/acme/ws"
	if got := SocketPath(short, tmp); got != short+"/chat.sock" {
		t.Errorf("short workspace: %q", got)
	}
	if got := SessionSocketPath(short, tmp, 5); got != short+"/chatengine/sessions/5.sock" {
		t.Errorf("short workspace session: %q", got)
	}
	long := "/Users/acme/" + strings.Repeat("w", platform.MaxSocketPath)
	got := SocketPath(long, tmp)
	if !strings.HasPrefix(got, tmp+"/"+fallbackPrefix) || len(got) > platform.MaxSocketPath {
		t.Errorf("long workspace: %q", got)
	}
	if again := SocketPath(long+"/", tmp+"/"); again != got {
		t.Errorf("not stable: %q vs %q", again, got)
	}
	if s := SessionSocketPath(long, tmp, 5); s != filepath.Join(filepath.Dir(got), "sessions", "5.sock") {
		t.Errorf("long workspace session: %q", s)
	}
	if other := SocketPath(long+"x", tmp); other == got {
		t.Error("two workspaces share a fallback socket")
	}
}

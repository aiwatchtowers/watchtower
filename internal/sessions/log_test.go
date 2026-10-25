package sessions

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSessionLog_Rotates(t *testing.T) {
	prev := MaxLogSize
	MaxLogSize = 100
	t.Cleanup(func() { MaxLogSize = prev })

	path := filepath.Join(t.TempDir(), "sessions.log")
	sl := NewSessionLog(path)
	for range 30 {
		sl.Log(SessionEvent{Timestamp: "2026-10-25T00:00:00Z", SessionID: "s1", Action: "created", Source: "digest.channel"})
	}

	if _, err := os.Stat(path + ".1"); err != nil {
		t.Fatalf("sessions.log.1 missing: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	line := int64(len(`{"ts":"2026-10-25T00:00:00Z","session_id":"s1","action":"created","source":"digest.channel","duration_ms":0}` + "\n"))
	if info.Size() > MaxLogSize+line {
		t.Errorf("sessions.log is %d bytes, want at most %d", info.Size(), MaxLogSize+line)
	}
}

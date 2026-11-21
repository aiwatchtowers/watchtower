//go:build measure

package sources

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionfeed"
)

// measureSamples is how many appends TestMeasure_ChatFileEventToChange times.
const measureSamples = 10

// TestMeasure_ChatFileEventToChange is the hub-side half of the phone
// Workchat latency promise (#2112 Task 10): the wall time from a transcript
// append to the session_chat source's OnChange (the publisher's fast-lane
// nudge), with the real fsnotify watcher, StandardChatTiming and a real
// sessionfeed.ReadChat of a Claude-format transcript. It does not cover the
// relay hop or the phone's apply. Not part of the default run (wall-clock):
//
//	go test -tags measure ./internal/hub/slices/sources -run TestMeasure_ -v
//
// Each append is a new Bash step, so every read changes the live block;
// appends are 2 s apart, past MinGap, so each sample is a lone event.
func TestMeasure_ChatFileEventToChange(t *testing.T) {
	conv := filepath.Join(t.TempDir(), "conv.jsonl")
	if err := os.WriteFile(conv, []byte(measureUser("u0", "run the tests")), 0o600); err != nil {
		t.Fatal(err)
	}
	changed := make(chan time.Time, 64)
	convs := []sessionfeed.Conversation{{AgentSessionID: "c1", Path: conv}}
	watches := handlers.NewChatWatchRegistry()
	s := SessionChat(watches, nil, SessionChatOptions{
		Fetch: func(context.Context, int64, string) (ChatRead, error) {
			r, err := sessionfeed.ReadChat(convs, sessionfeed.ReadOptions{Now: time.Now()})
			if err != nil {
				return ChatRead{}, err
			}
			return ChatRead{Entries: r.Feed.Entries, Live: r.Live, LiveErr: r.LiveErr, Paths: r.Paths}, nil
		},
		Conversations: func(context.Context, int64) ([]sessionfeed.Conversation, error) { return convs, nil },
		AgentSessions: func(context.Context, int64) ([]string, error) { return []string{"c1"}, nil },
		Liveness:      func() Liveness { return Liveness{Runs: map[int64]time.Time{7: time.Now()}} },
		OnChange:      func() { changed <- time.Now() },
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	t.Cleanup(func() { cancel(); <-done })
	s.RequestWatches().Watch(handlers.ChatWatch{SessionID: 7, Expires: time.Now().Add(handlers.ChatWatchLength)})
	go func() { done <- s.Run(ctx) }()
	wait := func(what string) time.Time {
		t.Helper()
		select {
		case at := <-changed:
			return at
		case <-time.After(10 * time.Second):
			t.Fatalf("no change: %s", what)
			return time.Time{}
		}
	}
	wait("the open read")
	time.Sleep(2 * time.Second) // the watch is armed after the open read; let it settle
	var got []time.Duration
	for i := 1; i <= measureSamples; i++ {
		f, err := os.OpenFile(conv, os.O_APPEND|os.O_WRONLY, 0)
		if err != nil {
			t.Fatal(err)
		}
		start := time.Now()
		if _, err := f.WriteString(measureBash("a"+strconv.Itoa(i), "t"+strconv.Itoa(i), "go test ./internal/x"+strconv.Itoa(i))); err != nil {
			t.Fatal(err)
		}
		if err := f.Close(); err != nil {
			t.Fatal(err)
		}
		got = append(got, wait("append "+strconv.Itoa(i)).Sub(start))
		time.Sleep(2 * time.Second)
	}
	sorted := slices.Clone(got)
	slices.Sort(sorted)
	t.Logf("measure: append → OnChange samples %v", got)
	// p50 and p90 by nearest rank.
	t.Logf("measure: append → OnChange median %s p90 %s min %s max %s (n=%d)",
		sorted[len(sorted)/2].Round(time.Millisecond), sorted[(len(sorted)*9+9)/10-1].Round(time.Millisecond),
		sorted[0].Round(time.Millisecond), sorted[len(sorted)-1].Round(time.Millisecond), len(sorted))
}

func measureLine(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b) + "\n"
}

func measureUser(uuid, text string) string {
	return measureLine(map[string]any{"type": "user", "uuid": uuid, "timestamp": time.Now().UTC().Format(time.RFC3339Nano),
		"message": map[string]any{"role": "user", "content": text}})
}

func measureBash(uuid, toolID, command string) string {
	return measureLine(map[string]any{"type": "assistant", "uuid": uuid, "timestamp": time.Now().UTC().Format(time.RFC3339Nano),
		"message": map[string]any{"id": "m-" + uuid, "role": "assistant", "content": []map[string]any{
			{"type": "tool_use", "id": toolID, "name": "Bash", "input": map[string]any{"command": command}},
		}}})
}

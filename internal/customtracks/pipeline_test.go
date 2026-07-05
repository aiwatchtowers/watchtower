package customtracks

import (
	"context"
	"strings"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mockGenerator returns a canned AI response and records the calls it saw. For
// the two-stage backfill it returns shortlistResp to the stage-1 (title) prompt
// and out to the stage-2 (extract) prompt, distinguished by their headers. A
// zero-value mock fails the test if Generate is ever called (calls stays > 0).
type mockGenerator struct {
	out           string
	shortlistResp string
	err           error
	lastSys       string
	lastUser      string
	calls         int
}

func (m *mockGenerator) Generate(ctx context.Context, sys, user, sess string) (string, *digest.Usage, string, error) {
	m.calls++
	m.lastSys = sys
	m.lastUser = user
	if m.err != nil {
		return "", nil, "", m.err
	}
	if m.shortlistResp != "" && strings.Contains(user, "ACTIVITY TITLES:") {
		return m.shortlistResp, &digest.Usage{}, "", nil
	}
	return m.out, &digest.Usage{}, "", nil
}

func TestScanEmptyActivityAdvancesWatermarkNoAICall(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid, _ := d.CreateCustomTrack(db.Track{AssigneeUserID: "U1", Text: "watch", Instruction: "i"})
	mock := &mockGenerator{} // fails the test if Generate is called

	p := New(d, mock, "", nil)

	events, err := p.RunForTrack(context.Background(), int(tid))
	if err != nil {
		t.Fatalf("RunForTrack: %v", err)
	}
	if len(events) != 0 {
		t.Fatalf("expected no events on empty activity, got %d", len(events))
	}
	if mock.calls != 0 {
		t.Fatalf("AI called %d times on empty activity; want 0", mock.calls)
	}
	got, _ := d.GetTrackByID(int(tid))
	if got.LastRunAt == "" {
		t.Fatal("watermark not advanced on empty activity")
	}
}

func TestComposeParsesTitleAndInstruction(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	mock := &mockGenerator{out: `{"title":"HashBank refund","instruction":"watch the refund decision"}`}
	p := New(d, mock, "", nil)
	res, err := p.Compose(context.Background(), 0, "watch the hashbank refund")
	if err != nil {
		t.Fatalf("Compose: %v", err)
	}
	if res.Title != "HashBank refund" || res.Instruction == "" {
		t.Fatalf("bad compose result: %+v", res)
	}
}

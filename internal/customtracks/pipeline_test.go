package customtracks

import (
	"context"
	"encoding/json"
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

// TestEncodeRefsDropsUnsafeRefs pins that only absolute URLs with an allowed
// scheme survive into source_refs. The Desktop timeline renders each stored
// ref as Link(destination:), so a model-invented ref must be dropped here
// rather than shipped to the UI as a clickable dead — or hostile — link.
func TestEncodeRefsDropsUnsafeRefs(t *testing.T) {
	kept := []string{
		"https://acme.slack.com/archives/C123/p1714567890123456",
		"http://jira.internal/browse/PROJ-1",
		"slack://channel?team=T1&id=C1",
		"mailto:someone@example.com",
		"HTTPS://acme.slack.com/archives/C1/p1", // scheme casing is the author's
	}
	for _, ref := range kept {
		// Compare decoded, not raw: json.Marshal escapes & as &.
		got := decodeRefs(t, encodeRefs([]string{ref}))
		if len(got) != 1 || got[0] != ref {
			t.Errorf("encodeRefs(%q) = %v; want it kept", ref, got)
		}
	}

	dropped := []string{
		"javascript:alert(document.cookie)",
		"data:text/html;base64,PHNjcmlwdD4=",
		"file:///etc/passwd",
		"the #general thread where this was decided", // prose, not a link
		"/archives/C123/p1714567890123456",           // relative
		"https://",                                   // scheme but no host
		"",
		"   ",
	}
	for _, ref := range dropped {
		if got := encodeRefs([]string{ref}); got != "[]" {
			t.Errorf("encodeRefs(%q) = %s; want it dropped as []", ref, got)
		}
	}
}

// TestEncodeRefsKeepsValidRefsAlongsideInvalid verifies filtering is per-ref:
// one bad entry must not discard the good ones it travelled with.
func TestEncodeRefsKeepsValidRefsAlongsideInvalid(t *testing.T) {
	got := decodeRefs(t, encodeRefs([]string{
		"javascript:alert(1)",
		"  https://acme.slack.com/archives/C1/p1  ",
		"not a link at all",
	}))
	want := "https://acme.slack.com/archives/C1/p1"
	if len(got) != 1 || got[0] != want {
		t.Fatalf("encodeRefs = %v; want exactly [%s]", got, want)
	}
}

// decodeRefs parses an encodeRefs result back into the slice the Desktop sees.
func decodeRefs(t *testing.T, encoded string) []string {
	t.Helper()
	var refs []string
	if err := json.Unmarshal([]byte(encoded), &refs); err != nil {
		t.Fatalf("encodeRefs produced invalid JSON %q: %v", encoded, err)
	}
	return refs
}

// TestEncodeRefsEmptyIsAlwaysJSONArray keeps the never-"" contract: the value
// goes into a NOT NULL JSON column and is decoded by the Desktop.
func TestEncodeRefsEmptyIsAlwaysJSONArray(t *testing.T) {
	if got := encodeRefs(nil); got != "[]" {
		t.Errorf("encodeRefs(nil) = %s; want []", got)
	}
	if got := encodeRefs([]string{}); got != "[]" {
		t.Errorf("encodeRefs(empty) = %s; want []", got)
	}
}

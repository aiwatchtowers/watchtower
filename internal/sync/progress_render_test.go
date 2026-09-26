package sync

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestProgress_Render_DelegatesToRenderSnapshot(t *testing.T) {
	p := NewProgress()
	got := p.Render("test-workspace")
	// Cosmetic styles add ANSI but the workspace name must appear in output.
	assert.Contains(t, got, "test-workspace")
}

func TestProgress_Render_ChangesAfterPhase(t *testing.T) {
	p := NewProgress()
	pre := p.Render("ws")
	p.SetPhase(PhaseDone)
	post := p.Render("ws")
	assert.NotEqual(t, pre, post, "render output should change after MarkDone")
	assert.Contains(t, post, "Synced ws workspace")
}

func TestExtractThreadTSFromPermalink_Match(t *testing.T) {
	got := extractThreadTSFromPermalink("https://x.slack.com/archives/C1/p123?thread_ts=1700000000.000100")
	if !got.Valid {
		t.Fatal("expected non-null thread_ts")
	}
	assert.Equal(t, "1700000000.000100", got.String)
}

func TestExtractThreadTSFromPermalink_TrimsTrailingParams(t *testing.T) {
	got := extractThreadTSFromPermalink("https://x.slack.com/archives/C1/p123?thread_ts=1700000000.000100&cid=C1")
	assert.True(t, got.Valid)
	assert.Equal(t, "1700000000.000100", got.String)
}

func TestExtractThreadTSFromPermalink_NoThreadTS(t *testing.T) {
	got := extractThreadTSFromPermalink("https://x.slack.com/archives/C1/p123")
	assert.False(t, got.Valid)
}

func TestExtractThreadTSFromPermalink_EmptyValue(t *testing.T) {
	got := extractThreadTSFromPermalink("https://x.slack.com/archives/C1/p123?thread_ts=&other=1")
	assert.False(t, got.Valid)
}

func TestExtractThreadTSFromPermalink_EmptyInput(t *testing.T) {
	got := extractThreadTSFromPermalink("")
	assert.False(t, got.Valid)
}

func TestParseSlackTS_Valid(t *testing.T) {
	tt, err := parseSlackTS("1700000000.000100")
	assert.NoError(t, err)
	assert.Equal(t, int64(1700000000), tt.Unix())
}

func TestParseSlackTS_NoFraction(t *testing.T) {
	tt, err := parseSlackTS("1700000000")
	assert.NoError(t, err)
	assert.Equal(t, int64(1700000000), tt.Unix())
}

func TestParseSlackTS_Invalid(t *testing.T) {
	cases := []string{"", ".123", "abc", "abc.def"}
	for _, c := range cases {
		t.Run(c, func(t *testing.T) {
			_, err := parseSlackTS(c)
			assert.Error(t, err)
		})
	}
}

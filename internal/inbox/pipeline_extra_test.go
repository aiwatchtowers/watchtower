package inbox

import (
	"fmt"
	"log"
	"strings"
	"testing"
	"unicode/utf8"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestPipeline_AccumulatedUsage_AlwaysZero pins the post-demolition contract:
// Run makes no AI call, so the usage the daemon and CLI report is always zero.
func TestPipeline_AccumulatedUsage_AlwaysZero(t *testing.T) {
	p := &Pipeline{}
	in, out, cost, total := p.AccumulatedUsage()
	assert.Equal(t, 0, in)
	assert.Equal(t, 0, out)
	assert.Equal(t, float64(0), cost)
	assert.Equal(t, 0, total)
}

func TestLoadContext_ResolvesMentionInMessageText(t *testing.T) {
	// Item context lines already resolve the author name; raw `<@U…>` mentions
	// inside the text must resolve too instead of being dropped.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	p := New(d, testConfig(), nil, log.Default())
	p.SetOwner(db.Owner{ID: "U1", SlackUserID: "U1", Email: "u1@test.com"})

	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "ask <@U3> about the rollout")
	insertMessage(t, d, "C1", "100.2", "U2", "any update?")

	ctx := p.loadContext("C1", "100.2", "")
	assert.Contains(t, ctx, "ask @Bob Brown about the rollout")
}

// TestLoadContext_TruncatesByRunesNotBytes pins that the persisted item
// context is cut on rune boundaries: byte-slicing Cyrillic text (2 bytes per
// rune) at an odd offset writes invalid UTF-8 into inbox_items.context, which
// Catch-Up, the briefing and meeting prep all read.
func TestLoadContext_TruncatesByRunesNotBytes(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	p := New(d, testConfig(), nil, log.Default())
	insertChannel(t, d, "C1", "public")

	// A leading ASCII byte puts every Cyrillic rune on an odd byte offset, so
	// a byte cut at 200 lands mid-rune.
	long := "x" + strings.Repeat("ж", 400)
	for i := 1; i <= 5; i++ {
		insertMessage(t, d, "C1", fmt.Sprintf("100.%d", i), "U2", long)
	}
	insertMessage(t, d, "C1", "100.9", "U2", "latest")

	ctx := p.loadContext("C1", "100.9", "")
	require.NotEmpty(t, ctx)
	assert.True(t, utf8.ValidString(ctx), "item context must stay valid UTF-8")
	for _, line := range strings.Split(ctx, "\n") {
		assert.LessOrEqual(t, utf8.RuneCountInString(line), len("[U2] ")+200+len("..."), "each line is capped at 200 runes of text")
	}
}

// TestLoadContext_ShortLinesUntouched is the degenerate branch: text within
// the caps is persisted verbatim, with no ellipsis appended.
func TestLoadContext_ShortLinesUntouched(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	p := New(d, testConfig(), nil, log.Default())
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "короткое сообщение")
	insertMessage(t, d, "C1", "100.2", "U2", "latest")

	ctx := p.loadContext("C1", "100.2", "")
	assert.Contains(t, ctx, "короткое сообщение")
	assert.NotContains(t, ctx, "...")
}

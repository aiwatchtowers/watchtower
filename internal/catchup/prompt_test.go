package catchup

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

func TestBuildComposeUserMessage_SectionsAndTags(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	g := gathered{
		Digests: []db.CatchupItem{{Area: "digests", ID: 12, Title: "#eng", Body: "shipped\n- Deploy: v2", Meta: "41 messages · to Thu 17:40"}},
		Inbox:   []db.CatchupItem{{Area: "inbox", ID: 7, Title: "mention", Body: "can you review?", Meta: "from Ann in #eng"}},
	}
	msg, used := buildComposeUserMessage(promptInput{Window: Window{From: now.Add(-time.Hour), To: now}, Profile: "CTO", Prefs: "PREFS", Correction: "shorter"}, g, 0)
	assert.Contains(t, msg, "WINDOW: Fri 4 Sep 17:30 → Fri 4 Sep 18:30")
	assert.Contains(t, msg, "OPERATOR PROFILE:\nCTO")
	assert.Contains(t, msg, "PREFS")
	assert.Contains(t, msg, "OPERATOR CORRECTION: shorter")
	assert.Contains(t, msg, "=== SLACK DIGESTS (1) ===\n[digests#12] #eng — 41 messages · to Thu 17:40\n  shipped\n  - Deploy: v2")
	assert.Contains(t, msg, "=== FOR YOU — INBOX (1) ===\n[inbox#7] mention — from Ann in #eng\n  can you review?")
	assert.NotContains(t, msg, "=== MEETINGS", "empty sections omitted")
	assert.Len(t, used.Digests, 1)
	assert.Len(t, used.Inbox, 1)
	_, ok := used.byRef[refKey{"inbox", 7}]
	assert.True(t, ok, "returned gathered is indexed")
}

func TestBuildComposeUserMessage_NoProfile(t *testing.T) {
	g := gathered{Inbox: []db.CatchupItem{{Area: "inbox", ID: 1, Title: "dm", Body: "hi"}}}
	msg, _ := buildComposeUserMessage(promptInput{}, g, 0)
	assert.Contains(t, msg, "OPERATOR PROFILE:\n(none)")
	assert.NotContains(t, msg, "OPERATOR CORRECTION")
	assert.Contains(t, msg, "[inbox#1] dm\n", "no Meta → no em dash tail")
}

func TestBuildComposeUserMessage_BudgetTrimOrder(t *testing.T) {
	big := strings.Repeat("x", 200)
	item := func(area string, id int) db.CatchupItem {
		return db.CatchupItem{Area: area, ID: id, Title: "t", Body: big}
	}
	g := gathered{
		Digests:   []db.CatchupItem{item("digests", 1), item("digests", 2)},
		Streams:   []db.CatchupItem{item("streams", 1), item("streams", 2)},
		Decisions: []db.CatchupItem{item("decisions", 1)},
		Tracks:    []db.CatchupItem{item("tracks", 1)},
		Inbox:     []db.CatchupItem{item("inbox", 1)},
		Targets:   []db.CatchupItem{item("targets", 1)},
		Meetings:  []db.CatchupItem{item("recaps", 1)},
	}
	full, _ := buildComposeUserMessage(promptInput{}, g, 0)
	// One dropped item shrinks the message by ~200 body chars + its line; a
	// budget of full-550 needs three drops: streams#2, streams#1, tracks#1.
	budget := len(full) - 550
	msg, used := buildComposeUserMessage(promptInput{}, g, budget)
	assert.LessOrEqual(t, len(msg), budget)
	assert.Empty(t, used.Streams, "streams trimmed first")
	assert.Empty(t, used.Tracks, "then tracks")
	assert.Len(t, used.Decisions, 1)
	assert.Len(t, used.Digests, 2)
	assert.Len(t, used.Inbox, 1, "inbox never trimmed")
	assert.Len(t, used.Targets, 1)
	assert.Len(t, used.Meetings, 1)
	assert.NotContains(t, msg, "[streams#1]", "trimmed items leave the message")
	_, ok := used.byRef[refKey{"streams", 1}]
	assert.False(t, ok, "trimmed items leave the index")
}

func TestBuildComposeUserMessage_PerItemTrim(t *testing.T) {
	g := gathered{Inbox: []db.CatchupItem{{Area: "inbox", ID: 1, Title: "dm", Body: strings.Repeat("y", 1000)}}}
	msg, _ := buildComposeUserMessage(promptInput{}, g, 0)
	assert.Less(t, strings.Count(msg, "y"), 300)
	assert.Contains(t, msg, "…")
}

func TestBuildComposeUserMessage_UntrimmableOverBudgetStops(t *testing.T) {
	g := gathered{Inbox: []db.CatchupItem{{Area: "inbox", ID: 1, Title: "dm", Body: "hello"}}}
	msg, used := buildComposeUserMessage(promptInput{}, g, 10)
	assert.Greater(t, len(msg), 10, "nothing trimmable → message stays over budget, no infinite loop")
	assert.Len(t, used.Inbox, 1)
}

func TestGathered_IsEmptyAndIndex(t *testing.T) {
	var empty gathered
	assert.True(t, empty.isEmpty())
	g := gathered{
		Meetings: []db.CatchupItem{{Area: "recaps", ID: 3, Title: "standup"}},
		Targets:  []db.CatchupItem{{Area: "targets", ID: 9, Title: "ship"}},
	}
	assert.False(t, g.isEmpty())
	g.index()
	assert.Equal(t, "standup", g.byRef[refKey{"recaps", 3}].Title)
	assert.Equal(t, "ship", g.byRef[refKey{"targets", 9}].Title)
	assert.Len(t, g.byRef, 2)
}

func TestBuildLearnUserMessage(t *testing.T) {
	topic := Topic{Title: "Payments migration", Narrative: "blocked\non infra", Priority: "high"}
	refs := []learnRef{
		{Area: "digests", ChannelID: "1:C123", Label: "#eng"},
		{Area: "inbox", SenderID: "1:U9", Label: "mention"},
	}
	msg := buildLearnUserMessage(topic, refs, -1, "  #eng is noise  ")
	assert.Contains(t, msg, "TOPIC: Payments migration\n")
	assert.Contains(t, msg, "NARRATIVE: blocked on infra\n")
	assert.Contains(t, msg, "TOPIC PRIORITY: high\n")
	assert.Contains(t, msg, "SOURCE REFS (use the supplied ids to build scope keys):\n")
	assert.Contains(t, msg, "- area=digests channel_id=1:C123 label=#eng\n")
	assert.Contains(t, msg, "- area=inbox sender_user_id=1:U9 label=mention\n")
	assert.Contains(t, msg, "OPERATOR RATING: dislike\n")
	assert.Contains(t, msg, "OPERATOR COMMENT: #eng is noise\n")

	liked := buildLearnUserMessage(Topic{Title: "T", Priority: "low"}, nil, 1, "keep it")
	assert.Contains(t, liked, "OPERATOR RATING: like\n")
	assert.Contains(t, liked, "SOURCE REFS (use the supplied ids to build scope keys):\n(none)\n")
	assert.NotContains(t, liked, "NARRATIVE:", "no narrative → no line")
}

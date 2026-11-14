package db

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedLiveConversation makes a "target" conversation of four user/assistant
// pairs at 2026-10-24 10:00 + n minutes. The third pair is the Live turn:
// live_slack_since is that turn's assistant message id. The Live turn's owner
// prompt precedes it and stays readable; the Live answer and every later
// message (the fourth pair, which has no Slack step of its own) are excluded.
func seedLiveConversation(t *testing.T, d *DB) (conv int64, users, assistants []int64, base time.Time) {
	t.Helper()
	base = time.Date(2026, 10, 24, 10, 0, 0, 0, time.UTC)
	conv = insertChatConversation(t, d, "target", "7")
	for i, q := range []string{"question one", "question two", "question three live", "question four after live"} {
		at := float64(base.Add(time.Duration(i) * time.Minute).Unix())
		users = append(users, insertChatMessage(t, d, conv, "user", q, at))
		assistants = append(assistants, insertChatMessage(t, d, conv, "assistant", "answer "+q, at))
	}
	_, err := d.Exec(`UPDATE chat_conversations SET live_slack_since = ? WHERE id = ?`, assistants[2], conv)
	require.NoError(t, err)
	return conv, users, assistants, base
}

func TestLIVE01_MarkedTurnsStayOutOfStores(t *testing.T) {
	d := openTestDB(t)
	conv, users, assistants, base := seedLiveConversation(t, d)
	kept := []int64{users[0], assistants[0], users[1], assistants[1], users[2]}

	ideas, err := d.ListChatTurnsForIdeas(0, base.Add(time.Hour).Format(time.RFC3339), 50)
	require.NoError(t, err)
	var got []int64
	for _, x := range ideas {
		got = append(got, x.ID)
	}
	assert.Equal(t, kept, got, "ideas")

	mem, err := d.ListOwnerChatTurns(0, []string{"target"})
	require.NoError(t, err)
	got = nil
	for _, x := range mem {
		got = append(got, x.ID)
	}
	assert.Equal(t, []int64{users[0], users[1], users[2]}, got, "memory")

	since, err := d.ListOwnerChatTurnsSince(base.Add(-time.Hour))
	require.NoError(t, err)
	require.Len(t, since, 3, "instructions miner / coach")

	recent, err := d.ListRecentChatTurns("target", "7", 20)
	require.NoError(t, err)
	got = nil
	for _, x := range recent {
		got = append(got, x.ID)
	}
	assert.Equal(t, kept, got, "next step")

	ok, err := d.OwnerChatTurnExists(conv, base.Add(2*time.Minute).Unix(), []string{"target"})
	require.NoError(t, err)
	assert.True(t, ok, "the Live turn's owner prompt is the owner's own words")
	ok, err = d.OwnerChatTurnExists(conv, base.Add(3*time.Minute).Unix(), []string{"target"})
	require.NoError(t, err)
	assert.False(t, ok, "a later owner turn is not an evidence turn")
}

func TestLIVE01_LaterTurnsMarked(t *testing.T) {
	d := openTestDB(t)
	conv, users, assistants, base := seedLiveConversation(t, d)
	rows, err := d.ListOwnerChatTurns(assistants[2]-1, []string{"target"})
	require.NoError(t, err)
	assert.Empty(t, rows, "nothing from the Live answer on")
	_ = users

	// An unmarked conversation is read in full.
	other := insertChatConversation(t, d, "target", "8")
	insertChatMessage(t, d, other, "user", "plain", float64(base.Unix()))
	rows, err = d.ListOwnerChatTurns(0, []string{"target"})
	require.NoError(t, err)
	require.Len(t, rows, 4)
	assert.Equal(t, other, rows[3].ConversationID)

	// A message added later is still hidden.
	late := insertChatMessage(t, d, conv, "user", "turn five", float64(base.Add(time.Hour).Unix()))
	rows, err = d.ListOwnerChatTurns(0, []string{"target"})
	require.NoError(t, err)
	for _, r := range rows {
		assert.NotEqual(t, late, r.ID)
	}
}

func TestLIVE01_LiveSlackOwnerLineOK(t *testing.T) {
	d := openTestDB(t)
	conv, users, _, _ := seedLiveConversation(t, d)
	_, err := d.Exec(`UPDATE chat_messages SET text = ? WHERE id = ?`, "remember:  keep it\n  short   and clear", users[3])
	require.NoError(t, err)
	ok, err := d.LiveSlackOwnerLineOK(conv, users[3], "keep it short and clear")
	require.NoError(t, err)
	assert.True(t, ok, "a multi-line, double-spaced owner message passes")
	ok, err = d.LiveSlackOwnerLineOK(conv, users[3], "text a Live answer wrote")
	require.NoError(t, err)
	assert.False(t, ok)
	unmarked := insertChatConversation(t, d, "target", "9")
	ok, err = d.LiveSlackOwnerLineOK(unmarked, 1, "anything")
	require.NoError(t, err)
	assert.True(t, ok)
}

// liveCheckedReaders read chat text into a lasting store and apply the mark.
var liveCheckedReaders = map[string]bool{
	"ListChatTurnsForIdeas":   true, // ideas
	"ListOwnerChatTurns":      true, // memory
	"OwnerChatTurnExists":     true, // memory evidence
	"ListOwnerChatTurnsSince": true, // instructions miner / coach
	"ListRecentChatTurns":     true, // target next step
	"LiveSlackOwnerLineOK":    true, // remember:
}

// displayOnlyReaders touch the chat tables without feeding a lasting store.
var displayOnlyReaders = map[string]string{
	"activeBranchCTE":                  "SQL fragment of the chat engine's own branch walk",
	"onActiveBranch":                   "SQL fragment of the chat engine's own branch walk",
	"ChatNotLiveSlack":                 "the predicate itself",
	"ChatNotPrivateMeeting":            "the private-meeting predicate",
	"GetChatConversation":              "the chat engine reads its own conversation row (title, session, routing)",
	"SetChatRouting":                   "routing columns only",
	"ChatTablesPresent":                "table existence probe",
	"ActiveChatPath":                   "the chat engine's own history for its next turn",
	"SetChatTitle":                     "writes a title",
	"SetChatActual":                    "routing columns only",
	"normalizeLegacyChatTables":        "schema repair of old chat tables",
	"MeetingChatArtifactKeys":          "keys for a private-recording drop, no text",
	"OwnerThreadLines":                 "spec review thread only, never a chat that can use the Slack connector",
	"ImportDraftCache":                 "existence count of a conversation id, no text",
	"InsertChatCoachProposal":          "existence check of a conversation id, no text",
	"IdeasChatFloorTop":                "MAX(id), a number with no text",
	"deleteWorkbenchCodeQuestions":     "delete only",
	"deleteWorkbenchSpecReviewThreads": "delete only",
	"keptJoin":                         "the knowledge source's join: it skips a marked conversation (internal/kb TestLIVE01_KeptArtifactSkipped)",
}

// TestLIVE01_ReaderList fails when a non-test function in internal/ mentions
// chat_messages or chat_conversations without being on one of the two lists.
func TestLIVE01_ReaderList(t *testing.T) {
	root := filepath.Join("..", "..", "internal")
	re := regexp.MustCompile(`chat_messages|chat_conversations`)
	var unknown []string
	fset := token.NewFileSet()
	require.NoError(t, filepath.WalkDir(root, func(p string, de fs.DirEntry, err error) error {
		if err != nil || de.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return err
		}
		src, err := os.ReadFile(p) //nolint:gosec // the test reads the repo's own source tree
		if err != nil {
			return err
		}
		f, err := parser.ParseFile(fset, p, src, parser.ParseComments)
		if err != nil {
			return nil //nolint:nilerr // a file that does not parse is not a reader
		}
		check := func(name string, from, to token.Pos) {
			body := string(src[fset.Position(from).Offset:fset.Position(to).Offset])
			if re.MatchString(body) && !liveCheckedReaders[name] {
				if _, ok := displayOnlyReaders[name]; !ok {
					unknown = append(unknown, filepath.Base(p)+":"+name)
				}
			}
		}
		for _, decl := range f.Decls {
			switch x := decl.(type) {
			case *ast.FuncDecl:
				if x.Body != nil {
					check(x.Name.Name, x.Body.Pos(), x.Body.End())
				}
			case *ast.GenDecl:
				for _, sp := range x.Specs {
					if vs, ok := sp.(*ast.ValueSpec); ok {
						check(vs.Names[0].Name, vs.Pos(), vs.End())
					}
				}
			}
		}
		return nil
	}))
	assert.Empty(t, unknown, "a function reads the chat tables: apply db.ChatNotLiveSlack and list it in liveCheckedReaders, or list it in displayOnlyReaders with its reason (LIVE-01)")
	for name := range liveCheckedReaders {
		assert.NotContains(t, displayOnlyReaders, name)
	}
}

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

// seedLiveConversation makes a "target" conversation with four owner turns at
// 2026-10-24 10:00 + n minutes; live_slack_since is the id of turn 3.
func seedLiveConversation(t *testing.T, d *DB) (conv int64, ids []int64, base time.Time) {
	t.Helper()
	base = time.Date(2026, 10, 24, 10, 0, 0, 0, time.UTC)
	conv = insertChatConversation(t, d, "target", "7")
	for i, txt := range []string{"turn one", "turn two", "turn three live", "turn four after live"} {
		ids = append(ids, insertChatMessage(t, d, conv, "user", txt, float64(base.Add(time.Duration(i)*time.Minute).Unix())))
	}
	_, err := d.Exec(`UPDATE chat_conversations SET live_slack_since = ? WHERE id = ?`, ids[2], conv)
	require.NoError(t, err)
	return conv, ids, base
}

func TestLIVE01_MarkedTurnsStayOutOfStores(t *testing.T) {
	d := openTestDB(t)
	conv, ids, base := seedLiveConversation(t, d)

	ideas, err := d.ListChatTurnsForIdeas(0, base.Add(time.Hour).Format(time.RFC3339), 50)
	require.NoError(t, err)
	var got []int64
	for _, x := range ideas {
		got = append(got, x.ID)
	}
	assert.Equal(t, ids[:2], got, "ideas")

	mem, err := d.ListOwnerChatTurns(0, []string{"target"})
	require.NoError(t, err)
	require.Len(t, mem, 2, "memory")
	assert.Equal(t, ids[1], mem[1].ID)

	since, err := d.ListOwnerChatTurnsSince(base.Add(-time.Hour))
	require.NoError(t, err)
	require.Len(t, since, 2, "instructions miner / coach")

	recent, err := d.ListRecentChatTurns("target", "7", 10)
	require.NoError(t, err)
	require.Len(t, recent, 2, "next step")

	ok, err := d.OwnerChatTurnExists(conv, base.Add(time.Minute).Unix(), []string{"target"})
	require.NoError(t, err)
	assert.True(t, ok)
	ok, err = d.OwnerChatTurnExists(conv, base.Add(2*time.Minute).Unix(), []string{"target"})
	require.NoError(t, err)
	assert.False(t, ok, "the first Live turn is not an evidence turn")
}

func TestLIVE01_LaterTurnsMarked(t *testing.T) {
	d := openTestDB(t)
	conv, ids, base := seedLiveConversation(t, d)
	// Turn four carried no Slack step of its own; it is still after the mark.
	rows, err := d.ListOwnerChatTurns(ids[2]-1, []string{"target"})
	require.NoError(t, err)
	assert.Empty(t, rows)
	// A conversation without a mark is read in full.
	other := insertChatConversation(t, d, "target", "8")
	insertChatMessage(t, d, other, "user", "plain", float64(base.Unix()))
	rows, err = d.ListOwnerChatTurns(0, []string{"target"})
	require.NoError(t, err)
	require.Len(t, rows, 3)
	assert.Equal(t, other, rows[2].ConversationID)

	// A later turn is added: still hidden.
	late := insertChatMessage(t, d, conv, "user", "turn five", float64(base.Add(time.Hour).Unix()))
	rows, err = d.ListOwnerChatTurns(0, []string{"target"})
	require.NoError(t, err)
	for _, r := range rows {
		assert.NotEqual(t, late, r.ID)
	}
}

func TestLIVE01_LiveSlackOwnerLineOK(t *testing.T) {
	d := openTestDB(t)
	conv, ids, _ := seedLiveConversation(t, d)
	ok, err := d.LiveSlackOwnerLineOK(conv, ids[3], "after live")
	require.NoError(t, err)
	assert.True(t, ok)
	ok, err = d.LiveSlackOwnerLineOK(conv, ids[3], "text a Live answer wrote")
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
		src, err := os.ReadFile(p)
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

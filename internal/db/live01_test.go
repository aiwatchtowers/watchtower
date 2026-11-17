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

// displayOnlyReadersAt is displayOnlyReaders for functions added since the
// iPhone chat (#1791): each key names one function in one file
// ("<path under internal/>:<name>"), so a generic name such as Delete or
// send never covers a same-named function elsewhere. New entries go here,
// never into the bare-name list above; a key whose function the scan no
// longer sees fails the test.
var displayOnlyReadersAt = map[string]string{
	"tools/chat_history.go:boundConversation": "reads the bound conversation's context_type to refuse isolated threads; no text. The chat-history tools hand a chat its own rows for its next answer, like ActiveChatPath",
	"db/chat_lease.go:markSessionLostSQL":     "writes the error code of a dead turn's reply (MarkChatTurnSessionLost, chat.recover, chat.release_launches); reads no text",
	// internal/hub chat_answer push: ids, status and the conversation title only.
	"hub/chat_turn_watch.go:send":            "the chat_answer push reads a conversation title, never message text into a store",
	"hub/chat_turn_watch.go:assistantStatus": "the chat_answer push reads one turn row's status, no text",
	"hub/chat_turn_watch.go:desktopLeases":   "the chat_answer push: lease ids of main chats, no text",
	"hub/chat_turn_watch.go:pendingActions":  "the chat_answer push: pending action ids of main chats, no text",
	// The tower's ideas.delete (plan Task 9): IdeaQueries.delete's Go twin.
	"db/screen_writes.go:DeleteIdeaTx": "deletes a deleted idea's Discuss chat by id; reads no text",
	"inboxfeed/screens.go:tablesIdeas": "the ideas commands' ChangeTables, table names only",
	// internal/chatstore: the hub's chat turn store, the Swift write path's
	// twin. It writes the chat rows and reads its own tree for the next turn;
	// stepStarted and markIfUsedTx write the mark itself (LIVE-01 mechanism).
	"chatstore/store.go:readConversationTx": "the turn store reads its own conversation row (routing, leaf, title)",
	"chatstore/store.go:loadMessagesTx":     "the turn store's own branch walk for the next turn",
	"chatstore/store.go:insertMessageTx":    "writes a turn's message rows",
	"chatstore/store.go:setPrefixTitleTx":   "writes the prefix title",
	"chatstore/store.go:writeRoutingTx":     "routing columns only",
	"chatstore/store.go:selectBranchTx":     "moves the active leaf",
	"chatstore/store.go:markReadTx":         "read_at from a created_at, no text",
	"chatstore/turn.go:recordActual":        "routing columns of the turn's own rows",
	"chatstore/turn.go:recordSession":       "session id only",
	"chatstore/turn.go:requireMessageTx":    "existence probe of the turn's own row",
	"chatstore/turn.go:updateAssistantTx":   "writes the turn's assistant row",
	"chatstore/turn.go:setModelTx":          "writes the turn's model",
	"chatstore/turn.go:stepStarted":         "writes a step and the LIVE-01 mark",
	"chatstore/turn.go:markIfUsedTx":        "writes the LIVE-01 mark",
	"chatstore/turn.go:titleIfNeeded":       "a count of complete answers, no text",
	// internal/chatstore/embedded.go: an embedded chat's own `ai query
	// --persist` turn (the DatabaseEmbeddedChatStore twin). It writes that
	// turn's rows and reads no chat text; embedded chats never carry Slack
	// connectors (main surface only).
	"chatstore/embedded.go:BeginEmbedded": "an existence probe of the conversation, then inserts the turn's owner row and empty reply",
	"chatstore/embedded.go:Apply":         "writes the turn's own reply text and steps",
	"chatstore/embedded.go:saveActual":    "routing columns of the turn's own reply",
	"chatstore/embedded.go:Finalize":      "writes the turn's own reply (text, status, tokens) and the conversation's updated_at",
	// The phone's chat actions (iPhone chat §4.5): conversation rows the
	// Mac's Chats panel writes too, and the attachment intake's row.
	"chatstore/conversations.go:newConversationTx":  "inserts an empty conversation row",
	"chatstore/conversations.go:ConversationExists": "an existence count, no text",
	"chatstore/conversations.go:pinTx":              "the pinned flag",
	"chatstore/conversations.go:renameTx":           "writes the owner's title",
	"chatstore/conversations.go:deleteTx":           "delete only",
	// The chat.* tower commands (mobile-inbox spec §8): the Desktop's
	// conversation-level writes, ported from its GRDB writers. They write
	// rows and read ids, flags and counts, never text into a store.
	"chatstore/commands.go:tConversations":                "table names of a command's ChangeTables, no read",
	"chatstore/commands.go:tProjects":                     "table names of a command's ChangeTables, no read",
	"chatstore/commands.go:tSources":                      "table names of a command's ChangeTables, no read",
	"chatstore/commands.go:tLeases":                       "table names of a command's ChangeTables, no read",
	"chatstore/commands.go:RegisterCommands":              "registration and short writes: archive, ChangeTables names",
	"chatstore/commands.go:requireEmbeddedTx":             "reads a conversation's context_type by id (embedded or not), no text",
	"chatstore/commands.go:chatMessageAppend":             "inserts an embedded chat's notice row; reads no chat text",
	"chatstore/commands.go:chatReplyFinish":               "writes an embedded chat's reply end and updated_at; reads no chat text",
	"chatstore/commands.go:registerProjectCommands":       "ChangeTables names of the project commands",
	"chatstore/commands.go:chatNew":                       "finds a context's chat id and inserts a conversation row",
	"chatstore/commands.go:insertContextChatTx":           "inserts an empty conversation row",
	"chatstore/commands.go:chatSetTitle":                  "writes an automatic title",
	"chatstore/commands.go:chatDeleteUntouched":           "deletes an untouched draft (existence checks only)",
	"chatstore/commands.go:chatSetProject":                "the project column and the session id",
	"chatstore/commands.go:chatSetRouting":                "routing columns only",
	"chatstore/commands.go:chatSetModel":                  "provider and model columns only",
	"chatstore/commands.go:chatContext":                   "moves a draft chat to its context (existence checks only)",
	"chatstore/commands.go:chatDeleteEmptyCodeQuestions":  "deletes empty code questions",
	"chatstore/commands.go:emptyCodeQuestionsTx":          "ids of code questions with no message, no text",
	"chatstore/commands.go:chatAttach":                    "inserts an attachment row of an existing conversation, no text read",
	"db/chat_artifact_keep.go:KeepChatArtifactTx":         "reads the LIVE-01 mark itself to refuse a keep; no text",
	"db/chat_projects.go:DropChatProjectSessionsTx":       "clears session ids, no text",
	"db/meeting_transcripts.go:DeleteMeetingTranscriptTx": "deletes a recording's meeting chat (meetings.delete), no text read",
	"chatstore/attachments.go:SaveAttachment":             "inserts an attachment row of an existing conversation, no text read",
	// The phone's chat (iPhone chat spec §4.6): the hub's chat slices and the
	// Go port of the Mac's ⌘K search show chat text on the phone and store
	// nothing (the slices live in memory and the sealed relay records only).
	"db/chat_search.go:chatTitleMatches":                     "the ⌘K search port: title hits shown on the phone",
	"db/chat_search.go:chatMessageMatches":                   "the ⌘K search port: message hits shown on the phone",
	"hub/slices/sources/chat_list.go:chatListRows":           "the phone's chat list (titles, states, last lines)",
	"hub/slices/sources/chat_feed.go:chatFeedConversationTx": "the phone's chat feed: the conversation's meta",
	"hub/slices/sources/chat_feed.go:chatBranchTx":           "the phone's chat feed: the active branch's ids",
	"hub/slices/sources/chat_feed.go:chatFeedMessageRowsTx":  "the phone's chat feed: the messages shown",
	"hub/slices/sources/chat_feed.go:chatFeedActionsTx":      "the phone's chat feed: the actions of the turns shown",
	"hub/slices/sources/chat_feed.go:buildChatPage":          "the phone's chat page: older messages shown",
	"hub/slices/sources/registry.go:ChangeTables":            "table names of the hub's data_version watch, no read",
}

// TestLIVE01_ReaderList fails when a non-test function in internal/ mentions
// chat_messages or chat_conversations without being on one of the lists, or
// when a displayOnlyReadersAt key names no such function.
func TestLIVE01_ReaderList(t *testing.T) {
	root := filepath.Join("..", "..", "internal")
	re := regexp.MustCompile(`chat_messages|chat_conversations`)
	var unknown []string
	seenAt := map[string]bool{}
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
			if !re.MatchString(body) || liveCheckedReaders[name] {
				return
			}
			rel, err := filepath.Rel(root, p)
			require.NoError(t, err)
			key := filepath.ToSlash(rel) + ":" + name
			if _, ok := displayOnlyReadersAt[key]; ok {
				seenAt[key] = true
				return
			}
			if _, ok := displayOnlyReaders[name]; !ok {
				unknown = append(unknown, key)
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
	for key := range displayOnlyReadersAt {
		assert.True(t, seenAt[key], "%s: no such function reads the chat tables any more; remove the stale key (LIVE-01)", key)
	}
}

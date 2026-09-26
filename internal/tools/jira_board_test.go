package tools

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// fakeBoardClient returns a fixed board list (or a fetch error) — the seam a
// test uses to stand in for a live *jira.Client.
type fakeBoardClient struct {
	boards   []jira.Board
	fetchErr error
}

func (f *fakeBoardClient) FetchAllBoards(context.Context) ([]jira.Board, error) {
	return f.boards, f.fetchErr
}

// fakeProfiler records the boards it was asked to analyze and can fail on
// demand — the best-effort profiler seam.
type fakeProfiler struct {
	analyzed []db.JiraBoard
	err      error
}

func (f *fakeProfiler) AnalyzeBoard(_ context.Context, b db.JiraBoard) (*jira.BoardProfile, error) {
	f.analyzed = append(f.analyzed, b)
	if f.err != nil {
		return nil, f.err
	}
	return &jira.BoardProfile{}, nil
}

func boardFixture(id int, projectKey, name string) jira.Board {
	var b jira.Board
	b.ID = id
	b.Name = name
	b.Type = "scrum"
	b.Location.ProjectKey = projectKey
	return b
}

func connectFactory(client JiraBoardClient) JiraConnectFactory {
	return func(db.JiraAccount) (JiraConnect, error) { return JiraConnect{Client: client}, nil }
}

func TestConnectJiraBoard_Registration(t *testing.T) {
	tool := NewConnectJiraBoard(nil)
	assert.Equal(t, "connect_jira_board", tool.Name)
	assert.True(t, tool.External)
	assert.Equal(t, AccessWrite, tool.Access)
	assert.Equal(t, []string{"main"}, tool.Surfaces)
}

func TestConnectJiraBoard_ValidateRequiresProjectKeyAndAccount(t *testing.T) {
	database := openDB(t)
	tool := NewConnectJiraBoard(connectFactory(&fakeBoardClient{}))
	ctx := context.Background()
	var verr *ValidationError

	// No Jira site connected yet.
	err := tool.Validate(ctx, database, json.RawMessage(`{"project_key":"ABC","reason":"r"}`))
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "no Jira site")

	seedJira(t, database)
	// project_key missing.
	assert.ErrorAs(t, tool.Validate(ctx, database, json.RawMessage(`{"reason":"r"}`)), &verr)
	// Unknown field is rejected (decodeStrict).
	assert.ErrorAs(t, tool.Validate(ctx, database, json.RawMessage(`{"project_key":"ABC","reason":"r","foo":1}`)), &verr)
	// A project that is NOT synced still validates — connect exists precisely to
	// start watching an un-synced project (unlike create_jira_issue).
	assert.NoError(t, tool.Validate(ctx, database, json.RawMessage(`{"project_key":"NEWPROJ","reason":"r"}`)))
}

// The proposal flow: propose records a pending row and selects nothing; the
// board is selected only after the owner approves and Apply runs.
func TestConnectJiraBoard_ProposeThenApplySelectsBoard(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	fc := &fakeBoardClient{boards: []jira.Board{
		boardFixture(10, "ABC", "ABC board"), boardFixture(11, "XYZ", "XYZ board"),
	}}
	reg := New(database)
	require.NoError(t, reg.Register(NewConnectJiraBoard(func(a db.JiraAccount) (JiraConnect, error) {
		assert.Equal(t, accountID, a.ID)
		return JiraConnect{Client: fc}, nil
	})))

	rc, err := reg.Propose(context.Background(), "connect_jira_board",
		json.RawMessage(`{"project_key":"ABC","reason":"watch ABC"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)

	// Nothing is selected on propose.
	sel, err := database.GetJiraSelectedBoards(accountID)
	require.NoError(t, err)
	assert.Empty(t, sel)

	// The owner approves, then Apply runs the tool exactly once.
	ok, err := database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)
	applied, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", applied.Status)

	sel, err = database.GetJiraSelectedBoards(accountID)
	require.NoError(t, err)
	require.Len(t, sel, 1)
	assert.Equal(t, 10, sel[0].ID)
	assert.Equal(t, "ABC", sel[0].ProjectKey)
}

// account_id is required when several sites are connected, and an explicit id
// reaches the right account's client.
func TestConnectJiraBoard_ResolvesExplicitAccount(t *testing.T) {
	database := openDB(t)
	seedJira(t, database)
	second, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://two.atlassian.net"})
	require.NoError(t, err)

	// Two enabled accounts and no account_id → ambiguous at Validate.
	tool := NewConnectJiraBoard(connectFactory(&fakeBoardClient{}))
	var verr *ValidationError
	require.ErrorAs(t, tool.Validate(context.Background(), database,
		json.RawMessage(`{"project_key":"ABC","reason":"r"}`)), &verr)

	// An explicit account_id resolves and the factory sees that account.
	var gotAccount int64
	tool = NewConnectJiraBoard(func(a db.JiraAccount) (JiraConnect, error) {
		gotAccount = a.ID
		return JiraConnect{Client: &fakeBoardClient{boards: []jira.Board{boardFixture(5, "ABC", "b")}}}, nil
	})
	out, err := tool.Execute(context.Background(), database, Call{Args: json.RawMessage(
		`{"account_id":` + strconv.FormatInt(second, 10) + `,"project_key":"ABC","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, second, gotAccount)
	assert.Equal(t, 5, out.(map[string]any)["board_id"])

	sel, _ := database.GetJiraSelectedBoards(second)
	require.Len(t, sel, 1)
	assert.Equal(t, 5, sel[0].ID)
}

// The board is matched against the LIVE list fetched at Apply time, so a
// project that returns no matching board is a clear miss — not a select of
// nothing.
func TestConnectJiraBoard_BoardNotFoundAfterRefresh(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	tool := NewConnectJiraBoard(connectFactory(&fakeBoardClient{
		boards: []jira.Board{boardFixture(1, "OTHER", "Other board")},
	}))
	_, err := tool.Execute(context.Background(), database,
		Call{Args: json.RawMessage(`{"project_key":"ABC","reason":"r"}`)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "ABC")

	// Nothing was selected on the miss.
	sel, _ := database.GetJiraSelectedBoards(accountID)
	assert.Empty(t, sel)
}

// A project with several boards is ambiguous without board_name, and board_name
// disambiguates it.
func TestConnectJiraBoard_AmbiguousProjectNeedsBoardName(t *testing.T) {
	database := openDB(t)
	seedJira(t, database)
	boards := []jira.Board{boardFixture(1, "ABC", "ABC Scrum"), boardFixture(2, "ABC", "ABC Kanban")}
	tool := NewConnectJiraBoard(connectFactory(&fakeBoardClient{boards: boards}))

	_, err := tool.Execute(context.Background(), database,
		Call{Args: json.RawMessage(`{"project_key":"ABC","reason":"r"}`)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "ABC Kanban")

	out, err := tool.Execute(context.Background(), database,
		Call{Args: json.RawMessage(`{"project_key":"ABC","board_name":"ABC Kanban","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, 2, out.(map[string]any)["board_id"])
}

// External (AGENT-03): connect_jira_board can never be granted execute trust.
func TestConnectJiraBoard_ExternalCannotBeExecuteTrust(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	require.NoError(t, reg.Register(NewConnectJiraBoard(connectFactory(&fakeBoardClient{}))))

	err := reg.SetTrust("connect_jira_board", TrustExecute)
	assert.ErrorIs(t, err, ErrExternalExecute)
	trust, _ := reg.Trust("connect_jira_board")
	assert.Equal(t, TrustAsk, trust)
}

// Profiling is best-effort: a profiler failure warns on an otherwise successful
// connect, and the board stays selected.
func TestConnectJiraBoard_ProfilerFailureWarnsButConnects(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	prof := &fakeProfiler{err: errors.New("llm down")}
	tool := NewConnectJiraBoard(func(db.JiraAccount) (JiraConnect, error) {
		return JiraConnect{
			Client:   &fakeBoardClient{boards: []jira.Board{boardFixture(9, "ABC", "b")}},
			Profiler: prof,
		}, nil
	})
	out, err := tool.Execute(context.Background(), database,
		Call{Args: json.RawMessage(`{"project_key":"ABC","reason":"r"}`)})
	require.NoError(t, err)
	res := out.(map[string]any)
	assert.Equal(t, 9, res["board_id"])
	assert.Contains(t, res["warning"], "profile was not generated")

	sel, _ := database.GetJiraSelectedBoards(accountID)
	require.Len(t, sel, 1)
	require.Len(t, prof.analyzed, 1, "the board was handed to the profiler")
}

// A revoked grant on the board fetch is recorded on the account, like
// create_jira_issue does on its create call.
func TestConnectJiraBoard_AuthRevokedMarksAccount(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	tool := NewConnectJiraBoard(connectFactory(&fakeBoardClient{fetchErr: jira.ErrAuthRevoked}))
	_, err := tool.Execute(context.Background(), database,
		Call{Args: json.RawMessage(`{"project_key":"ABC","reason":"r"}`)})
	assert.True(t, errors.Is(err, jira.ErrAuthRevoked))
	acct, _ := database.GetJiraAccount(accountID)
	assert.Equal(t, "revoked", acct.Status)
}

// The happy path: a profiler that succeeds adds no warning and is handed the
// board exactly once.
func TestConnectJiraBoard_ProfilerSuccessAddsNoWarning(t *testing.T) {
	database := openDB(t)
	seedJira(t, database)
	prof := &fakeProfiler{}
	tool := NewConnectJiraBoard(func(db.JiraAccount) (JiraConnect, error) {
		return JiraConnect{
			Client:   &fakeBoardClient{boards: []jira.Board{boardFixture(7, "ABC", "b")}},
			Profiler: prof,
		}, nil
	})
	out, err := tool.Execute(context.Background(), database,
		Call{Args: json.RawMessage(`{"project_key":"ABC","reason":"r"}`)})
	require.NoError(t, err)
	res := out.(map[string]any)
	assert.Equal(t, 7, res["board_id"])
	_, hasWarning := res["warning"]
	assert.False(t, hasWarning, "a successful profile adds no warning")
	require.Len(t, prof.analyzed, 1)
}

// A revoked grant surfacing through the profiler (not the fetch) is recorded on
// the account too — the connect still stands, but the owner must not be left
// with an account that reads OK and a phantom "profile failed" message.
func TestConnectJiraBoard_ProfilerAuthRevokedMarksAccount(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	prof := &fakeProfiler{err: jira.ErrAuthRevoked}
	tool := NewConnectJiraBoard(func(db.JiraAccount) (JiraConnect, error) {
		return JiraConnect{
			Client:   &fakeBoardClient{boards: []jira.Board{boardFixture(8, "ABC", "b")}},
			Profiler: prof,
		}, nil
	})
	out, err := tool.Execute(context.Background(), database,
		Call{Args: json.RawMessage(`{"project_key":"ABC","reason":"r"}`)})
	require.NoError(t, err, "the connect still succeeds — the board is selected")
	assert.Contains(t, out.(map[string]any)["warning"], "profile was not generated")
	acct, _ := database.GetJiraAccount(accountID)
	assert.Equal(t, "revoked", acct.Status)

	sel, _ := database.GetJiraSelectedBoards(accountID)
	require.Len(t, sel, 1)
}

// Reconnecting an already-profiled board hands the profiler the PERSISTED row
// (config hash + profile), not a freshly-built struct — this is what lets
// AnalyzeBoard's cache skip a fresh paid analysis. Also pins reconnect
// idempotency: still exactly one selected board.
func TestConnectJiraBoard_ReconnectPassesPersistedRowToProfiler(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: accountID, ID: 10, Name: "ABC board", ProjectKey: "ABC",
		BoardType: "scrum", SyncedAt: "2026-09-01T00:00:00Z",
	}))
	require.NoError(t, database.UpdateJiraBoardProfile(accountID, 10,
		"[]", "{}", `{"summary":"x"}`, "does things", "hash-123", "2026-09-01T00:00:00Z"))

	prof := &fakeProfiler{}
	tool := NewConnectJiraBoard(func(db.JiraAccount) (JiraConnect, error) {
		return JiraConnect{
			Client:   &fakeBoardClient{boards: []jira.Board{boardFixture(10, "ABC", "ABC board")}},
			Profiler: prof,
		}, nil
	})
	_, err := tool.Execute(context.Background(), database,
		Call{Args: json.RawMessage(`{"project_key":"ABC","reason":"r"}`)})
	require.NoError(t, err)

	require.Len(t, prof.analyzed, 1)
	assert.Equal(t, "hash-123", prof.analyzed[0].ConfigHash, "the profiler got the persisted row, not an empty struct")
	assert.NotEmpty(t, prof.analyzed[0].LLMProfileJSON)

	sel, _ := database.GetJiraSelectedBoards(accountID)
	require.Len(t, sel, 1)
	assert.Equal(t, 10, sel[0].ID)
}

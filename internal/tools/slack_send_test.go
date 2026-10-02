package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/slack"
)

type fakeSlackSender struct {
	posts      []SlackPosted // what PostMessage sent (User = channel, TS = thread)
	opened     []string
	recent     []SlackPosted
	recentMore bool
	recentErr  error
	postErr    error
	recentArgs []string
}

func (f *fakeSlackSender) PostMessage(_ context.Context, channelID, text, threadTS string) (string, error) {
	if f.postErr != nil {
		return "", f.postErr
	}
	f.posts = append(f.posts, SlackPosted{User: channelID, Text: text, TS: threadTS})
	return "1800000000.000100", nil
}

func (f *fakeSlackSender) OpenDM(_ context.Context, userID string) (string, error) {
	f.opened = append(f.opened, userID)
	return "DOPENED", nil
}

func (f *fakeSlackSender) RecentMessages(_ context.Context, channelID, threadTS, oldest string) ([]SlackPosted, bool, error) {
	f.recentArgs = []string{channelID, threadTS, oldest}
	return f.recent, f.recentMore, f.recentErr
}

// slackSendEnv is a registry with send_slack_message over a DB holding two
// workspaces: acme (#general, #ops, Alice, a DM with Alice) and beta
// (#general, two people called Sam).
type slackSendEnv struct {
	d      *db.DB
	reg    *Registry
	sender *fakeSlackSender
	scope  string
	acme   int64
	beta   int64
}

func newSlackSendEnv(t *testing.T) *slackSendEnv {
	t.Helper()
	d := openDB(t)
	env := &slackSendEnv{d: d, sender: &fakeSlackSender{}, scope: "channels:read,chat:write"}
	var err error
	env.acme, err = d.CreateSlackAccount(db.SlackAccount{TeamName: "Acme", TeamDomain: "acme", Label: "Acme"})
	require.NoError(t, err)
	env.beta, err = d.CreateSlackAccount(db.SlackAccount{TeamName: "Beta", TeamDomain: "beta"})
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE slack_accounts SET current_user_id = ? WHERE id = ?`, slack.Namespace(env.acme, "UOWNER"), env.acme)
	require.NoError(t, err)

	ch := func(acct int64, id, name, typ, dmUser string) {
		require.NoError(t, d.UpsertChannel(db.Channel{ID: slack.Namespace(acct, id), Name: name, Type: typ,
			DMUserID: sql.NullString{String: dmUser, Valid: dmUser != ""}}))
	}
	ch(env.acme, "CGEN", "general", "public", "")
	ch(env.acme, "COPS", "ops", "private", "")
	ch(env.acme, "DALICE", "", "dm", slack.Namespace(env.acme, "UALICE"))
	ch(env.beta, "CBGEN", "general", "public", "")
	require.NoError(t, d.UpsertChannel(db.Channel{ID: slack.Namespace(env.acme, "COLD"), Name: "old", Type: "public", IsArchived: true}))
	user := func(acct int64, id, name, display, email string) {
		require.NoError(t, d.UpsertUser(db.User{ID: slack.Namespace(acct, id), Name: name, DisplayName: display, Email: email}))
	}
	user(env.acme, "UALICE", "alice", "Alice", "alice@example.com")
	user(env.acme, "UBOB", "bob", "Bob", "")
	user(env.beta, "USAM1", "sam", "Sam", "")
	user(env.beta, "USAM2", "sam.k", "Sam", "")
	require.NoError(t, d.UpsertUser(db.User{ID: slack.Namespace(env.acme, "UGONE"), Name: "gone", DisplayName: "Gone", IsDeleted: true}))
	require.NoError(t, d.UpsertUser(db.User{ID: slack.Namespace(env.acme, "UBOT"), Name: "deploybot", DisplayName: "Deploy", IsBot: true}))

	env.reg = New(d)
	require.NoError(t, env.reg.Register(NewSendSlackMessage(func(a db.SlackAccount) (SlackSender, string, error) {
		return env.sender, env.scope, nil
	})))
	return env
}

func (e *slackSendEnv) propose(t *testing.T, args string) (Receipt, error) {
	t.Helper()
	return e.reg.Propose(context.Background(), "send_slack_message", json.RawMessage(args), Binding{Surface: "main"})
}

func (e *slackSendEnv) stored(t *testing.T, id int64) storedSlackSend {
	t.Helper()
	row, err := e.d.GetAgentAction(id)
	require.NoError(t, err)
	s, err := decodeStoredSlackSend(json.RawMessage(row.ArgsJSON))
	require.NoError(t, err)
	return s
}

func TestSendSlackMessage_ResolvesAndPinsTheRecipient(t *testing.T) {
	cases := []struct {
		name string
		args string
		want slackRecipient
	}{
		{"private channel by name", `{"channel":"#ops"}`,
			slackRecipient{ChannelID: "COPS", Label: "#ops"}},
		{"channel by raw id", `{"channel":"COPS"}`,
			slackRecipient{ChannelID: "COPS", Label: "#ops"}},
		{"name in one workspace via account_id", `{"channel":"general","account_id":1}`,
			slackRecipient{ChannelID: "CGEN", Label: "#general"}},
		{"namespaced id picks its workspace", `{"channel":"1:CGEN"}`,
			slackRecipient{ChannelID: "CGEN", Label: "#general"}},
		{"message link replies in its thread", `{"channel":"https://acme.slack.com/archives/CGEN/p1700000000123456"}`,
			slackRecipient{ChannelID: "CGEN", Label: "#general", ThreadTS: "1700000000.123456"}},
		{"reply link answers in the parent thread", `{"channel":"https://acme.slack.com/archives/CGEN/p1700000099000001?thread_ts=1700000000.123456&cid=CGEN"}`,
			slackRecipient{ChannelID: "CGEN", Label: "#general", ThreadTS: "1700000000.123456"}},
		{"explicit thread_ts", `{"channel":"#ops","thread_ts":"1700000000.000001"}`,
			slackRecipient{ChannelID: "COPS", Label: "#ops", ThreadTS: "1700000000.000001"}},
		{"DM by email uses the synced IM", `{"user":"Alice@Example.com"}`,
			slackRecipient{ChannelID: "DALICE", UserID: "UALICE", Label: "@Alice"}},
		{"DM by handle without an IM opens one later", `{"user":"@bob"}`,
			slackRecipient{UserID: "UBOB", Label: "@Bob"}},
		{"DM by its channel id names the person", `{"channel":"DALICE"}`,
			slackRecipient{ChannelID: "DALICE", UserID: "UALICE", Label: "@Alice"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := newSlackSendEnv(t)
			var args map[string]any
			require.NoError(t, json.Unmarshal([]byte(tc.args), &args))
			args["text"], args["reason"] = "hi", "asked to"
			raw, _ := json.Marshal(args)
			rc, err := env.propose(t, string(raw))
			require.NoError(t, err)
			assert.Equal(t, "pending", rc.Status)
			s := env.stored(t, rc.ActionID)
			require.NotNil(t, s.Target)
			want := tc.want
			want.AccountID, want.Workspace = env.acme, "Acme"
			assert.Equal(t, want, *s.Target)
			assert.Empty(t, s.Candidates)
			assert.Empty(t, env.sender.posts, "nothing is sent on propose (AGENT-01)")
		})
	}
}

func TestSendSlackMessage_RefusesWhatItCannotResolve(t *testing.T) {
	cases := []struct{ name, args, msg string }{
		{"unknown channel", `{"channel":"#nope"}`, "no channel #nope"},
		{"unknown person", `{"user":"carol"}`, "no person carol"},
		{"both channel and user", `{"channel":"#ops","user":"alice"}`, "exactly one of channel or user"},
		{"neither", `{}`, "exactly one of channel or user"},
		{"two people in one workspace", `{"user":"Sam"}`, "matches several in Beta"},
		{"thread on a DM", `{"user":"alice","thread_ts":"1700000000.000001"}`, "thread_ts needs a channel"},
		{"bad thread_ts", `{"channel":"#ops","thread_ts":"yesterday"}`, "thread_ts must look like"},
		{"thread_ts disagrees with the link", `{"channel":"https://acme.slack.com/archives/CGEN/p1700000000123456","thread_ts":"1700000000.000001"}`, "differs from the thread"},
		{"unknown account", `{"channel":"#ops","account_id":99}`, "Slack account #99 is not connected"},
		{"archived link host of another workspace", `{"channel":"https://beta.slack.com/archives/COPS"}`, "no channel"},
		{"archived channel", `{"channel":"#old"}`, "no channel #old"},
		{"deleted person", `{"user":"gone"}`, "no person gone"},
		{"bot", `{"user":"deploybot"}`, "no person deploybot"},
		{"model-supplied target", `{"channel":"#ops","target":{"account_id":2,"channel_id":"CEVIL","label":"#ops"}}`, "additional properties"},
		{"model-supplied candidates", `{"channel":"#ops","candidates":[]}`, "additional properties"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := newSlackSendEnv(t)
			var args map[string]any
			require.NoError(t, json.Unmarshal([]byte(tc.args), &args))
			args["text"], args["reason"] = "hi", "asked to"
			raw, _ := json.Marshal(args)
			_, err := env.propose(t, string(raw))
			var verr *ValidationError
			require.ErrorAs(t, err, &verr)
			assert.Contains(t, verr.Msg, tc.msg)
			rows, err := env.d.ListAgentActions(db.AgentActionFilter{})
			require.NoError(t, err)
			assert.Empty(t, rows, "a refused call writes no row")
		})
	}
}

func TestSendSlackMessage_TextLimits(t *testing.T) {
	env := newSlackSendEnv(t)
	_, err := env.propose(t, `{"channel":"#ops","text":"   ","reason":"r"}`)
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	long, _ := json.Marshal(strings.Repeat("я", slackSendMaxRunes+1))
	_, err = env.propose(t, `{"channel":"#ops","text":`+string(long)+`,"reason":"r"}`)
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "at most")
}

// The same channel name in two workspaces: one proposal with both pinned as
// candidates; it cannot be approved or executed until the owner picks one.
func TestSendSlackMessage_CrossWorkspaceAmbiguityNeedsAPick(t *testing.T) {
	env := newSlackSendEnv(t)
	rc, err := env.propose(t, `{"channel":"#general","text":"hello","reason":"r"}`)
	require.NoError(t, err)
	s := env.stored(t, rc.ActionID)
	assert.Nil(t, s.Target)
	require.Len(t, s.Candidates, 2)
	assert.Equal(t, env.acme, s.Candidates[0].AccountID)
	assert.Equal(t, env.beta, s.Candidates[1].AccountID)
	assert.Equal(t, "Beta", s.Candidates[1].Workspace)

	ctx := context.Background()
	_, err = env.reg.Approve(ctx, rc.ActionID, nil)
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "choose the workspace")

	_, err = env.reg.Approve(ctx, rc.ActionID, json.RawMessage(`{"candidate":2}`))
	require.ErrorAs(t, err, &verr)

	ok, err := env.reg.Approve(ctx, rc.ActionID, json.RawMessage(`{"candidate":1,"text":"hello, edited"}`))
	require.NoError(t, err)
	require.True(t, ok)
	row, err := env.reg.Apply(ctx, rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status, row.Error)
	require.Len(t, env.sender.posts, 1)
	assert.Equal(t, SlackPosted{User: "CBGEN", Text: "hello, edited"}, env.sender.posts[0])
}

func TestSendSlackMessage_ReviseRefusesAnythingButTextAndPick(t *testing.T) {
	env := newSlackSendEnv(t)
	rc, err := env.propose(t, `{"channel":"#ops","text":"hello","reason":"r"}`)
	require.NoError(t, err)
	ctx := context.Background()
	for _, patch := range []string{`{"channel":"#general"}`, `{"candidate":0}`, `{"text":""}`, `[1]`} {
		_, err := env.reg.Approve(ctx, rc.ActionID, json.RawMessage(patch))
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, patch)
	}
	assert.Equal(t, "pending", mustRow(t, env.d, rc.ActionID).Status)
}

func mustRow(t *testing.T, d *db.DB, id int64) *db.AgentAction {
	t.Helper()
	row, err := d.GetAgentAction(id)
	require.NoError(t, err)
	require.NotNil(t, row)
	return row
}

func approveAndApply(t *testing.T, env *slackSendEnv, id int64) *db.AgentAction {
	t.Helper()
	ok, err := env.reg.Approve(context.Background(), id, nil)
	require.NoError(t, err)
	require.True(t, ok)
	row, err := env.reg.Apply(context.Background(), id)
	require.NoError(t, err)
	return row
}

func TestSendSlackMessage_ExecutePostsIntoTheThreadAndLinksIt(t *testing.T) {
	env := newSlackSendEnv(t)
	rc, err := env.propose(t, `{"channel":"https://acme.slack.com/archives/CGEN/p1700000000123456","text":"on it, <@1:UALICE> &co","reason":"r"}`)
	require.NoError(t, err)
	row := approveAndApply(t, env, rc.ActionID)
	assert.Equal(t, "applied", row.Status, row.Error)
	require.Len(t, env.sender.posts, 1)
	assert.Equal(t, SlackPosted{User: "CGEN", Text: "on it, <@UALICE> &co", TS: "1700000000.123456"}, env.sender.posts[0],
		"the pinned account's namespaced mention is sent raw")
	var result map[string]any
	require.NoError(t, json.Unmarshal([]byte(row.ResultJSON), &result))
	assert.Equal(t, "https://acme.slack.com/archives/CGEN/p1800000000000100", result["url"])
	assert.Equal(t, "Message to #general", result["label"])
	assert.Nil(t, result["reused"])
}

func TestSendSlackMessage_DMWithoutAnIMOpensOne(t *testing.T) {
	env := newSlackSendEnv(t)
	rc, err := env.propose(t, `{"user":"bob","text":"hi Bob","reason":"r"}`)
	require.NoError(t, err)
	row := approveAndApply(t, env, rc.ActionID)
	assert.Equal(t, "applied", row.Status, row.Error)
	assert.Equal(t, []string{"UBOB"}, env.sender.opened)
	assert.Equal(t, "DOPENED", env.sender.posts[0].User)
}

func TestSendSlackMessage_ForeignMentionIsRefusedAtExecute(t *testing.T) {
	env := newSlackSendEnv(t)
	rc, err := env.propose(t, `{"channel":"#ops","text":"cc <@2:USAM1>","reason":"r"}`)
	require.NoError(t, err)
	row := approveAndApply(t, env, rc.ActionID)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "another Slack workspace")
	assert.Empty(t, env.sender.posts)
}

// A token whose recorded grant lacks chat:write fails without a network
// call; a legacy token (no recorded grant) is tried and Slack's missing_scope
// becomes the same error. Both carry the phrase the Desktop matches.
func TestSendSlackMessage_MissingScopeAsksToSignInAgain(t *testing.T) {
	env := newSlackSendEnv(t)
	env.scope = "channels:read"
	rc, err := env.propose(t, `{"channel":"#ops","text":"hi","reason":"r"}`)
	require.NoError(t, err)
	row := approveAndApply(t, env, rc.ActionID)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, SlackSendScopeHint)
	assert.Contains(t, row.Error, "Acme")
	assert.Empty(t, env.sender.posts)

	env2 := newSlackSendEnv(t)
	env2.scope = ""
	env2.sender.postErr = errors.New("missing_scope")
	rc, err = env2.propose(t, `{"channel":"#ops","text":"hi","reason":"r"}`)
	require.NoError(t, err)
	row = approveAndApply(t, env2, rc.ActionID)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, SlackSendScopeHint)
}

func TestSendSlackMessage_DisabledAccountIsNotSentFrom(t *testing.T) {
	env := newSlackSendEnv(t)
	rc, err := env.propose(t, `{"channel":"#ops","text":"hi","reason":"r"}`)
	require.NoError(t, err)
	require.NoError(t, env.d.SetSlackAccountEnabled(env.acme, false))
	row := approveAndApply(t, env, rc.ActionID)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "disabled or removed")
	assert.Empty(t, env.sender.posts)
}

// failOnce lands a row in `failed` the way a timed-out post would.
func failOnce(t *testing.T, env *slackSendEnv, args string) int64 {
	t.Helper()
	env.sender.postErr = errors.New("context deadline exceeded")
	rc, err := env.propose(t, args)
	require.NoError(t, err)
	row := approveAndApply(t, env, rc.ActionID)
	require.Equal(t, "failed", row.Status)
	env.sender.postErr = nil
	return rc.ActionID
}

func TestSendSlackMessage_RetryFindsTheMessageTheFailedAttemptPosted(t *testing.T) {
	env := newSlackSendEnv(t)
	id := failOnce(t, env, `{"channel":"#ops","text":"ship it & go","reason":"r"}`)
	env.sender.recent = []SlackPosted{
		{User: "UALICE", Text: "ship it &amp; go", TS: "1800000000.000001"},
		{User: "UOWNER", Text: "ship it &amp; go", TS: "1800000000.000002"},
	}
	applied, err := env.reg.Apply(context.Background(), id)
	require.NoError(t, err)
	assert.Equal(t, "applied", applied.Status, applied.Error)
	assert.Empty(t, env.sender.posts, "the landed message is not posted twice")
	row := mustRow(t, env.d, id)
	proposed, perr := time.Parse(time.RFC3339, row.CreatedAt)
	require.NoError(t, perr)
	assert.Equal(t, []string{"COPS", "", strconv.FormatInt(proposed.Add(-time.Minute).Unix(), 10) + ".000000"}, env.sender.recentArgs,
		"the lookup reads the channel from a minute before the proposal")
	var result map[string]any
	require.NoError(t, json.Unmarshal([]byte(applied.ResultJSON), &result))
	assert.Equal(t, true, result["reused"])
	assert.Equal(t, "1800000000.000002", result["ts"])
}

func TestSendSlackMessage_RetryPostsWhenNothingLanded(t *testing.T) {
	env := newSlackSendEnv(t)
	id := failOnce(t, env, `{"channel":"#ops","text":"ship it","reason":"r"}`)
	env.sender.recent = []SlackPosted{{User: "UOWNER", Text: "something else", TS: "1800000000.000002"}}
	row, err := env.reg.Apply(context.Background(), id)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status, row.Error)
	require.Len(t, env.sender.posts, 1)
}

func TestSendSlackMessage_RetryThatCannotTellDoesNotRepost(t *testing.T) {
	for name, setup := range map[string]func(*fakeSlackSender){
		"lookup fails":  func(f *fakeSlackSender) { f.recentErr = errors.New("ratelimited") },
		"page overflow": func(f *fakeSlackSender) { f.recentMore = true },
	} {
		t.Run(name, func(t *testing.T) {
			env := newSlackSendEnv(t)
			id := failOnce(t, env, `{"channel":"#ops","text":"ship it","reason":"r"}`)
			setup(env.sender)
			row, err := env.reg.Apply(context.Background(), id)
			require.NoError(t, err)
			assert.Equal(t, "failed", row.Status)
			assert.Contains(t, row.Error, "whether the failed attempt posted")
			assert.Empty(t, env.sender.posts, "a retry never re-posts on a guess")
		})
	}
}

// AGENT-03: the send leaves the machine, so it can never be trusted to run
// without the owner's click.
func TestSendSlackMessage_ExternalCannotBeExecuteTrust(t *testing.T) {
	env := newSlackSendEnv(t)
	assert.ErrorIs(t, env.reg.SetTrust("send_slack_message", TrustExecute), ErrExternalExecute)
	require.NoError(t, env.d.SetToolTrust("send_slack_message", "execute")) // a stale row
	rc, err := env.propose(t, `{"channel":"#ops","text":"hi","reason":"r"}`)
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.Empty(t, env.sender.posts)
}

// From a project terminal the send is recorded pending for the Desktop's
// Approve, bound to the project, and never posted on propose (DEV-06).
func TestSendSlackMessage_ProjectSessionOnlyProposes(t *testing.T) {
	env := newSlackSendEnv(t)
	pid := seedProject(t, env.d, "acme")
	rc, err := env.reg.Propose(context.Background(), "send_slack_message",
		json.RawMessage(`{"channel":"#ops","text":"build is green","reason":"r"}`), directBinding(pid))
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.Empty(t, env.sender.posts)
	row := mustRow(t, env.d, rc.ActionID)
	assert.Equal(t, ProjectContextType, row.ContextType)
	assert.Equal(t, "project", row.Surface)
}

func TestGetWritingStyle(t *testing.T) {
	d := openDB(t)
	reg := New(d)
	require.NoError(t, reg.Register(NewGetWritingStyle()))
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "T1", Name: "acme", Domain: "acme"}))

	out, err := reg.CallRead(context.Background(), "get_writing_style", nil, Binding{Surface: "main"})
	require.NoError(t, err)
	m := out.(map[string]any)
	assert.Equal(t, "", m["style_profile"])
	assert.Contains(t, m["note"], "No style profile yet")

	require.NoError(t, d.SetStyleProfile("Russian with the team, terse, no emoji"))
	out, err = reg.CallRead(context.Background(), "get_writing_style", nil, Binding{Surface: "main"})
	require.NoError(t, err)
	m = out.(map[string]any)
	assert.Equal(t, "Russian with the team, terse, no emoji", m["style_profile"])
	assert.NotEmpty(t, m["updated_at"], "the model can tell how fresh the profile is")
	assert.Nil(t, m["note"])
}

func TestNormalizeSlackText_MatchesWhatSlackStores(t *testing.T) {
	for sent, stored := range map[string]string{
		"see https://example.com/a?b=1 & go": "see <https://example.com/a?b=1> &amp; go",
		"a < b > c":                          "a &lt; b &gt; c",
		"<https://example.com|the doc> now":  "<https://example.com|the doc> now",
		"mail <mailto:a@example.com|a>":      "mail <mailto:a@example.com|a>",
		"cc <@UALICE>":                       "cc <@UALICE|alice>",
		"see <#CGEN>":                        "see <#CGEN|general>",
		"<!here> deploy":                     "<!here|here> deploy",
	} {
		assert.Equal(t, normalizeSlackText(sent), normalizeSlackText(stored), sent)
	}
	assert.NotEqual(t, normalizeSlackText("ship it"), normalizeSlackText("ship it!"))
}

// A failure before chat.postMessage on every attempt so far cannot have
// posted anything: the retry skips the lookup (which could dead-end on a busy
// channel) and sends.
func TestSendSlackMessage_RetryAfterANotSentFailureSkipsTheLookup(t *testing.T) {
	for name, setup := range map[string]func(*slackSendEnv){
		"scope missing, then granted": func(e *slackSendEnv) { e.scope = "channels:read" },
		"Slack refused the post":      func(e *slackSendEnv) { e.sender.postErr = errors.New("not_in_channel") },
	} {
		t.Run(name, func(t *testing.T) {
			env := newSlackSendEnv(t)
			setup(env)
			rc, err := env.propose(t, `{"channel":"#ops","text":"hi","reason":"r"}`)
			require.NoError(t, err)
			row := approveAndApply(t, env, rc.ActionID)
			require.Equal(t, "failed", row.Status)
			assert.True(t, strings.HasPrefix(row.Error, SlackNotSentPrefix), row.Error)

			env.scope, env.sender.postErr = "chat:write", nil
			env.sender.recentMore = true // a lookup would refuse; it must not run
			row, err = env.reg.Apply(context.Background(), rc.ActionID)
			require.NoError(t, err)
			assert.Equal(t, "applied", row.Status, row.Error)
			assert.Nil(t, env.sender.recentArgs, "no lookup after an attempt that never posted")
			assert.Len(t, env.sender.posts, 1)
		})
	}
}

// A timed-out post followed by a not-sent failure still may have landed: the
// third attempt must look before posting.
func TestSendSlackMessage_MayHaveLandedSticksAcrossLaterFailures(t *testing.T) {
	env := newSlackSendEnv(t)
	id := failOnce(t, env, `{"channel":"#ops","text":"ship it","reason":"r"}`)
	env.scope = "channels:read"
	row, err := env.reg.Apply(context.Background(), id)
	require.NoError(t, err)
	require.Equal(t, "failed", row.Status)
	assert.False(t, strings.HasPrefix(row.Error, SlackNotSentPrefix), "the first attempt may have posted")

	env.scope = "chat:write"
	env.sender.recent = []SlackPosted{{User: "UOWNER", Text: "ship it", TS: "1800000000.000009"}}
	row, err = env.reg.Apply(context.Background(), id)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status, row.Error)
	assert.Empty(t, env.sender.posts)
}

func TestSendSlackMessage_RetryWithAnUnknownOwnerRefuses(t *testing.T) {
	env := newSlackSendEnv(t)
	id := failOnce(t, env, `{"channel":"#general","account_id":2,"text":"hi","reason":"r"}`)
	row, err := env.reg.Apply(context.Background(), id)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "own user id is unknown")
	assert.Contains(t, row.Error, "check the conversation in Slack")
	assert.Empty(t, env.sender.posts)
}

// conversations.replies returns the thread's parent too; a parent with the
// same text is not the landed reply.
func TestSendSlackMessage_ThreadParentIsNotTheLandedReply(t *testing.T) {
	env := newSlackSendEnv(t)
	id := failOnce(t, env, `{"channel":"#ops","thread_ts":"1700000000.000001","text":"ack","reason":"r"}`)
	env.sender.recent = []SlackPosted{{User: "UOWNER", Text: "ack", TS: "1700000000.000001"}}
	row, err := env.reg.Apply(context.Background(), id)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status, row.Error)
	require.Len(t, env.sender.posts, 1)
	assert.Equal(t, "1700000000.000001", env.sender.recentArgs[1])
}

func TestSendSlackMessage_SlackRefusalsSayWhatToDo(t *testing.T) {
	for code, want := range map[string]string{
		"not_in_channel":    "join it in Slack",
		"channel_not_found": "ask for the message again",
		"token_revoked":     SlackSendScopeHint,
	} {
		env := newSlackSendEnv(t)
		env.sender.postErr = errors.New(code)
		rc, err := env.propose(t, `{"channel":"#ops","text":"hi","reason":"r"}`)
		require.NoError(t, err)
		row := approveAndApply(t, env, rc.ActionID)
		assert.Equal(t, "failed", row.Status, code)
		assert.Contains(t, row.Error, want, code)
		assert.Contains(t, row.Error, code, "Slack's own code stays visible")
	}
}

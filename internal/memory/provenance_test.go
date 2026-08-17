package memory

import (
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestSchemeOf pins the ref-grammar classifier: a bare Slack channel id (no
// colon) is scheme "", every colon-bearing ref classifies on its first
// segment — including an act: ref that carries two colons and an unregistered
// scheme like bogus:, which the registry then rejects (MEM-12). An
// account-namespaced Slack ref ("<accountID>:<rawSlackID>", the
// slack.Namespace shape from the multi-account migration) is scheme "" too:
// a purely-numeric pre-colon segment is an account id, never a scheme name,
// since every registered scheme is alphabetic — see schemeOf's doc comment.
func TestSchemeOf(t *testing.T) {
	cases := map[string]string{
		"C0123":                "",
		"chat:42":              "chat",
		"mail:abc":             "mail",
		"cal:evt_1":            "cal",
		"jira:CEX-7413":        "jira",
		"act:inbox_feedback:7": "act",
		"bogus:x":              "bogus",
		"":                     "",
		"1:C0473A5GC6N":        "",
		"42:U999":              "",
	}
	for in, want := range cases {
		assert.Equal(t, want, schemeOf(in), "schemeOf(%q)", in)
	}
}

// TestProvenanceRegistryDispatchesNamespacedSlackMessage is the MEM-12
// regression pin for the multi-account namespacing bug: a namespaced Slack
// message ref ("1:C0473A5GC6N") must dispatch to the message resolver (scheme
// "") and validate against the messages table exactly like a bare ref, not
// fall into an unregistered numeric "scheme" and get rejected as invented.
func TestProvenanceRegistryDispatchesNamespacedSlackMessage(t *testing.T) {
	d := newTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C0473A5GC6N', '100.000100', '1:U1', 'hi')`)
	require.NoError(t, err)
	reg := fullRegistry(d)

	ok, registered, err := reg.Validate(episodeRef{ChannelID: "1:C0473A5GC6N", TS: "100.000100"})
	require.NoError(t, err)
	assert.True(t, registered, "a namespaced Slack ref must classify as the message scheme")
	assert.True(t, ok, "a real namespaced message resolves")
}

// TestProvenanceRegistryDispatchesMessage: a bare-channel ref routes to the
// message resolver (scheme ""), which keys existence on the messages table.
// fullRegistry builds a registry carrying every scheme's resolver — the shape
// the MEM-12 dispatch guards exercise. Production has no single global registry;
// each write site scopes its own (extractor: message-only; gmail: mail-only;
// belief surface: chat+act, the pipeline's p.registry).
func fullRegistry(d *db.DB) *provenanceRegistry {
	return newProvenanceRegistry(
		messageResolver{d},
		chatResolver{db: d, logf: func(string, ...any) {}, contextTypes: []string{"situation", "target", "track"}},
		mailResolver{d},
		calResolver{d},
		actResolver{db: d},
	)
}

func TestProvenanceRegistryDispatchesMessage(t *testing.T) {
	d := newTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1GEN', '100.000100', 'U1', 'hi')`)
	require.NoError(t, err)
	reg := fullRegistry(d)

	ok, registered, err := reg.Validate(episodeRef{ChannelID: "C1GEN", TS: "100.000100"})
	require.NoError(t, err)
	assert.True(t, registered, "a bare channel id is the registered message scheme")
	assert.True(t, ok, "a real message resolves")

	ok, registered, err = reg.Validate(episodeRef{ChannelID: "C1GEN", TS: "999.000000"})
	require.NoError(t, err)
	assert.True(t, registered)
	assert.False(t, ok, "a missing message does not resolve")
}

// TestProvenanceRegistryDispatchesChat: a chat: ref routes to the chat
// resolver, which resolves iff it is a genuine role='user' situation turn
// (MEM-09 owner-authenticity folded into the chat resolver's existence check).
func TestProvenanceRegistryDispatchesChat(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	conv := seedChatConversation(t, d, "situation", "7")
	seedChatMessage(t, d, conv, "user", "owner said", 1720000000.0)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	ok, registered, err := p.registry.Validate(episodeRef{ChannelID: fmt.Sprintf("chat:%d", conv), TS: "1720000000"})
	require.NoError(t, err)
	assert.True(t, registered, "chat is a registered scheme")
	assert.True(t, ok, "an owner turn resolves through the chat resolver")

	conv2 := seedChatConversation(t, d, "situation", "8")
	seedChatMessage(t, d, conv2, "assistant", "bot said", 1720000100.0)
	ok, registered, err = p.registry.Validate(episodeRef{ChannelID: fmt.Sprintf("chat:%d", conv2), TS: "1720000100"})
	require.NoError(t, err)
	assert.True(t, registered)
	assert.False(t, ok, "an assistant turn is not an owner turn (MEM-09)")
}

// TestProvenanceRegistryUnregisteredScheme: a ref whose scheme has no
// registered resolver returns registered=false — the MEM-12 write-time
// rejection seam.
func TestProvenanceRegistryUnregisteredScheme(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	ok, registered, err := p.registry.Validate(episodeRef{ChannelID: "bogus:x", TS: "1"})
	require.NoError(t, err, "an unregistered scheme is a clean rejection, not a lookup error")
	assert.False(t, registered, "an unregistered scheme has no resolver")
	assert.False(t, ok)
}

// TestProvenanceRegistryPropagatesLookupError: a resolver lookup error
// propagates as err (registered=true) so the caller can keep its freeze-vs-drop
// disposition (resolved ambiguity #8).
func TestProvenanceRegistryPropagatesLookupError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)
	p.registry = newProvenanceRegistry(messageResolver{errCheckerAfter{db: d, failTS: "100"}})

	_, registered, err := p.registry.Validate(episodeRef{ChannelID: "C1", TS: "100"})
	require.Error(t, err, "a resolver lookup error propagates unchanged")
	assert.True(t, registered, "the scheme was registered — only the lookup failed")
	assert.Contains(t, err.Error(), "disk I/O error")
}

// TestProvenanceRegistryDispatchesMail: a mail: ref routes to the mail
// resolver, which keys existence on the gmail_messages id only (resolved
// ambiguity #5); a missing id is a clean non-resolution, never an error.
func TestProvenanceRegistryDispatchesMail(t *testing.T) {
	d := newTestDB(t)
	seedGmailMessage(t, d, "msg-1", "thr-1", "a@example.com", "A", "Subj", "body", recentISO(0))
	reg := fullRegistry(d)

	ok, registered, err := reg.Validate(episodeRef{ChannelID: "mail:msg-1", TS: "1720000000"})
	require.NoError(t, err)
	assert.True(t, registered, "mail is a registered scheme")
	assert.True(t, ok, "an existing gmail message resolves by id")

	ok, registered, err = reg.Validate(episodeRef{ChannelID: "mail:missing", TS: "1720000000"})
	require.NoError(t, err)
	assert.True(t, registered)
	assert.False(t, ok, "a missing message id does not resolve")
}

// TestGmailMessageExistsAbsentTable: gmail_messages is a migration-guaranteed
// base table, so a query failure (here, the table dropped out from under the
// check) propagates as a genuine lookup error rather than being masked as a
// clean miss — a masked miss would let the extractor's MEM-01 freeze silently
// pass a batch it never actually validated.
func TestGmailMessageExistsAbsentTable(t *testing.T) {
	d := newTestDB(t)
	_, err := d.Exec(`DROP TABLE gmail_messages`)
	require.NoError(t, err)

	_, err = d.GmailMessageExists("anything")
	require.Error(t, err, "a failed gmail_messages lookup propagates, not masked as a miss")
}

// errMailChecker fails GmailMessageExists with a lookup error — the mail analog
// of errCheckerAfter, for the resolver error-propagation path.
type errMailChecker struct{}

func (errMailChecker) GmailMessageExists(string) (bool, error) {
	return false, fmt.Errorf("disk I/O error")
}

// TestMailResolverPropagatesLookupError: a gmail lookup error propagates as err
// (registered=true) so the caller keeps its freeze-vs-drop disposition.
func TestMailResolverPropagatesLookupError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)
	p.registry = newProvenanceRegistry(mailResolver{errMailChecker{}})

	_, registered, err := p.registry.Validate(episodeRef{ChannelID: "mail:x", TS: "1"})
	require.Error(t, err, "a resolver lookup error propagates unchanged")
	assert.True(t, registered, "the scheme was registered — only the lookup failed")
	assert.Contains(t, err.Error(), "disk I/O error")
}

// TestProvenanceRegistryDispatchesCal: a cal: ref routes to the cal resolver,
// which keys existence on the calendar_events id only (resolved ambiguity #2);
// a missing id is a clean non-resolution, never an error.
func TestProvenanceRegistryDispatchesCal(t *testing.T) {
	d := newTestDB(t)
	seedCalendarEvent(t, d, calEvent{id: "evt-1", title: "Standup", start: "2026-07-15T10:00:00Z", end: "2026-07-15T10:30:00Z"})
	reg := fullRegistry(d)

	ok, registered, err := reg.Validate(episodeRef{ChannelID: "cal:evt-1", TS: "1720000000"})
	require.NoError(t, err)
	assert.True(t, registered, "cal is a registered scheme")
	assert.True(t, ok, "an existing calendar event resolves by id")

	ok, registered, err = reg.Validate(episodeRef{ChannelID: "cal:missing", TS: "1720000000"})
	require.NoError(t, err)
	assert.True(t, registered)
	assert.False(t, ok, "a missing event id does not resolve")
}

// errCalChecker fails CalendarEventExists with a lookup error — the calendar
// analog of errMailChecker, for the resolver error-propagation path.
type errCalChecker struct{}

func (errCalChecker) CalendarEventExists(string) (bool, error) {
	return false, fmt.Errorf("disk I/O error")
}

// TestCalResolverPropagatesLookupError: a calendar lookup error propagates as
// err (registered=true) so the caller keeps its freeze-vs-drop disposition.
func TestCalResolverPropagatesLookupError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)
	p.registry = newProvenanceRegistry(calResolver{errCalChecker{}})

	_, registered, err := p.registry.Validate(episodeRef{ChannelID: "cal:x", TS: "1"})
	require.Error(t, err, "a resolver lookup error propagates unchanged")
	assert.True(t, registered, "the scheme was registered — only the lookup failed")
	assert.Contains(t, err.Error(), "disk I/O error")
}

// TestCalRegisteredInPipelineRegistry: the cal resolver is registered in the
// pipeline's belief-surface registry so a belief-pass op could later cite a
// cal: episode ref (harmless when calendar is dark).
func TestCalRegisteredInPipelineRegistry(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedCalendarEvent(t, d, calEvent{id: "evt-1", title: "Standup", start: "2026-07-15T10:00:00Z", end: "2026-07-15T10:30:00Z"})
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	ok, registered, err := p.registry.Validate(episodeRef{ChannelID: "cal:evt-1", TS: "1"})
	require.NoError(t, err)
	assert.True(t, registered, "cal is registered in the pipeline registry")
	assert.True(t, ok)
}

// seedInboxFeedback inserts an inbox_items row and an inbox_feedback row
// referencing it, returning the feedback rowid (== inbox_feedback.id).
func seedInboxFeedback(t *testing.T, d *db.DB, rating int) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status)
		VALUES ('C1', '1700000001.000100', 'U2', 'mention', 'pending')`)
	require.NoError(t, err)
	itemID, err := res.LastInsertId()
	require.NoError(t, err)
	res, err = d.Exec(`INSERT INTO inbox_feedback (inbox_item_id, rating, created_at)
		VALUES (?, ?, '2026-07-16T00:00:00Z')`, itemID, rating)
	require.NoError(t, err)
	fbID, err := res.LastInsertId()
	require.NoError(t, err)
	return fbID
}

// TestProvenanceRegistryDispatchesAct: an act:<table>:<row_id> ref routes to the
// act resolver, resolving iff the row exists in a WHITELISTED table; a missing
// row and a non-whitelisted table are both clean non-resolutions (registered),
// never errors (resolved ambiguity #6).
func TestProvenanceRegistryDispatchesAct(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	fbID := seedInboxFeedback(t, d, -1)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	ok, registered, err := p.registry.Validate(episodeRef{ChannelID: fmt.Sprintf("act:inbox_feedback:%d", fbID), TS: "1720000000"})
	require.NoError(t, err)
	assert.True(t, registered, "act is a registered scheme")
	assert.True(t, ok, "an existing whitelisted interaction row resolves")

	ok, registered, err = p.registry.Validate(episodeRef{ChannelID: "act:inbox_feedback:999999", TS: "1"})
	require.NoError(t, err)
	assert.True(t, registered)
	assert.False(t, ok, "a missing row does not resolve")

	ok, registered, err = p.registry.Validate(episodeRef{ChannelID: "act:secret_table:1", TS: "1"})
	require.NoError(t, err, "a non-whitelisted table is a clean drop, not an error")
	assert.True(t, registered, "act scheme is registered even for an unknown table")
	assert.False(t, ok, "a non-whitelisted table never resolves")

	// A situation row (also whitelisted) resolves.
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "s", Summary: "s", Chronology: "c"})
	require.NoError(t, err)
	ok, _, err = p.registry.Validate(episodeRef{ChannelID: fmt.Sprintf("act:situations:%d", sitID), TS: "1"})
	require.NoError(t, err)
	assert.True(t, ok, "an existing situation resolves through the act resolver")
}

// TestMemory12_UnregisteredSchemeRejectedAtWrite is the MEM-12 formal guard: a
// provenance ref whose scheme has no registered resolver is dropped-and-counted
// at write time exactly like an invented ref, never written; a registered,
// resolving ref alongside it survives, and an episode whose refs are ALL
// unregistered is discarded entirely (no provenance left).
func TestMemory12_UnregisteredSchemeRejectedAtWrite(t *testing.T) {
	d := newTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1GEN', '100.000100', 'U1', 'hi')`)
	require.NoError(t, err)

	eps := []extractedEpisode{{
		Title: "mixed",
		Refs: []episodeRef{
			{ChannelID: "C1GEN", TS: "100.000100"}, // registered message scheme, resolves
			{ChannelID: "bogus:zzz", TS: "1"},      // unregistered scheme → rejected (MEM-12)
		},
	}}
	kept, dropped, err := validateRefs(d, eps)
	require.NoError(t, err, "an unregistered scheme is a clean drop, never a lookup-error freeze")
	require.Len(t, kept, 1)
	require.Len(t, kept[0].Refs, 1, "only the registered, resolving ref survives")
	assert.Equal(t, "C1GEN", kept[0].Refs[0].ChannelID)
	assert.Equal(t, 1, dropped, "the unregistered-scheme ref is dropped and counted")

	eps2 := []extractedEpisode{{Title: "all bogus", Refs: []episodeRef{{ChannelID: "bogus:a", TS: "1"}}}}
	kept2, dropped2, err := validateRefs(d, eps2)
	require.NoError(t, err)
	assert.Empty(t, kept2, "an all-unregistered episode leaves no provenance and is discarded")
	assert.Equal(t, 1, dropped2)
}

// fakeSenderResolver is a scriptable senderResolver for tests: each method
// looks up its argument in a map and returns the mapped error otherwise.
type fakeSenderResolver struct {
	slack map[string]string // "channelID ts" -> sender
	mail  map[string]string // messageID -> sender
	err   error             // when set, every lookup returns ("", err) instead
}

func (f fakeSenderResolver) SlackSender(channelID, ts string) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	return f.slack[channelID+" "+ts], nil
}

func (f fakeSenderResolver) MailSender(messageID string) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	return f.mail[messageID], nil
}

// TestProvenanceRows builds the db-layer index rows from a node's ## Provenance
// section: each ref is classified by scheme and its ts decoded to a unix float;
// a ref whose ts is not numeric is skipped (it cannot be windowed), and a node
// with no ## Provenance section yields nil. SenderID is populated for Slack and
// Gmail refs via the resolver (Slice B); every other scheme stays "".
func TestProvenanceRows(t *testing.T) {
	body := "# Ep\n\n## Story\nstuff\n\n## Provenance\n" +
		"- C0AAA 1700000000.000100\n" +
		"- mail:abc 1700000500\n" +
		"- notanumber whoops\n"
	n := Node{ID: "ep_1", Type: "episode", Body: body}

	resolver := fakeSenderResolver{
		slack: map[string]string{"C0AAA 1700000000.000100": "U1"},
		mail:  map[string]string{"abc": "sender@example.com"},
	}
	rows := provenanceRows(n, resolver, nil)
	require.Len(t, rows, 2, "the non-numeric ts ref is skipped")

	assert.Equal(t, "ep_1", rows[0].NodeID)
	assert.Equal(t, "", rows[0].Scheme)
	assert.Equal(t, "C0AAA", rows[0].ChannelID)
	assert.Equal(t, "1700000000.000100", rows[0].TSRaw)
	assert.InDelta(t, 1700000000.0001, rows[0].TSUnix, 1e-6)
	assert.Equal(t, "U1", rows[0].SenderID)

	assert.Equal(t, "mail", rows[1].Scheme)
	assert.Equal(t, "mail:abc", rows[1].ChannelID)
	assert.InDelta(t, 1700000500.0, rows[1].TSUnix, 1e-6)
	assert.Equal(t, "sender@example.com", rows[1].SenderID)

	// A node with no provenance section yields nil.
	plain := Node{ID: "ent_1", Type: "entity", Body: "# Entity\n\n## What\nA thing.\n"}
	assert.Nil(t, provenanceRows(plain, resolver, nil))

	// A nil resolver (e.g. merge.go's historical call before Task 3, or any
	// caller that doesn't need sender population) leaves every SenderID "".
	rowsNoResolver := provenanceRows(n, nil, nil)
	require.Len(t, rowsNoResolver, 2)
	assert.Equal(t, "", rowsNoResolver[0].SenderID)
	assert.Equal(t, "", rowsNoResolver[1].SenderID)
}

// TestProvenanceRows_SenderLookupErrorIsNotFatal: a sender-lookup error (or a
// clean not-found) never drops the ref or fails the whole row — it only
// leaves SenderID empty for that one ref (this is index-population plumbing
// downstream of MEM-01's write-time validation, not a second validation
// gate; a genuinely invalid ref was already rejected before it was ever
// written).
func TestProvenanceRows_SenderLookupErrorIsNotFatal(t *testing.T) {
	body := "# Ep\n\n## Story\nstuff\n\n## Provenance\n- C0AAA 1700000000.000100\n"
	n := Node{ID: "ep_1", Type: "episode", Body: body}

	var logged []string
	logf := func(format string, args ...any) { logged = append(logged, fmt.Sprintf(format, args...)) }

	rows := provenanceRows(n, fakeSenderResolver{err: errors.New("boom")}, logf)
	require.Len(t, rows, 1, "a sender lookup failure must not drop the ref")
	assert.Equal(t, "", rows[0].SenderID)
	assert.NotEmpty(t, logged, "the lookup failure is logged")
}

// TestProvenanceRegistryDispatchesJira: a jira:<KEY> ref resolves through
// jiraResolver by issue key; a missing/deleted key is a clean non-resolution.
func TestProvenanceRegistryDispatchesJira(t *testing.T) {
	reg := newProvenanceRegistry(jiraResolver{db: fakeJiraChecker{exists: map[string]bool{"CEX-7413": true}}})
	ok, registered, err := reg.Validate(episodeRef{ChannelID: "jira:CEX-7413", TS: "2026-07-22T10:00:00.000+0000"})
	if err != nil || !registered || !ok {
		t.Errorf("existing issue = ok %v registered %v err %v; want true,true,nil", ok, registered, err)
	}
	ok, registered, err = reg.Validate(episodeRef{ChannelID: "jira:CEX-404", TS: "x"})
	if err != nil || !registered || ok {
		t.Errorf("missing issue = ok %v registered %v err %v; want false,true,nil", ok, registered, err)
	}
}

// TestJiraResolverPropagatesLookupError: a jira_issues lookup error propagates
// (registered=true) — the table is migration-guaranteed, never a clean miss.
func TestJiraResolverPropagatesLookupError(t *testing.T) {
	reg := newProvenanceRegistry(jiraResolver{db: fakeJiraChecker{err: errors.New("db down")}})
	_, registered, err := reg.Validate(episodeRef{ChannelID: "jira:CEX-1", TS: "x"})
	if err == nil || !registered {
		t.Errorf("lookup error: registered %v err %v; want true, non-nil", registered, err)
	}
}

// TestJiraRegisteredInPipelineRegistry: the belief surface's registry carries
// the jira scheme so a belief op may cite a jira: episode ref.
func TestJiraRegisteredInPipelineRegistry(t *testing.T) {
	d, v := newTestDB(t), newTestVault(t)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)
	if _, registered, _ := p.registry.Validate(episodeRef{ChannelID: "jira:CEX-1", TS: "x"}); !registered {
		t.Error("jira scheme not registered in the pipeline registry")
	}
}

type fakeJiraChecker struct {
	exists map[string]bool
	err    error
}

func (f fakeJiraChecker) JiraIssueExists(key string) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	return f.exists[key], nil
}

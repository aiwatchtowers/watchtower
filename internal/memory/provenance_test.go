package memory

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestSchemeOf pins the ref-grammar classifier: a bare Slack channel id (no
// colon) is scheme "", every colon-bearing ref classifies on its first
// segment — including an act: ref that carries two colons and an unregistered
// scheme like bogus:, which the registry then rejects (MEM-12).
func TestSchemeOf(t *testing.T) {
	cases := map[string]string{
		"C0123":                "",
		"chat:42":              "chat",
		"mail:abc":             "mail",
		"cal:evt_1":            "cal",
		"act:inbox_feedback:7": "act",
		"bogus:x":              "bogus",
		"":                     "",
	}
	for in, want := range cases {
		assert.Equal(t, want, schemeOf(in), "schemeOf(%q)", in)
	}
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

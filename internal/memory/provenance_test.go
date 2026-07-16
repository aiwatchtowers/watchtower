package memory

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
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
func TestProvenanceRegistryDispatchesMessage(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1GEN', '100.000100', 'U1', 'hi')`)
	require.NoError(t, err)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	ok, registered, err := p.registry.Validate(episodeRef{ChannelID: "C1GEN", TS: "100.000100"})
	require.NoError(t, err)
	assert.True(t, registered, "a bare channel id is the registered message scheme")
	assert.True(t, ok, "a real message resolves")

	ok, registered, err = p.registry.Validate(episodeRef{ChannelID: "C1GEN", TS: "999.000000"})
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

package memory

import "strings"

// This file is the MEM-12 provenance-resolver registry: the single write-time
// seam that answers "does this provenance ref resolve against a raw source of
// record?" for every ref scheme the vault can carry. It generalizes the two
// hardcoded checks that predate it — the Slack message check (MessageExists,
// MEM-01) and the chat: owner-turn check (ChatTablesPresent + OwnerChatTurnExists,
// MEM-09) — into one interface with one resolver per scheme.
//
// Contract (resolved ambiguity #8): the registry unifies the LOOKUP, never the
// POLICY. Validate returns (ok, registered, err); the CALLER keeps its
// disposition — the extractor freezes the window on a lookup error (MEM-01/04),
// the belief pass soft-drops a chat: lookup error. An unregistered scheme
// (registered=false) is rejected at write and counted like an invented ref
// (MEM-12), never written.

// ProvenanceResolver answers whether one provenance ref of its scheme resolves
// against a raw source of record. One resolver is registered per ref scheme.
type ProvenanceResolver interface {
	// Scheme is the ref grammar's scheme this resolver owns: "" (Slack message),
	// "chat", "mail", "act". It is the key schemeOf classifies a ref into.
	Scheme() string
	// Validate reports whether the ref points at a real source-of-record row.
	// An err means the check itself could not run (the caller decides
	// freeze-vs-drop); (false, nil) is a positive not-found.
	Validate(ref episodeRef) (ok bool, err error)
}

// ProvenanceRegistry dispatches a ref to the resolver registered for its
// scheme. Built once in NewPipeline with the message and chat resolvers (mail
// and act join in Tasks 4/6).
type ProvenanceRegistry struct {
	byScheme map[string]ProvenanceResolver
}

// newProvenanceRegistry indexes the resolvers by their scheme. A later resolver
// for the same scheme wins (construction-time wiring only, never a runtime race).
func newProvenanceRegistry(resolvers ...ProvenanceResolver) *ProvenanceRegistry {
	m := make(map[string]ProvenanceResolver, len(resolvers))
	for _, r := range resolvers {
		m[r.Scheme()] = r
	}
	return &ProvenanceRegistry{byScheme: m}
}

// schemeOf classifies a channel_id by the substring before its first colon: a
// bare Slack channel id (no colon) is scheme ""; "chat:42"→"chat",
// "mail:abc"→"mail", "act:inbox_feedback:7"→"act" (the act scheme carries two
// colons but classifies on its first segment), "bogus:x"→"bogus". The registry
// then decides whether that scheme has a resolver (MEM-12).
func schemeOf(channelID string) string {
	if i := strings.IndexByte(channelID, ':'); i >= 0 {
		return channelID[:i]
	}
	return ""
}

// Validate dispatches ref to its scheme's resolver. registered is false when no
// resolver owns the ref's scheme (MEM-12: the ref is rejected at write, never
// written); ok/err are the resolver's existence answer, which the caller
// disposes of per its own freeze-vs-drop policy (resolved ambiguity #8).
func (r *ProvenanceRegistry) Validate(ref episodeRef) (ok, registered bool, err error) {
	res, found := r.byScheme[schemeOf(ref.ChannelID)]
	if !found {
		return false, false, nil
	}
	got, verr := res.Validate(ref)
	return got, true, verr
}

// messageResolver is the scheme-"" resolver: the Slack/Jira message-existence
// check behind MEM-01. It wraps a messageChecker (the DB in production, an
// erroring fake in tests) so the extractor's checkMsg seam is preserved.
type messageResolver struct{ checker messageChecker }

func (messageResolver) Scheme() string { return "" }

func (m messageResolver) Validate(ref episodeRef) (bool, error) {
	return m.checker.MessageExists(ref.ChannelID, ref.TS)
}

// chatTurnChecker is the write-time chat-ref lookup behind MEM-09. *db.DB
// satisfies it; the seam mirrors messageChecker so a resolver can be tested
// without a live database.
type chatTurnChecker interface {
	ChatTablesPresent() (bool, error)
	OwnerChatTurnExists(conversationID, ts int64) (bool, error)
}

// chatResolver is the scheme-"chat" resolver: it "resolves" a chat:<id> ref iff
// the ref is a genuine role='user' situation Discuss turn (ChatTablesPresent +
// OwnerChatTurnExists). Folding the MEM-09 owner-authenticity check INTO the
// resolver's existence check is deliberate — a chat: ref that resolves is, by
// construction, an authored owner turn, which is exactly what lets
// newEvidenceLines mint it at owner rank (MEM-09 stays a pure code path). Every
// failure mode (unparseable id, absent tables, non-owner turn) is a positive
// non-resolution (ok=false); only a genuine DB failure returns err so the
// belief pass can soft-drop it and re-scan next run.
type chatResolver struct {
	db   chatTurnChecker
	logf func(string, ...any)
}

func (chatResolver) Scheme() string { return strings.TrimSuffix(chatRefPrefix, ":") }

func (c chatResolver) Validate(ref episodeRef) (bool, error) {
	convID, ts, ok := parseChatRef(ref.ChannelID, ref.TS)
	if !ok {
		c.logf("memory: beliefs: chat ref %s %s dropped (unparseable ref, MEM-09)", ref.ChannelID, ref.TS)
		return false, nil
	}
	present, presenceErr := c.db.ChatTablesPresent()
	if presenceErr != nil {
		// Distinguish a presence-check DB error from genuine table absence: the
		// former is a transient failure, not evidence the tables do not exist, so
		// it must never be logged as "tables absent" (P5/style-m3).
		c.logf("memory: beliefs: chat ref %s %s dropped (presence check errored: %v, MEM-09)", ref.ChannelID, ref.TS, presenceErr)
		return false, presenceErr
	}
	if !present {
		c.logf("memory: beliefs: chat ref %s %s dropped (chat tables absent — headless daemon, MEM-09)", ref.ChannelID, ref.TS)
		return false, nil
	}
	owner, cerr := c.db.OwnerChatTurnExists(convID, ts)
	if cerr != nil {
		c.logf("memory: beliefs: chat ref %s %s lookup: %v — dropped", ref.ChannelID, ref.TS, cerr)
		return false, cerr
	}
	if !owner {
		c.logf("memory: beliefs: chat ref %s %s is not an owner (role='user') situation turn — dropped (MEM-09)", ref.ChannelID, ref.TS)
		return false, nil
	}
	return true, nil
}

// extractorRegistry is the registry the Slack episode extractor validates
// against: the message resolver over the given checker (scheme ""). The
// extractor only ever emits bare-channel refs, so any other scheme is
// unregistered and rejected at write (MEM-12). It is built from the passed
// checker rather than the pipeline's stored registry so the checkMsg
// lookup-failure seam (pipeline_test.go) keeps freezing the watermark on error.
func extractorRegistry(checker messageChecker) *ProvenanceRegistry {
	return newProvenanceRegistry(messageResolver{checker})
}

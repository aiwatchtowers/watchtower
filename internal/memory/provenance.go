package memory

import (
	"strconv"
	"strings"
)

// This file is the MEM-12 provenance-resolver registry: the write-time seam
// that answers "does this provenance ref resolve against a raw source of
// record?" for every ref scheme the vault can carry. It generalizes the two
// hardcoded checks that predate it — the Slack message check (MessageExists,
// MEM-01) and the chat: owner-turn check (ChatTablesPresent + OwnerChatTurnExists,
// MEM-09) — into one interface with one resolver per scheme.
//
// There is no single global registry: each write site validates through a
// registry SCOPED to the schemes valid at that site, so a scheme can never be
// smuggled in where it does not belong. The Slack extractor validates through a
// message-only registry (extractorRegistry, built from the checkMsg seam so the
// MEM-01 lookup-freeze test keeps biting); the Gmail extractor through a
// mail-only registry (built once per run); the belief surface through the
// pipeline's chat+act registry (p.registry, the only schemes validateChatRefs
// routes). A ref of a scheme the site's registry does not carry is rejected at
// write and counted like an invented ref (MEM-12), never written.
//
// Contract (resolved ambiguity #8): the registry unifies the LOOKUP, never the
// POLICY. Validate returns (ok, registered, err); the CALLER keeps its
// disposition — the extractor freezes the window on a lookup error (MEM-01/04),
// the belief pass soft-drops a chat:/act: lookup error.

// provenanceResolver answers whether one provenance ref of its scheme resolves
// against a raw source of record. One resolver is registered per ref scheme.
type provenanceResolver interface {
	// Scheme is the ref grammar's scheme this resolver owns: "" (Slack message),
	// "chat", "mail", "act". It is the key schemeOf classifies a ref into.
	Scheme() string
	// Validate reports whether the ref points at a real source-of-record row.
	// An err means the check itself could not run (the caller decides
	// freeze-vs-drop); (false, nil) is a positive not-found.
	Validate(ref episodeRef) (ok bool, err error)
}

// provenanceRegistry dispatches a ref to the resolver registered for its
// scheme. Callers build one scoped to their write site's valid schemes.
type provenanceRegistry struct {
	byScheme map[string]provenanceResolver
}

// newProvenanceRegistry indexes the resolvers by their scheme. A later resolver
// for the same scheme wins (construction-time wiring only, never a runtime race).
func newProvenanceRegistry(resolvers ...provenanceResolver) *provenanceRegistry {
	m := make(map[string]provenanceResolver, len(resolvers))
	for _, r := range resolvers {
		m[r.Scheme()] = r
	}
	return &provenanceRegistry{byScheme: m}
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
func (r *provenanceRegistry) Validate(ref episodeRef) (ok, registered bool, err error) {
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
	OwnerChatTurnExists(conversationID, ts int64, contextTypes []string) (bool, error)
}

// memoChatChecker wraps a chatTurnChecker and memoizes ChatTablesPresent for the
// span of one validateChatRefs call: without it the chat resolver round-trips the
// presence query once per chat ref. reset() is called at the start of each
// validateChatRefs pass, so a chat table created lazily between runs is still
// picked up on the next pass. OwnerChatTurnExists is NOT cached — it is per-ref.
type memoChatChecker struct {
	db      chatTurnChecker
	checked bool
	present bool
	err     error
}

func (m *memoChatChecker) reset() { m.checked = false }

func (m *memoChatChecker) ChatTablesPresent() (bool, error) {
	if !m.checked {
		m.present, m.err = m.db.ChatTablesPresent()
		m.checked = true
	}
	return m.present, m.err
}

func (m *memoChatChecker) OwnerChatTurnExists(conversationID, ts int64, contextTypes []string) (bool, error) {
	return m.db.OwnerChatTurnExists(conversationID, ts, contextTypes)
}

// chatResolver is the scheme-"chat" resolver: it "resolves" a chat:<id> ref iff
// the ref is a genuine role='user' Discuss turn in a conversation whose
// context_type is in contextTypes (ChatTablesPresent + OwnerChatTurnExists).
// Folding the MEM-09 owner-authenticity check INTO the resolver's existence
// check is deliberate — a chat: ref that resolves is, by construction, an
// authored owner turn, which is exactly what lets newEvidenceLines mint it at
// owner rank (MEM-09 stays a pure code path). contextTypes is {"situation"} when
// memory.sources.chats is off (byte-identical to the Phase-4 situation-only
// check, so every MEM-09 guard passes unchanged) and {"situation","target",
// "track"} when on, so owner-rank elevation widens in lockstep with the flag.
// Every failure mode (unparseable id, absent tables, non-owner turn, wrong
// context type) is a positive non-resolution (ok=false); only a genuine DB
// failure returns err so the belief pass can soft-drop it and re-scan next run.
type chatResolver struct {
	db           chatTurnChecker
	logf         func(string, ...any)
	contextTypes []string
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
	owner, cerr := c.db.OwnerChatTurnExists(convID, ts, c.contextTypes)
	if cerr != nil {
		c.logf("memory: beliefs: chat ref %s %s lookup: %v — dropped", ref.ChannelID, ref.TS, cerr)
		return false, cerr
	}
	if !owner {
		c.logf("memory: beliefs: chat ref %s %s is not an owner (role='user') Discuss turn in an allowed context — dropped (MEM-09)", ref.ChannelID, ref.TS)
		return false, nil
	}
	return true, nil
}

// mailChecker is the write-time gmail-message existence lookup behind the mail:
// scheme. *db.DB satisfies it; tests inject an erroring fake to exercise the
// lookup-error propagation path without a live gmail_messages table.
type mailChecker interface {
	GmailMessageExists(id string) (bool, error)
}

// mailResolver is the scheme-"mail" resolver: a mail:<message_id> ref resolves
// iff a gmail_messages row with that id exists (resolved ambiguity #5 — identity
// is the message id; the ref's ts carries the internal_date for age math but is
// not re-validated here). The Gmail extractor builds a mail-only registry from
// it once per run; gmail_messages is a migration-guaranteed base table, so a
// lookup failure is a genuine error (batch freeze), not a clean miss.
type mailResolver struct{ db mailChecker }

// mailRefPrefix marks an evidence/episode channel_id as a Gmail message
// reference ("mail:<message_id>").
const mailRefPrefix = "mail:"

func (mailResolver) Scheme() string { return strings.TrimSuffix(mailRefPrefix, ":") }

func (m mailResolver) Validate(ref episodeRef) (bool, error) {
	return m.db.GmailMessageExists(strings.TrimPrefix(ref.ChannelID, mailRefPrefix))
}

// calChecker is the write-time calendar-event existence lookup behind the cal:
// scheme. *db.DB satisfies it; tests inject an erroring fake to exercise the
// lookup-error propagation path without a live calendar_events table.
type calChecker interface {
	CalendarEventExists(id string) (bool, error)
}

// calResolver is the scheme-"cal" resolver: a cal:<event_id> ref resolves iff a
// calendar_events row with that id exists (resolved ambiguity #2 — identity is
// the event id; the ref's ts carries the event start time for age math but is
// not re-validated here, the mailResolver shape). The mechanical calendar
// builder validates through a cal-only registry built from it; calendar_events
// is a migration-guaranteed base table, so a lookup failure is a genuine error
// (step freeze), not a clean miss (the GmailMessageExists precedent).
type calResolver struct{ db calChecker }

// calRefPrefix marks an evidence/episode channel_id as a calendar event
// reference ("cal:<event_id>").
const calRefPrefix = "cal:"

func (calResolver) Scheme() string { return strings.TrimSuffix(calRefPrefix, ":") }

func (c calResolver) Validate(ref episodeRef) (bool, error) {
	return c.db.CalendarEventExists(strings.TrimPrefix(ref.ChannelID, calRefPrefix))
}

// interactionChecker is the write-time owner-interaction existence lookup behind
// the act: scheme (MEM-15). *db.DB satisfies it; the whitelist of source tables
// lives in InteractionExists.
type interactionChecker interface {
	InteractionExists(table string, id int64) (bool, error)
}

// actResolver is the scheme-"act" resolver: an act:<table>:<row_id> ref resolves
// iff row_id exists in a whitelisted owner-interaction table (resolved ambiguity
// #6 — inbox_feedback / user_interactions / decision_reads / situations). A
// malformed ref or a non-whitelisted table is a clean non-resolution (ok=false,
// no error), so it drops like an invented ref. This existence check is what lets
// newEvidenceLines mint owner-action rank for an act: ref (MEM-15) — the model
// can propose the ref, but only a real interaction row makes it count. Drops are
// logged here at the resolver, the same one consistent site as the chat
// resolver's drop logs (belief-surface drop-logging parity).
type actResolver struct {
	db   interactionChecker
	logf func(string, ...any)
}

// actRefPrefix marks an evidence channel_id as an owner-interaction reference
// ("act:<table>:<row_id>"). It classifies as scheme "act" on its first colon
// segment despite carrying two colons (schemeOf).
const actRefPrefix = "act:"

func (actResolver) Scheme() string { return strings.TrimSuffix(actRefPrefix, ":") }

func (a actResolver) Validate(ref episodeRef) (bool, error) {
	logf := a.logf
	if logf == nil {
		logf = func(string, ...any) {}
	}
	table, id, ok := parseActRef(ref.ChannelID)
	if !ok {
		logf("memory: beliefs: act ref %s dropped (malformed ref, MEM-15)", ref.ChannelID)
		return false, nil
	}
	exists, err := a.db.InteractionExists(table, id)
	if err != nil {
		logf("memory: beliefs: act ref %s lookup: %v — dropped", ref.ChannelID, err)
		return false, err
	}
	if !exists {
		logf("memory: beliefs: act ref %s dropped (no such %s interaction row, MEM-15)", ref.ChannelID, table)
	}
	return exists, nil
}

// parseActRef splits an "act:<table>:<row_id>" channel id into its table and
// integer row id. The row id is the final colon segment (a table name never
// contains a colon, but LastIndex is robust either way); a malformed shape or a
// non-integer row id yields ok=false.
func parseActRef(channelID string) (table string, id int64, ok bool) {
	rest := strings.TrimPrefix(channelID, actRefPrefix)
	i := strings.LastIndexByte(rest, ':')
	if i <= 0 {
		return "", 0, false
	}
	table = rest[:i]
	id, err := strconv.ParseInt(rest[i+1:], 10, 64)
	if err != nil {
		return "", 0, false
	}
	return table, id, true
}

// extractorRegistry is the message-only registry the Slack episode extractor
// validates against (scheme ""). The extractor only ever emits bare-channel
// refs, so any other scheme is unregistered and rejected at write (MEM-12). It
// is built per call from the passed checker (not the pipeline's chat+act
// registry) so the checkMsg lookup-failure seam (pipeline_test.go) keeps
// freezing the watermark on error.
func extractorRegistry(checker messageChecker) *provenanceRegistry {
	return newProvenanceRegistry(messageResolver{checker})
}

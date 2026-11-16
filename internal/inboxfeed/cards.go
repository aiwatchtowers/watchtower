package inboxfeed

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/tower/api"
)

// The legacy entries' fixed card ids.
const (
	TracksCardID       = "tracks"
	IdeasCardID        = "ideas"
	ThreadBriefsCardID = "thread-briefs"
	MessagesCardID     = "messages"
)

// The kinds ParseCardID answers.
const (
	KindOutput       = "output"
	KindAction       = "action"
	KindReminder     = "reminder"
	KindNotice       = "notice"
	KindBrief        = "brief"
	KindTracks       = "tracks"
	KindIdeas        = "ideas"
	KindThreadBriefs = "thread-briefs"
	KindMessages     = "messages"
)

const briefPrefix = "brief-"

// OutputCardID is an artifact's card id: o<automation_outputs.id>.
func OutputCardID(id int64) string { return "o" + strconv.FormatInt(id, 10) }

// ActionCardID is a native approval's card id: a<agent_actions.id>.
func ActionCardID(id int64) string { return "a" + strconv.FormatInt(id, 10) }

// ReminderCardID is a due reminder's card id: r<reminders.id>.
func ReminderCardID(id int64) string { return "r" + strconv.FormatInt(id, 10) }

// NoticeCardID is a built-in upgrade notice's card id: n<builtin_migrations
// rowid> (the row's upsert keeps its rowid).
func NoticeCardID(id int64) string { return "n" + strconv.FormatInt(id, 10) }

// BriefCardID is a Morning brief day's card id: brief-<yyyy-MM-dd>.
func BriefCardID(date string) string { return briefPrefix + date }

// ParseCardID reads a card id: its kind (Kind*), the row id of the
// numbered kinds and the date of a brief.
func ParseCardID(id string) (kind string, num int64, date string, err error) {
	switch id {
	case TracksCardID:
		return KindTracks, 0, "", nil
	case IdeasCardID:
		return KindIdeas, 0, "", nil
	case ThreadBriefsCardID:
		return KindThreadBriefs, 0, "", nil
	case MessagesCardID:
		return KindMessages, 0, "", nil
	}
	if d, ok := strings.CutPrefix(id, briefPrefix); ok {
		if _, perr := time.Parse("2006-01-02", d); perr != nil {
			return "", 0, "", fmt.Errorf("inboxfeed: card id %q: not a date", id)
		}
		return KindBrief, 0, d, nil
	}
	kinds := map[byte]string{'o': KindOutput, 'a': KindAction, 'r': KindReminder, 'n': KindNotice}
	if len(id) < 2 || kinds[id[0]] == "" {
		return "", 0, "", fmt.Errorf("inboxfeed: unknown card id %q", id)
	}
	n, perr := strconv.ParseInt(id[1:], 10, 64)
	if perr != nil || n <= 0 || strconv.FormatInt(n, 10) != id[1:] {
		return "", 0, "", fmt.Errorf("inboxfeed: card id %q: bad number", id)
	}
	return kinds[id[0]], n, "", nil
}

// output is one open inbox output (AutomationQueries.fetchInboxOutputs).
type output struct {
	ID, AutomationID, RunID int64
	Name, BuiltinID         string
	Title, Body, Priority   string
	BlocksJSON, ContentHash string
	Living, Unread          bool
	CreatedAt, WrittenAt    time.Time
	ChangedAt               time.Time
	// FolderID is its effective folder (inbox_artifact_folders); 0 when
	// none.
	FolderID sql.NullInt64
	// ActionsJSON is its own buttons; PressedAction and PressedRunID its
	// Reply press (the flattened index, the run it queued).
	ActionsJSON, Link           string
	PressedAction, PressedRunID sql.NullInt64
	// Recipe is its automation as the Reply buttons read it.
	Recipe recipeState
}

// readOutputs reads the open inbox outputs (neither done nor dismissed,
// read or not), the most recently changed first.
func readOutputs(ctx context.Context, tx *sql.Tx) ([]output, error) {
	rows, err := tx.QueryContext(ctx, `SELECT o.id, o.automation_id, o.run_id, o.title, o.body, o.priority,
			o.created_at, o.read_at IS NULL, o.blocks_json, o.output_key IS NOT NULL, o.content_hash,
			COALESCE(o.written_at, ''), COALESCE(o.changed_at, ''),
			COALESCE(NULLIF(a.name, ''), a.slug), COALESCE(a.builtin_id, ''), f.folder_id,
			o.actions_json, o.link, o.pressed_action, o.pressed_run_id,
			a.parse_error != '', a.removed_at IS NOT NULL,
			a.parse_error = '' AND a.removed_at IS NULL AND a.confirmed_hash != a.approval_hash,
			a.parse_error = '' AND a.enabled AND a.removed_at IS NULL AND a.confirmed_hash != ''
				AND a.confirmed_hash = a.approval_hash
		FROM automation_outputs o JOIN automations a ON a.id = o.automation_id
		LEFT JOIN inbox_artifact_folders f ON f.output_id = o.id
		WHERE o.kind = 'inbox' AND o.done_at IS NULL AND o.dismissed_at IS NULL
		ORDER BY o.changed_at DESC, o.id DESC`)
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the artifacts: %w", err)
	}
	defer rows.Close()
	var out []output
	for rows.Next() {
		var o output
		var created, written, changed string
		if err := rows.Scan(&o.ID, &o.AutomationID, &o.RunID, &o.Title, &o.Body, &o.Priority,
			&created, &o.Unread, &o.BlocksJSON, &o.Living, &o.ContentHash, &written, &changed,
			&o.Name, &o.BuiltinID, &o.FolderID, &o.ActionsJSON, &o.Link, &o.PressedAction, &o.PressedRunID,
			&o.Recipe.parseError, &o.Recipe.removed, &o.Recipe.needsConfirmation, &o.Recipe.runnable); err != nil {
			return nil, fmt.Errorf("inboxfeed: reading an artifact: %w", err)
		}
		o.CreatedAt = parseStamp(created)
		o.WrittenAt, o.ChangedAt = o.CreatedAt, o.CreatedAt
		if written != "" {
			o.WrittenAt = parseStamp(written)
		}
		if changed != "" {
			o.ChangedAt = parseStamp(changed)
		}
		out = append(out, o)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the artifacts: %w", err)
	}
	return out, nil
}

// parseStamp reads an RFC 3339 time (fractional seconds allowed); an
// unreadable one is the zero time, listed last.
func parseStamp(s string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}
	}
	return t.UTC()
}

// formatStamp is a feed stamp: RFC 3339 UTC, whole seconds.
func formatStamp(t time.Time) string { return t.UTC().Format(stampLayout) }

// place sorts the outputs keep accepts into their folders, each list in the
// read's order (InboxFolderQueries.artifactsByFolder): a folder the tree
// does not hold shows in the root.
func place(t tree, outputs []output, keep func(output) bool) map[int64][]output {
	out := map[int64][]output{}
	for _, o := range outputs {
		if !keep(o) {
			continue
		}
		folder := t.root().ID
		if o.FolderID.Valid {
			if _, ok := t.byID[o.FolderID.Int64]; ok {
				folder = o.FolderID.Int64
			}
		}
		out[folder] = append(out[folder], o)
	}
	return out
}

// cards are folder f's entries in list order (InboxFolderEntries.build):
//   - Needs approval: the built-in upgrade notices, then every open
//     approval (native cards above the recipe's), then the settled rows;
//   - the root: Waiting for me first while it has rows that wait on the
//     owner; then, newest first, its artifacts and the legacy entries by
//     their own time; on a tree without Needs approval, the approvals'
//     entries last;
//   - an owner folder: its artifacts, newest change first.
func (s *snapshot) cards(f folderRow) []api.Card {
	switch f.Kind {
	case api.FolderApprovals:
		return s.approvalCards(f.ID)
	case api.FolderRoot:
		var pinned []api.Card
		var timed []timedCard
		for _, o := range s.artifacts[f.ID] {
			c := s.artifactCard(o, f.ID)
			if c.Pinned {
				pinned = append(pinned, c)
				continue
			}
			timed = append(timed, timedCard{o.ChangedAt, c})
		}
		timed = append(timed, s.legacyCards(f.ID)...)
		sort.SliceStable(timed, func(i, j int) bool { return timed[i].at.After(timed[j].at) })
		out := pinned
		for _, t := range timed {
			out = append(out, t.card)
		}
		if !s.tree.hasApprovals() {
			out = append(out, s.approvalCards(f.ID)...)
		}
		return out
	default:
		out := make([]api.Card, 0, len(s.artifacts[f.ID]))
		for _, o := range s.artifacts[f.ID] {
			out = append(out, s.artifactCard(o, f.ID))
		}
		return out
	}
}

// artifactCard is an artifact's card (InboxFolderEntries.row, InboxCardTexts,
// InboxCardSubject): its title (the automation's name when it has none),
// its source, a markdown preview of its body, its stamp (a living card's
// last write, else its creation), unread (its rows that wait when it has
// row refs, else never opened) and pinned (Waiting for me with rows that
// wait). A block document past MaxBlocksBytes is sent as a notice card.
func (s *snapshot) artifactCard(o output, folder int64) api.Card {
	refs := s.refs[o.ID]
	waiting := waitingRows(refs, s.refState.waits)
	unread := o.Unread
	if len(refs) > 0 {
		unread = waiting > 0
	}
	stamp := o.CreatedAt
	if o.Living {
		stamp = o.WrittenAt
	}
	c := api.Card{
		ID: OutputCardID(o.ID), FolderID: folder, CardKind: api.CardArtifact,
		Title: cardTitle(o), SourceLine: sourceLine(o), Preview: Preview(o.Body),
		Stamp: formatStamp(stamp), Living: o.Living, Unread: unread, Priority: priority(o.Priority),
		Pinned:     s.waitingForMe.automationID != 0 && o.AutomationID == s.waitingForMe.automationID && waiting > 0,
		Automation: &api.CardAutomation{ID: o.AutomationID, Name: o.Name, BuiltinID: o.BuiltinID, RunID: o.RunID},
		Blocks:     o.BlocksJSON, Body: o.Body, Link: o.Link, ContentHash: o.ContentHash,
		Actions: s.cardActions(o, s.now), RefFacts: s.refState.refFacts(refs),
	}
	if len(c.Blocks) > MaxBlocksBytes {
		c.CardKind, c.Blocks, c.Actions = api.CardNotice, "", []api.CardAction{}
		c.Body, c.Preview = TooLargeSentence, TooLargeSentence
	}
	return c
}

// notice is a built-in whose one-time move failed (BuiltinUpgradeNotice).
type notice struct {
	RowID     int64
	BuiltinID string
	Error     string
	UpdatedAt time.Time
}

// readNotices reads every failed move, newest first.
func readNotices(ctx context.Context, tx *sql.Tx) ([]notice, error) {
	rows, err := tx.QueryContext(ctx, `SELECT rowid, builtin_id, error, updated_at FROM builtin_migrations
		WHERE status = 'failed' ORDER BY updated_at DESC, builtin_id`)
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the built-in moves: %w", err)
	}
	defer rows.Close()
	var out []notice
	for rows.Next() {
		var n notice
		var updated string
		if err := rows.Scan(&n.RowID, &n.BuiltinID, &n.Error, &updated); err != nil {
			return nil, fmt.Errorf("inboxfeed: reading a built-in move: %w", err)
		}
		n.UpdatedAt = parseStamp(updated)
		out = append(out, n)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the built-in moves: %w", err)
	}
	return out, nil
}

// noticeCard is a failed move's card: "Couldn't move X to Automations",
// always unread, its error as the body.
func noticeCard(n notice, folder int64) api.Card {
	return api.Card{
		ID: NoticeCardID(n.RowID), FolderID: folder, CardKind: api.CardNotice,
		Title: noticeTitle(n.BuiltinID), Stamp: formatStamp(n.UpdatedAt), Unread: true,
		Priority: "medium", Body: n.Error, Actions: []api.CardAction{}, RefFacts: []api.RefFacts{},
	}
}

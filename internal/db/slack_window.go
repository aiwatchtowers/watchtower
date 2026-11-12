package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	watchtowerslack "watchtower/internal/slack"
)

// WindowScope names which Slack conversations a raw window reads.
type WindowScope string

// WindowScopeMemberChannels is every unarchived public or private channel the
// owner is a member of, plus every 1:1 DM and group DM (a DM or group DM row
// exists only for the owner's own conversations).
const WindowScopeMemberChannels WindowScope = "member_channels"

// Slack window caps. The byte budget bounds the window as llm() will see it
// once serialised as JSON (automations.MaxLLMInputBytes, 200 KiB, counts the
// prompt, the serialised input and the schema): each row costs the
// JSON-encoded length of every string field, escaping included (encoding/json
// writes < > & as \u003c-style 6-byte escapes, so every Slack mention and link
// costs more than its raw bytes), plus SlackWindowRowOverheadBytes. The 20 KiB
// left under the limit is for the prompt and the schema.
const (
	SlackWindowMaxMessages  = 500
	SlackWindowMaxTextChars = 200_000
	SlackWindowMaxBytes     = 180 << 10
	SlackWindowMaxAge       = 7 * 24 * time.Hour
	SlackWindowTextRunes    = 4000 // per message; a longer text is cut with "…"
	// SlackWindowRowOverheadBytes is a row's JSON cost besides its string
	// values, sized on the primitive's row shape {id, channel_id, channel,
	// author, at, time, text, thread_id, permalink, by_owner, to_owner, bot}
	// with generous non-string values: every string empty, the largest int64
	// id, a 35-byte RFC 3339 "at" (nanoseconds and a zone offset), a 32-byte
	// "time" and three false booleans encode to 238 bytes, plus 1 for the
	// array comma; rounded up to 240. A field added to the row shape re-sizes
	// it (TestSlackWindow_RowOverheadCoversTheRowShape).
	SlackWindowRowOverheadBytes = 240
)

// SlackWindowQuery is one read of the Slack window.
type SlackWindowQuery struct {
	Scope      WindowScope
	AfterRowID int64     // messages.rowid already read; 0 = no cursor
	Floor      time.Time // zero = none
	Now        time.Time
}

// SlackWindowMessage is one message of the window, in arrival order.
type SlackWindowMessage struct {
	RowID                                                                              int64
	ChannelID, ChannelName, ChannelType, TS, ThreadTS, UserID, Author, Text, Permalink string
	At                                                                                 time.Time
	ByOwner, ToOwner, Bot                                                              bool
}

// SlackWindow is the result of ReadSlackWindow.
type SlackWindow struct {
	Messages []SlackWindowMessage
	// NextRowID is the cursor for the next read: the newest messages.rowid
	// when the window was read to its end, else the last included message's.
	NextRowID int64
	Truncated bool
	// SkippedOlder counts in-scope rows past the cursor older than
	// SlackWindowMaxAge; BelowFloor those within the age limit but before
	// Floor. Both stay 0 without a cursor.
	SkippedOlder int
	BelowFloor   int
}

type slackWindowCaps struct{ messages, textChars, bytes int }

var defaultSlackWindowCaps = slackWindowCaps{
	messages: SlackWindowMaxMessages, textChars: SlackWindowMaxTextChars, bytes: SlackWindowMaxBytes,
}

// slackWindowJoins and slackWindowFilters are the window's FROM and its
// filters up to the scope; the filters bind AfterRowID. Callers append the
// scope and their own predicates.
const slackWindowJoins = `FROM messages m
	JOIN channels c ON c.id = m.channel_id
	JOIN slack_accounts sa ON sa.id = CAST(substr(m.channel_id, 1, instr(m.channel_id, ':') - 1) AS INTEGER)
	LEFT JOIN users u ON u.id = m.user_id
	LEFT JOIN channel_settings cs ON cs.channel_id = m.channel_id`

const slackWindowFilters = `m.rowid > ?
	  AND sa.enabled = 1 AND sa.status NOT IN ('removed', 'purged')
	  AND m.is_deleted = 0
	  AND m.text != ''
	  AND m.subtype NOT IN ('channel_join', 'channel_leave', 'channel_topic', 'channel_purpose',
	                        'channel_name', 'channel_archive', 'channel_unarchive')
	  AND COALESCE(u.is_muted_for_llm, 0) = 0
	  AND COALESCE(cs.is_muted_for_llm, 0) = 0`

func slackWindowScopeSQL(scope WindowScope) (string, error) {
	switch scope {
	case WindowScopeMemberChannels:
		return `c.is_archived = 0 AND ((c.type IN ('public', 'private') AND c.is_member = 1) OR c.type IN ('dm', 'group_dm'))`, nil
	}
	return "", fmt.Errorf("slack window: unknown scope %q", scope)
}

// slackWindowBounds returns the age bound (Now − SlackWindowMaxAge) and the
// effective lower bound max(Floor, age bound), as ts_unix seconds.
func slackWindowBounds(q SlackWindowQuery) (age, lower float64, err error) {
	if q.Now.IsZero() {
		return 0, 0, errors.New("slack window: Now is zero")
	}
	ageAt := q.Now.Add(-SlackWindowMaxAge)
	lowerAt := ageAt
	if q.Floor.After(lowerAt) {
		lowerAt = q.Floor
	}
	return float64(ageAt.Unix()), float64(lowerAt.Unix()), nil
}

// SlackWindowHasMaterial reports whether ReadSlackWindow would return at least
// one message: an in-scope message past the cursor at or after the effective
// lower bound. It reads no message bodies.
func (db *DB) SlackWindowHasMaterial(ctx context.Context, q SlackWindowQuery) (bool, error) {
	scope, err := slackWindowScopeSQL(q.Scope)
	if err != nil {
		return false, err
	}
	_, lower, err := slackWindowBounds(q)
	if err != nil {
		return false, err
	}
	var has bool
	err = db.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 `+slackWindowJoins+`
		WHERE `+slackWindowFilters+`
		  AND m.ts_unix >= ? AND `+scope+`)`, q.AfterRowID, lower).Scan(&has)
	if err != nil {
		return false, fmt.Errorf("slack window: checking for material: %w", err)
	}
	return has, nil
}

// ReadSlackWindow reads the Slack messages past q.AfterRowID in arrival order
// (rowid ascending), in one read-only transaction, cut at the window caps.
func (db *DB) ReadSlackWindow(ctx context.Context, q SlackWindowQuery) (SlackWindow, error) {
	return db.readSlackWindow(ctx, q, defaultSlackWindowCaps)
}

// slackWindowRow is a streamed row before it becomes a message.
type slackWindowRow struct {
	msg        SlackWindowMessage
	owner      string
	tsUnix     float64
	channel    string
	userName   [3]string // display_name, real_name, name
	dmUserName [3]string
}

func (db *DB) readSlackWindow(ctx context.Context, q SlackWindowQuery, caps slackWindowCaps) (SlackWindow, error) {
	scope, err := slackWindowScopeSQL(q.Scope)
	if err != nil {
		return SlackWindow{}, err
	}
	age, lower, err := slackWindowBounds(q)
	if err != nil {
		return SlackWindow{}, err
	}
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return SlackWindow{}, fmt.Errorf("slack window: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var maxRowID int64
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&maxRowID); err != nil {
		return SlackWindow{}, fmt.Errorf("slack window: newest rowid: %w", err)
	}
	groupNames, err := slackWindowGroupDMNames(ctx, tx)
	if err != nil {
		return SlackWindow{}, err
	}

	// Without a cursor the read starts at the lower bound and counts nothing;
	// with one, every in-scope row past it is streamed and the old ones are
	// counted (their bodies are not read).
	scanFrom := lower
	if q.AfterRowID > 0 {
		scanFrom = -math.MaxFloat64
	}
	w, owners, err := streamSlackWindow(ctx, tx, scope, q.AfterRowID, scanFrom, age, lower, groupNames, caps)
	if err != nil {
		return SlackWindow{}, err
	}
	if !w.Truncated {
		w.NextRowID = max(maxRowID, q.AfterRowID)
	}
	if err := markSlackWindowToOwner(ctx, tx, &w, owners); err != nil {
		return SlackWindow{}, err
	}
	return w, nil
}

// streamSlackWindow reads the rows and applies the caps (each checked before a
// row is appended). Counts of passed rows are kept only up to the last included
// message when the window is cut, so the next read does not count them twice.
// owners maps each included message's account ("<id>" of its channel's
// "<id>:" prefix) to that account's current_user_id.
func streamSlackWindow(ctx context.Context, tx *sql.Tx, scope string, after int64, scanFrom, age, lower float64,
	groupNames map[string]string, caps slackWindowCaps) (w SlackWindow, owners map[string]string, err error) {
	//nolint:gosec // G202: the concatenated joins, filters and scope are the package's constant SQL; every value is a bound arg.
	rows, err := tx.QueryContext(ctx, `SELECT m.rowid, m.channel_id, c.name, c.type, m.ts, COALESCE(m.thread_ts, ''),
		       m.user_id, COALESCE(u.display_name, ''), COALESCE(u.real_name, ''), COALESCE(u.name, ''),
		       CASE WHEN m.ts_unix >= ? THEN m.text ELSE '' END, m.permalink, m.ts_unix,
		       sa.current_user_id, COALESCE(u.is_bot_override, u.is_bot, 0),
		       COALESCE(du.display_name, ''), COALESCE(du.real_name, ''), COALESCE(du.name, '')
		`+slackWindowJoins+`
		LEFT JOIN users du ON c.type = 'dm' AND du.id = c.dm_user_id
		WHERE `+slackWindowFilters+`
		  AND m.ts_unix >= ? AND `+scope+`
		ORDER BY m.rowid`, lower, after, scanFrom)
	if err != nil {
		return SlackWindow{}, nil, fmt.Errorf("slack window: reading messages: %w", err)
	}
	defer rows.Close()

	w = SlackWindow{NextRowID: after}
	owners = map[string]string{}
	var chars, size, pendingOlder, pendingBelow int
	for rows.Next() {
		var r slackWindowRow
		var bot int
		if err := rows.Scan(&r.msg.RowID, &r.msg.ChannelID, &r.channel, &r.msg.ChannelType, &r.msg.TS, &r.msg.ThreadTS,
			&r.msg.UserID, &r.userName[0], &r.userName[1], &r.userName[2],
			&r.msg.Text, &r.msg.Permalink, &r.tsUnix, &r.owner, &bot,
			&r.dmUserName[0], &r.dmUserName[1], &r.dmUserName[2]); err != nil {
			return SlackWindow{}, nil, fmt.Errorf("slack window: scanning a message: %w", err)
		}
		if r.tsUnix < age {
			pendingOlder++
			continue
		}
		if r.tsUnix < lower {
			pendingBelow++
			continue
		}
		m := finishSlackWindowRow(r, bot == 1, groupNames)
		runes := utf8.RuneCountInString(m.Text)
		bytes := slackWindowMessageBytes(m)
		if len(w.Messages)+1 > caps.messages || chars+runes > caps.textChars || size+bytes > caps.bytes {
			w.Truncated = true
			break
		}
		w.Messages = append(w.Messages, m)
		acct, _, _ := strings.Cut(m.ChannelID, ":")
		owners[acct] = r.owner
		chars += runes
		size += bytes
		w.SkippedOlder += pendingOlder
		w.BelowFloor += pendingBelow
		pendingOlder, pendingBelow = 0, 0
		w.NextRowID = m.RowID
	}
	if err := rows.Err(); err != nil {
		return SlackWindow{}, nil, fmt.Errorf("slack window: reading messages: %w", err)
	}
	if !w.Truncated {
		w.SkippedOlder += pendingOlder
		w.BelowFloor += pendingBelow
	}
	return w, owners, nil
}

func finishSlackWindowRow(r slackWindowRow, bot bool, groupNames map[string]string) SlackWindowMessage {
	m := r.msg
	m.At = time.Unix(int64(r.tsUnix), 0)
	m.Author = slackWindowPersonName(r.userName)
	m.ByOwner = r.owner != "" && m.UserID == r.owner
	m.Bot = bot
	m.Text = cutSlackWindowText(m.Text)
	switch m.ChannelType {
	case "dm":
		m.ChannelName = "@" + slackWindowPersonName(r.dmUserName)
	case "group_dm":
		m.ChannelName = groupNames[m.ChannelID]
		if m.ChannelName == "" {
			m.ChannelName = r.channel
		}
	default:
		m.ChannelName = "#" + r.channel
	}
	return m
}

// slackWindowPersonName is display_name, else real_name, else name, else "Someone".
func slackWindowPersonName(names [3]string) string {
	for _, n := range names {
		if n != "" {
			return n
		}
	}
	return "Someone"
}

func cutSlackWindowText(text string) string {
	if utf8.RuneCountInString(text) <= SlackWindowTextRunes {
		return text
	}
	return string([]rune(text)[:SlackWindowTextRunes-1]) + "…"
}

// slackWindowMessageBytes is a row's cost against SlackWindowMaxBytes: the
// JSON-encoded length (quotes and escapes included) of each string value the
// primitive's row shape carries, plus SlackWindowRowOverheadBytes.
func slackWindowMessageBytes(m SlackWindowMessage) int {
	n := SlackWindowRowOverheadBytes
	for _, f := range []string{m.ChannelID, m.ChannelName, m.Author, m.Text, m.ThreadTS, m.Permalink} {
		n += jsonStringBytes(f)
	}
	return n
}

// jsonStringBytes is len(json.Marshal(s)) without the allocation: encoding/json
// escapes " and \ (2 bytes), \n \r \t \b \f (2), other control bytes,
// < > &, U+2028 and U+2029 (6), and writes each invalid UTF-8 byte as a raw
// U+FFFD (3).
func jsonStringBytes(s string) int {
	n := 2
	for i := 0; i < len(s); {
		b := s[i]
		if b < utf8.RuneSelf {
			switch {
			case b == '"' || b == '\\' || b == '\n' || b == '\r' || b == '\t' || b == '\b' || b == '\f':
				n += 2
			case b < 0x20 || b == '<' || b == '>' || b == '&':
				n += 6
			default:
				n++
			}
			i++
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			n += 3 // written as a raw U+FFFD
		case r == '\u2028' || r == '\u2029':
			n += 6
		default:
			n += size
		}
		i += size
	}
	return n
}

// slackWindowGroupDM is a group DM with its members' handles, the owner's left out.
type slackWindowGroupDM struct {
	id      string
	handles []string
}

// slackWindowGroupDMNames names every group DM of an enabled account by its
// members, read from Slack's "mpdm-<handle>--<handle>-<n>" channel name (the
// database keeps no member list): the owner left out, each handle as the
// person's display name, else real name, else the handle; the first three,
// then "+N". A name in any other form is left out of the map.
func slackWindowGroupDMNames(ctx context.Context, tx *sql.Tx) (map[string]string, error) {
	groups, allHandles, err := listSlackWindowGroupDMs(ctx, tx)
	if err != nil || len(groups) == 0 {
		return map[string]string{}, err
	}
	handlesJSON, err := json.Marshal(allHandles)
	if err != nil {
		return nil, fmt.Errorf("slack window: encoding group DM handles: %w", err)
	}
	rows, err := tx.QueryContext(ctx, `SELECT id, name, display_name, real_name FROM users
		WHERE name IN (SELECT value FROM json_each(?))`, string(handlesJSON))
	if err != nil {
		return nil, fmt.Errorf("slack window: reading group DM members: %w", err)
	}
	defer rows.Close()
	people := map[string]string{} // "<account>:<handle>" → name
	for rows.Next() {
		var id, handle, display, realName string
		if err := rows.Scan(&id, &handle, &display, &realName); err != nil {
			return nil, fmt.Errorf("slack window: scanning a group DM member: %w", err)
		}
		acct, _, _ := strings.Cut(id, ":")
		people[acct+":"+handle] = slackWindowPersonName([3]string{display, realName, handle})
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("slack window: reading group DM members: %w", err)
	}

	out := make(map[string]string, len(groups))
	for _, g := range groups {
		acct, _, _ := strings.Cut(g.id, ":")
		names := make([]string, 0, len(g.handles))
		for _, h := range g.handles {
			if n, ok := people[acct+":"+h]; ok {
				names = append(names, n)
			} else {
				names = append(names, h)
			}
		}
		out[g.id] = joinGroupDMNames(names)
	}
	return out, nil
}

// listSlackWindowGroupDMs lists the group DMs in Slack's mpdm name form and
// every handle they hold.
func listSlackWindowGroupDMs(ctx context.Context, tx *sql.Tx) ([]slackWindowGroupDM, []string, error) {
	rows, err := tx.QueryContext(ctx, `SELECT c.id, c.name, COALESCE(ou.name, '')
		FROM channels c
		JOIN slack_accounts sa ON sa.id = CAST(substr(c.id, 1, instr(c.id, ':') - 1) AS INTEGER)
		LEFT JOIN users ou ON ou.id = sa.current_user_id
		WHERE c.type = 'group_dm' AND sa.enabled = 1 AND sa.status NOT IN ('removed', 'purged')`)
	if err != nil {
		return nil, nil, fmt.Errorf("slack window: listing group DMs: %w", err)
	}
	defer rows.Close()
	var groups []slackWindowGroupDM
	var allHandles []string
	for rows.Next() {
		var id, name, ownerHandle string
		if err := rows.Scan(&id, &name, &ownerHandle); err != nil {
			return nil, nil, fmt.Errorf("slack window: scanning a group DM: %w", err)
		}
		handles, ok := mpdmHandles(name)
		if !ok {
			continue
		}
		kept := handles[:0]
		for _, h := range handles {
			if h != ownerHandle {
				kept = append(kept, h)
			}
		}
		groups = append(groups, slackWindowGroupDM{id: id, handles: kept})
		allHandles = append(allHandles, kept...)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("slack window: listing group DMs: %w", err)
	}
	return groups, allHandles, nil
}

// mpdmHandles splits Slack's group DM name "mpdm-a--b--c-1" into its handles.
func mpdmHandles(name string) ([]string, bool) {
	rest, ok := strings.CutPrefix(name, "mpdm-")
	if !ok {
		return nil, false
	}
	if i := strings.LastIndexByte(rest, '-'); i > 0 {
		if _, err := strconv.Atoi(rest[i+1:]); err == nil {
			rest = rest[:i]
		}
	}
	var handles []string
	for _, h := range strings.Split(rest, "--") {
		if h != "" {
			handles = append(handles, h)
		}
	}
	return handles, len(handles) > 0
}

func joinGroupDMNames(names []string) string {
	if len(names) <= 3 {
		return strings.Join(names, ", ")
	}
	return strings.Join(names[:3], ", ") + " +" + strconv.Itoa(len(names)-3)
}

// markSlackWindowToOwner sets ToOwner with the attention detector's rules
// (owner_addressed.go), one query per account over the included rows, plus the
// 1:1 DM rule (another person's message in a DM). owners maps an account to
// its current_user_id; an account with none has no owner to address.
func markSlackWindowToOwner(ctx context.Context, tx *sql.Tx, w *SlackWindow, owners map[string]string) error {
	byAccount := map[string][]int64{}
	index := make(map[int64]int, len(w.Messages))
	for i, m := range w.Messages {
		index[m.RowID] = i
		acct, _, _ := strings.Cut(m.ChannelID, ":")
		byAccount[acct] = append(byAccount[acct], m.RowID)
	}
	for acct, rowIDs := range byAccount {
		owner := owners[acct]
		if owner == "" {
			continue
		}
		addressed, err := slackWindowAddressedRows(ctx, tx, owner, rowIDs)
		if err != nil {
			return err
		}
		for _, id := range addressed {
			w.Messages[index[id]].ToOwner = true
		}
		for _, id := range rowIDs {
			m := &w.Messages[index[id]]
			if m.ChannelType == "dm" && m.UserID != "" && m.UserID != owner {
				m.ToOwner = true
			}
		}
	}
	return nil
}

// slackWindowAddressedRows returns the rowIDs that mention owner, reply in the
// owner's thread or are the owner's reaction requests.
func slackWindowAddressedRows(ctx context.Context, tx *sql.Tx, owner string, rowIDs []int64) ([]int64, error) {
	ids, err := json.Marshal(rowIDs)
	if err != nil {
		return nil, fmt.Errorf("slack window: encoding row ids: %w", err)
	}
	strict, pipe := watchtowerslack.MentionPatterns(owner)
	//nolint:gosec // G202: the concatenated predicates are the package's constant owner_addressed.go SQL; every value is a bound arg.
	rows, err := tx.QueryContext(ctx, `SELECT m.rowid FROM messages m
		WHERE m.rowid IN (SELECT value FROM json_each(?))
		  AND m.user_id != ''
		  AND ((m.user_id != ? AND (`+ownerMentionSQL("m.text")+` OR `+ownerThreadReplySQL("m")+`))
		       OR `+ownerReactionRequestSQL("m")+`)`,
		string(ids), owner, strict, pipe, owner, owner, owner)
	if err != nil {
		return nil, fmt.Errorf("slack window: addressed to the owner: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("slack window: scanning an addressed row: %w", err)
		}
		out = append(out, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("slack window: addressed to the owner: %w", err)
	}
	return out, nil
}

// LastAutomationRunCreatedAt returns when the newest run of automationID with
// the given trigger was queued; statuses narrows it (none = any status).
// ok is false when there is no such run.
func (db *DB) LastAutomationRunCreatedAt(ctx context.Context, automationID int64, trigger string, statuses ...string) (time.Time, bool, error) {
	query := `SELECT queued_at FROM automation_runs WHERE automation_id = ? AND trigger = ?`
	args := []any{automationID, trigger}
	if len(statuses) > 0 {
		query += ` AND status IN (` + placeholders(len(statuses)) + `)`
		for _, s := range statuses {
			args = append(args, s)
		}
	}
	query += ` ORDER BY queued_at DESC, id DESC LIMIT 1`
	var queued string
	err := db.QueryRowContext(ctx, query, args...).Scan(&queued)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("last %s run of automation %d: %w", trigger, automationID, err)
	}
	at, err := time.Parse(automationTimeLayout, queued)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("last %s run of automation %d: queued_at %q: %w", trigger, automationID, queued, err)
	}
	return at, true, nil
}

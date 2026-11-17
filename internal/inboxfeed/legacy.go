package inboxfeed

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// The legacy entries' features (the Mac's ReadinessFeature ids): with both
// off, the root shows no placeholder day card.
const (
	briefingFeatureID = "briefing"
	dayPlanFeatureID  = "day-plan"
)

// dayPage is how many dates the Morning brief reads (ActionStripViewModel.dayPage).
const dayPage = 30

// briefWindow is how long a thread brief stays in the root (ask #609).
const briefWindow = 24 * time.Hour

// ideaFinderBuiltinID is the idea-finder built-in: Idea finder stays in the
// root while it is indexed.
const ideaFinderBuiltinID = "idea-finder"

// legacy is what the root's legacy entries read (InboxFeedSnapshot's legacy
// half).
type legacy struct {
	days          []day
	tracks        []track
	stoppedTracks []track
	ideas         []idea
	ideaFinder    bool
	messages      []message
	briefs        []db.AgentAction
	// placeholder: today's placeholder day card is listed.
	placeholder bool
	today       string
	// openDay is the day the client has open (Options.Day): listed while
	// it has a briefing or a plan.
	openDay    string
	startOfDay time.Time
}

// day is one date of the Morning brief (InboxDayCard).
type day struct {
	Date                string
	HasBriefing, Unread bool
	HasPlan             bool
	PlanDone, PlanTotal int
	Stamp               time.Time
	Attention           []api.LegacyAttention
	PlanItems           []api.LegacyItem
}

type track struct {
	ID             int64
	Text, Priority string
	Unread         bool
	NewEvents      int
	LastEventAt    time.Time
}

type idea struct {
	ID                           int64
	Kind, Status, Title, Essence string
	ChatBorn, AwaitsVerdict      bool
	UpdatedAt                    time.Time
}

type message struct {
	ID                                  int64
	Title, Source, WhyMatters, Priority string
	Unread                              bool
	Stamp                               time.Time
}

// readLegacy reads the legacy entries at now; disabled are the features
// turned off.
func readLegacy(ctx context.Context, tx *sql.Tx, now time.Time, disabled func(string) bool, standIn bool) (legacy, error) {
	var l legacy
	y, m, d := now.Date()
	l.startOfDay = time.Date(y, m, d, 0, 0, 0, 0, now.Location())
	l.today = now.Format("2006-01-02")
	var err error
	if l.days, err = readDays(ctx, tx); err != nil {
		return l, err
	}
	if l.tracks, err = readTracks(ctx, tx, false); err != nil {
		return l, err
	}
	if l.stoppedTracks, err = readTracks(ctx, tx, true); err != nil {
		return l, err
	}
	if l.ideas, err = readIdeas(ctx, tx); err != nil {
		return l, err
	}
	if err = tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM automations WHERE builtin_id = ?)`,
		ideaFinderBuiltinID).Scan(&l.ideaFinder); err != nil {
		return l, fmt.Errorf("inboxfeed: reading the idea finder: %w", err)
	}
	if standIn {
		if l.messages, err = readMessages(ctx, tx, now); err != nil {
			return l, err
		}
	}
	if l.briefs, err = readBriefs(ctx, tx, now); err != nil {
		return l, err
	}
	hasToday := false
	for _, dd := range l.days {
		hasToday = hasToday || dd.Date == l.today
	}
	if (!disabled(briefingFeatureID) || !disabled(dayPlanFeatureID)) && !hasToday {
		known, err := db.OwnerKnownTx(ctx, tx)
		if err != nil {
			return l, err
		}
		l.placeholder = known
	}
	return l, nil
}

// readDays reads the Morning brief's dates (BriefingQueries.fetchDayCards,
// the first page): each date's newest briefing and newest plan with its
// items, newest date first.
func readDays(ctx context.Context, tx *sql.Tx) ([]day, error) {
	var out []day
	err := eachRow(ctx, tx, `SELECT d.date,
			b.id IS NOT NULL, b.read_at IS NULL, COALESCE(b.created_at, ''), COALESCE(b.attention, '[]'),
			p.id, COALESCE(p.generated_at, '')
		FROM (SELECT date FROM briefings UNION SELECT plan_date FROM day_plans ORDER BY date DESC LIMIT ?) d
		LEFT JOIN (SELECT *, ROW_NUMBER() OVER (PARTITION BY date ORDER BY created_at DESC, id DESC) AS pick
			FROM briefings) b ON b.date = d.date AND b.pick = 1
		LEFT JOIN (SELECT *, ROW_NUMBER() OVER (PARTITION BY plan_date ORDER BY id DESC) AS pick
			FROM day_plans) p ON p.plan_date = d.date AND p.pick = 1
		ORDER BY d.date DESC`, []any{dayPage}, func(rows *sql.Rows) error {
		var dd day
		var created, attention, generated string
		var plan sql.NullInt64
		if err := rows.Scan(&dd.Date, &dd.HasBriefing, &dd.Unread, &created, &attention, &plan, &generated); err != nil {
			return err
		}
		dd.Unread = dd.HasBriefing && dd.Unread
		dd.HasPlan = plan.Valid
		dd.Stamp = time.Unix(0, 0).UTC()
		switch {
		case dd.HasBriefing && !parseStamp(created).IsZero():
			dd.Stamp = parseStamp(created)
		case dd.HasPlan && !parseStamp(generated).IsZero():
			dd.Stamp = parseStamp(generated)
		}
		dd.Attention = attentionOf(attention, dd.HasBriefing)
		if plan.Valid {
			dd.PlanItems = []api.LegacyItem{{ID: plan.Int64}} // the plan id, replaced below
		}
		out = append(out, dd)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the Morning brief: %w", err)
	}
	for i := range out {
		if !out[i].HasPlan {
			continue
		}
		planID := out[i].PlanItems[0].ID
		out[i].PlanItems = []api.LegacyItem{}
		// DayPlanQueries.fetchItems' order: the time blocks, then the backlog.
		err := eachRow(ctx, tx, `SELECT id, title, COALESCE(start_time, ''), COALESCE(end_time, ''), status = 'done',
				COALESCE(priority, '')
			FROM day_plan_items WHERE day_plan_id = ?
			ORDER BY CASE kind WHEN 'timeblock' THEN 0 ELSE 1 END, order_index, id`, []any{planID},
			func(rows *sql.Rows) error {
				it := api.LegacyItem{RefKind: api.RefPlanItem, Date: out[i].Date}
				var priority, start, end string
				if err := rows.Scan(&it.ID, &it.Title, &start, &end, &it.Done, &priority); err != nil {
					return err
				}
				// A time block's start and end; the screen models draw the
				// range in the client's zone.
				if at := parseStamp(start); !at.IsZero() {
					it.Stamp = formatStamp(at)
				}
				if at := parseStamp(end); !at.IsZero() {
					it.End = formatStamp(at)
				}
				it.High = priority == "high"
				out[i].PlanTotal++
				if it.Done {
					out[i].PlanDone++
				}
				out[i].PlanItems = append(out[i].PlanItems, it)
				return nil
			})
		if err != nil {
			return nil, fmt.Errorf("inboxfeed: reading the day plan of %s: %w", out[i].Date, err)
		}
	}
	return out, nil
}

// attentionOf is a briefing's attention items (Briefing.parsedAttention):
// none when the column is not a list of items with a text.
func attentionOf(raw string, has bool) []api.LegacyAttention {
	out := []api.LegacyAttention{}
	if !has {
		return out
	}
	var items []struct {
		Text       *string `json:"text"`
		Reason     string  `json:"reason"`
		Priority   string  `json:"priority"`
		SourceType string  `json:"source_type"`
		SourceID   string  `json:"source_id"`
	}
	if json.Unmarshal([]byte(raw), &items) != nil {
		return out
	}
	for _, it := range items {
		if it.Text == nil {
			return []api.LegacyAttention{}
		}
		out = append(out, api.LegacyAttention{Text: *it.Text, Reason: it.Reason, Priority: it.Priority,
			SourceType: it.SourceType, SourceID: it.SourceID})
	}
	return out
}

// readTracks reads Track my threads' tracks (TrackQueries.fetchInboxCards):
// the active ones, or the stopped (dismissed) ones newest stop first.
func readTracks(ctx context.Context, tx *sql.Tx, stopped bool) ([]track, error) {
	filter, order := "t.dismissed_at = ''", "t.has_updates DESC, t.updated_at DESC, t.id DESC"
	if stopped {
		filter, order = "t.dismissed_at != ''", "t.dismissed_at DESC, t.id DESC"
	}
	var out []track
	err := eachRow(ctx, tx, `SELECT t.id, t.text, t.priority, t.read_at IS NOT NULL AND t.has_updates = 0, t.updated_at,
			COALESCE((SELECT MAX(e.created_at) FROM track_events e WHERE e.track_id = t.id), ''),
			(SELECT COUNT(*) FROM track_events e WHERE e.track_id = t.id AND (e.read_at IS NULL OR e.read_at = ''))
		FROM tracks t WHERE `+filter+` ORDER BY `+order, nil, func(rows *sql.Rows) error {
		var t track
		var read bool
		var updated, event string
		if err := rows.Scan(&t.ID, &t.Text, &t.Priority, &read, &updated, &event, &t.NewEvents); err != nil {
			return err
		}
		t.Unread = !read || t.NewEvents > 0
		t.LastEventAt = time.Unix(0, 0).UTC()
		for _, at := range []time.Time{parseStamp(updated), parseStamp(event)} {
			if !at.IsZero() && at.After(t.LastEventAt) {
				t.LastEventAt = at
			}
		}
		out = append(out, t)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the tracks: %w", err)
	}
	return out, nil
}

// readIdeas reads Idea finder's registry (IdeaQueries.fetchInboxRegistry).
func readIdeas(ctx context.Context, tx *sql.Tx) ([]idea, error) {
	var out []idea
	err := eachRow(ctx, tx, `SELECT id, kind, status, title, essence, chat_born, updated_at,
			(status = 'proposed' OR needs_review = 1) AND (kind != 'decision' OR chat_born = 1)
		FROM ideas WHERE kind IN ('idea', 'note', 'decision') AND status != 'merged'
		ORDER BY updated_at DESC, id DESC`, nil, func(rows *sql.Rows) error {
		var i idea
		var updated string
		if err := rows.Scan(&i.ID, &i.Kind, &i.Status, &i.Title, &i.Essence, &i.ChatBorn, &updated,
			&i.AwaitsVerdict); err != nil {
			return err
		}
		i.UpdatedAt = parseStamp(updated)
		out = append(out, i)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the ideas: %w", err)
	}
	return out, nil
}

// readMessages reads the Messages entry's open messages
// (InboxQueries.fetchOpenMessages) with each row's words (InboxListRow:
// messageTitle, messageSource without its time).
func readMessages(ctx context.Context, tx *sql.Tx, now time.Time) ([]message, error) {
	items, err := db.OpenInboxItemsTx(ctx, tx, now, openMessageLimit)
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: %w", err)
	}
	out := make([]message, 0, len(items))
	for _, it := range items {
		mentions, _ := db.ParseInboxMentions(it.Mentions)
		accumulated := len(mentions)+it.MentionsEarlier > 1
		m := message{ID: int64(it.ID), WhyMatters: it.WhyMatters, Priority: it.Priority, Unread: it.ReadAt == ""}
		m.Stamp = parseStamp(it.At)
		if m.Stamp.IsZero() {
			m.Stamp = now.UTC()
		}
		m.Title = messageTitle(it.InboxItem, mentions, accumulated)
		who := it.SenderName
		switch {
		case strings.HasPrefix(it.TriggerType, "jira_") || strings.HasPrefix(it.TriggerType, "linear_"):
			who = it.ChannelID
		case it.TriggerType == "email_received":
			who = it.SenderUserID
		case accumulated:
			names, err := userNames(ctx, tx, mentions)
			if err != nil {
				return nil, err
			}
			who = db.InboxMentionSenders(mentions, names)
		}
		var parts []string
		for _, p := range []string{who, messageWhere(it)} {
			if p != "" {
				parts = append(parts, p)
			}
		}
		m.Source = strings.Join(parts, " · ")
		if m.Source == "" {
			m.Source = "Message"
		}
		out = append(out, m)
	}
	return out, nil
}

// messageTitle is InboxListRow.messageTitle: a folded item's count, else
// its text's first line (a mail's without its subject).
func messageTitle(it db.InboxItem, mentions []db.InboxMention, accumulated bool) string {
	if accumulated {
		return db.InboxMentionCountLabel(mentions, it.MentionsEarlier)
	}
	text := it.Snippet
	if it.TriggerType == "email_received" {
		if _, after, ok := strings.Cut(text, " — "); ok {
			text = after
		}
	}
	// Swift's split(whereSeparator: \.isNewline) drops empty lines.
	lines := strings.FieldsFunc(text, func(r rune) bool {
		switch r {
		case '\n', '\r', '\v', '\f', 0x85, 0x2028, 0x2029:
			return true
		}
		return false
	})
	if len(lines) == 0 || lines[0] == "" {
		return "Message"
	}
	return lines[0]
}

// messageWhere is HomeFeedQueries.whereText.
func messageWhere(it db.OpenInboxItem) string {
	switch it.TriggerType {
	case "jira_assigned", "linear_assigned":
		return "assigned to you"
	case "jira_comment_mention", "linear_comment_mention":
		return "mentioned you"
	case "email_received":
		subject, _, _ := strings.Cut(it.Snippet, " — ")
		return subject
	case "mention", "thread_reply", "reaction":
		if it.ChannelName != "" {
			return "#" + it.ChannelName
		}
	}
	return ""
}

// userNames are the best names of mentions' senders that have a user row.
func userNames(ctx context.Context, tx *sql.Tx, mentions []db.InboxMention) (map[string]string, error) {
	names := map[string]string{}
	for _, m := range mentions {
		if _, ok := names[m.SenderID]; ok {
			continue
		}
		var name string
		err := tx.QueryRowContext(ctx, `SELECT COALESCE(NULLIF(display_name, ''), NULLIF(real_name, ''), NULLIF(name, ''), id)
			FROM users WHERE id = ?`, m.SenderID).Scan(&name)
		if err != nil && err != sql.ErrNoRows {
			return nil, fmt.Errorf("inboxfeed: reading a sender's name: %w", err)
		}
		names[m.SenderID] = name
	}
	return names, nil
}

// readBriefs reads the thread briefs applied in the last 24 hours, newest
// first (AgentActionQueries.fetchExecutedBriefs).
func readBriefs(ctx context.Context, tx *sql.Tx, now time.Time) ([]db.AgentAction, error) {
	var out []db.AgentAction
	since := now.Add(-briefWindow).UTC().Format(stampLayout)
	err := eachRow(ctx, tx, `SELECT `+db.AgentActionColumns+` FROM agent_actions
		WHERE tool = ? AND status = 'applied' AND applied_at >= ?
		  AND (context_type IS NOT 'project' OR external = 1) AND NOT (surface = 'inbox' AND tool = 'apply_track_action')
		ORDER BY applied_at DESC, id DESC`, []any{toolBriefContext, since}, func(rows *sql.Rows) error {
		a, err := db.ScanAgentAction(rows)
		if err != nil {
			return err
		}
		out = append(out, *a)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the thread briefs: %w", err)
	}
	return out, nil
}

// timedCard is a root card with the time the root orders it by.
type timedCard struct {
	at   time.Time
	card api.Card
}

// legacyCards are the root's legacy entries with their own times
// (InboxFolderEntries.legacy): a card per Morning brief day (today's and
// every unread one, and today's placeholder), Track my threads while a
// track exists (stopped ones included), Idea finder while an idea exists
// or its built-in is indexed, Messages while it stands in for Waiting for
// me and has a message, and each thread brief applied in the last 24
// hours at its own applied time (the Mac lists each as a root entry).
func (s *snapshot) legacyCards(folder int64) []timedCard {
	l := s.legacy
	var out []timedCard
	for _, d := range l.rootDays() {
		out = append(out, timedCard{d.Stamp, dayCard(d, l.today, folder)})
	}
	if c, at, ok := tracksCard(l, folder); ok {
		out = append(out, timedCard{at, c})
	}
	if len(l.ideas) > 0 || l.ideaFinder {
		c, at := ideasCard(l, folder)
		out = append(out, timedCard{at, c})
	}
	if s.waitingForMe.standIn && len(l.messages) > 0 {
		c, at := messagesCard(l, folder, s.refState)
		out = append(out, timedCard{at, c})
	}
	for _, b := range l.briefs {
		c, at := threadBriefCard(b, folder)
		out = append(out, timedCard{at, c})
	}
	return out
}

// rootDays are InboxListBuilder.rootDays: today's and every unread day,
// plus today's placeholder, newest first.
func (l legacy) rootDays() []day {
	var out []day
	for _, d := range l.days {
		if d.Date == l.today || d.Unread || d.Date == l.openDay {
			out = append(out, d)
		}
	}
	if l.placeholder {
		out = append(out, day{Date: l.today, Stamp: l.startOfDay})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Stamp.After(out[j].Stamp) })
	return out
}

func legacyCard(id string, folder int64, title, source, preview string, at time.Time, unread bool,
	section api.LegacySection,
) api.Card {
	if section.Items == nil {
		section.Items = []api.LegacyItem{}
	}
	if section.Attention == nil {
		section.Attention = []api.LegacyAttention{}
	}
	return api.Card{ID: id, FolderID: folder, CardKind: api.CardLegacy, Title: title, SourceLine: source,
		Preview: preview, Stamp: formatStamp(at), Unread: unread, Priority: "medium",
		Actions: []api.CardAction{}, RefFacts: []api.RefFacts{}, Legacy: &section}
}

// dayCard is a Morning brief day (InboxFolderEntries.row's legacyDay):
// "Morning brief", "today" on today's, "Your day · Wed 22 Oct"; its plan
// items and attention list.
func dayCard(d day, today string, folder int64) api.Card {
	preview := ""
	if d.Date == today {
		preview = "today"
	}
	source := "Your day · " + d.Date
	if t, err := time.Parse("2006-01-02", d.Date); err == nil {
		source = "Your day · " + t.Format("Mon 2 Jan")
	}
	return legacyCard(BriefCardID(d.Date), folder, "Morning brief", source, preview, d.Stamp, d.Unread,
		api.LegacySection{Kind: api.LegacyMorningBrief, Items: d.PlanItems, Attention: d.Attention})
}

// tracksCard is Track my threads: "N unread" over the active tracks, its
// time the newest track's (stopped ones included); the active tracks
// newest first, then the stopped ones flagged.
func tracksCard(l legacy, folder int64) (api.Card, time.Time, bool) {
	if len(l.tracks)+len(l.stoppedTracks) == 0 {
		return api.Card{}, time.Time{}, false
	}
	var at time.Time
	unread := 0
	active := append([]track{}, l.tracks...)
	for _, t := range append(append([]track{}, l.tracks...), l.stoppedTracks...) {
		if t.LastEventAt.After(at) {
			at = t.LastEventAt
		}
	}
	for _, t := range l.tracks {
		if t.Unread {
			unread++
		}
	}
	sort.SliceStable(active, func(i, j int) bool {
		if !active[i].LastEventAt.Equal(active[j].LastEventAt) {
			return active[i].LastEventAt.After(active[j].LastEventAt)
		}
		return active[i].ID < active[j].ID
	})
	items := make([]api.LegacyItem, 0, len(l.tracks)+len(l.stoppedTracks))
	for _, t := range active {
		items = append(items, trackItem(t, false))
	}
	for _, t := range l.stoppedTracks {
		items = append(items, trackItem(t, true))
	}
	return legacyCard(TracksCardID, folder, "Track my threads", "", countLine(unread, "unread"), at, unread > 0,
		api.LegacySection{Kind: api.LegacyTracks, Items: items}), at, true
}

func trackItem(t track, stopped bool) api.LegacyItem {
	preview := ""
	if t.NewEvents > 0 {
		preview = strconv.Itoa(t.NewEvents) + " new"
	}
	return api.LegacyItem{RefKind: api.RefTrack, ID: t.ID, Title: t.Text, Subtitle: "Track", Preview: preview,
		Stamp: formatStamp(t.LastEventAt), Unread: t.Unread, High: t.Priority == "high", Stopped: stopped}
}

// ideasCard is Idea finder: "N to judge", its time the newest idea's; the
// ideas awaiting a verdict first, then the rest newest first.
func ideasCard(l legacy, folder int64) (api.Card, time.Time) {
	var at time.Time
	var decide, rest []idea
	for _, i := range l.ideas {
		if i.UpdatedAt.After(at) {
			at = i.UpdatedAt
		}
		if i.AwaitsVerdict {
			decide = append(decide, i)
		} else {
			rest = append(rest, i)
		}
	}
	sort.SliceStable(rest, func(a, b int) bool {
		if !rest[a].UpdatedAt.Equal(rest[b].UpdatedAt) {
			return rest[a].UpdatedAt.After(rest[b].UpdatedAt)
		}
		return rest[a].ID < rest[b].ID
	})
	items := make([]api.LegacyItem, 0, len(l.ideas))
	for _, i := range append(decide, rest...) {
		items = append(items, api.LegacyItem{RefKind: api.RefIdea, ID: i.ID, Title: i.Title, Subtitle: ideaSource(i),
			Preview: i.Essence, Stamp: formatStamp(i.UpdatedAt), Unread: i.AwaitsVerdict})
	}
	return legacyCard(IdeasCardID, folder, "Idea finder", "", countLine(len(decide), "to judge"), at, len(decide) > 0,
		api.LegacySection{Kind: api.LegacyIdeas, Items: items}), at
}

// ideaSource is InboxListRow.ideaSource: "Idea · proposed", "Decision ·
// not now", "… · Chat" for one born in a chat.
func ideaSource(i idea) string {
	kind := i.Kind
	if kind != "" {
		kind = strings.ToUpper(kind[:1]) + kind[1:]
	}
	line := kind + " · " + strings.ReplaceAll(i.Status, "_", " ")
	if i.ChatBorn {
		return line + " · Chat"
	}
	return line
}

// messagesCard is the Messages entry: "N waiting", "Mentions, DMs and
// replies", unread while one message is; its time the newest message's;
// the messages newest first.
func messagesCard(l legacy, folder int64, st refState) (api.Card, time.Time) {
	msgs := append([]message{}, l.messages...)
	var at time.Time
	unread := false
	for _, m := range msgs {
		if m.Stamp.After(at) {
			at = m.Stamp
		}
		unread = unread || m.Unread
	}
	sort.SliceStable(msgs, func(i, j int) bool {
		if !msgs[i].Stamp.Equal(msgs[j].Stamp) {
			return msgs[i].Stamp.After(msgs[j].Stamp)
		}
		return msgs[i].ID < msgs[j].ID
	})
	items := make([]api.LegacyItem, 0, len(msgs))
	refs := make([]ref, 0, len(msgs))
	for _, m := range msgs {
		items = append(items, api.LegacyItem{RefKind: api.RefInboxItem, ID: m.ID, Title: m.Title, Subtitle: m.Source,
			Preview: m.WhyMatters, Stamp: formatStamp(m.Stamp), Unread: m.Unread, High: m.Priority == "high"})
		refs = append(refs, ref{Kind: api.RefInboxItem, ID: m.ID})
	}
	card := legacyCard(MessagesCardID, folder, "Messages", "Mentions, DMs and replies",
		strconv.Itoa(len(msgs))+" waiting", at, unread, api.LegacySection{Kind: api.LegacyMessages, Items: items})
	// Each item's facts, in item order: the Mac's Reply… reads them, as on an artifact's rows.
	card.RefFacts = st.refFacts(refs)
	return card, at
}

// threadBriefCard is one brief the `:brief:` reaction made in the last 24
// hours (InboxFolderEntries.row's brief): titled by its reason ("Thread
// brief" without one), a result — never unread, never counted — at its
// applied time, with the brief as its one legacy item.
func threadBriefCard(b db.AgentAction, folder int64) (api.Card, time.Time) {
	applied := parseStamp(b.AppliedAt)
	title := b.Reason
	if title == "" {
		title = "Thread brief"
	}
	item := api.LegacyItem{RefKind: api.RefAction, ID: b.ID, Title: title, Subtitle: "Thread brief",
		Preview: strings.Join(summaryLines(b.Tool, jsonObject(b.ArgsJSON), b.ArgsJSON, jsonObject(b.ResultJSON)), "\n"),
		Stamp:   formatStamp(applied)}
	return legacyCard(ThreadBriefCardID(b.ID), folder, title, "Thread brief", "", applied, false,
		api.LegacySection{Kind: api.LegacyThreadBriefs, Items: []api.LegacyItem{item}}), applied
}

// countLine is "<n> <what>", or "" for none.
func countLine(n int, what string) string {
	if n == 0 {
		return ""
	}
	return strconv.Itoa(n) + " " + what
}

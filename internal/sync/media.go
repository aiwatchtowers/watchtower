package sync

import (
	"cmp"
	"context"
	"database/sql"
	"strings"
	"time"

	goslack "github.com/slack-go/slack"

	"watchtower/internal/db"
	"watchtower/internal/media"
	"watchtower/internal/media/linkrule"
	watchtowerslack "watchtower/internal/slack"
)

// maxSlackFileLookups bounds the conversations.history / conversations.replies
// calls one account's cycle spends on search matches that shared a file but came without it.
const maxSlackFileLookups = 20

// Media kinds a Slack message's re-upsert replaces.
var (
	slackReplaceAll   = []string{"image", "link"}
	slackReplaceLinks = []string{"link"}
)

// slackMediaPlan is what discovery reads once per Run (or backfill chunk):
// the refused-host set links are checked against and media_state.start_at.
type slackMediaPlan struct {
	refused map[string]bool
	start   time.Time
}

// resetMediaPlan makes the next mediaPlan call read the plan afresh; Run and
// BackfillSearch call it first.
func (o *Orchestrator) resetMediaPlan() {
	o.planMu.Lock()
	defer o.planMu.Unlock()
	o.plan, o.planRead = nil, false
}

// mediaPlan returns the plan, read on the first call after resetMediaPlan
// and reused by every later page and thread of the run; nil (logged once)
// when it cannot be read, and the run then records no media at all.
func (o *Orchestrator) mediaPlan(ctx context.Context) *slackMediaPlan {
	o.planMu.Lock()
	defer o.planMu.Unlock()
	if o.planRead {
		return o.plan
	}
	o.planRead = true
	start, err := o.db.MediaStartAt()
	if err != nil {
		o.logger.Printf("warning: media discovery skipped for this sync: %v", err)
		return nil
	}
	refused, err := media.RefusedHosts(ctx, o.db, media.DenyHosts(o.config))
	if err != nil {
		o.logger.Printf("warning: media discovery skipped for this sync: %v", err)
		return nil
	}
	o.plan = &slackMediaPlan{refused: refused, start: start}
	return o.plan
}

// isNew reports a message at ts recent enough to record media for; false for
// a ts that does not parse.
func (p *slackMediaPlan) isNew(ts string) bool {
	at, err := parseSlackTS(ts)
	return err == nil && !at.Before(p.start)
}

// slackMediaFound returns the images and links of one Slack message: image
// files (locator = file id; an external or non-hosted file is recorded
// skipped_type with no URL, so it is never downloaded) and the message's
// links that Fetchable accepts (locator and content key url:<normalized>).
// A Slack tombstone has none.
func slackMediaFound(text, subtype string, files []goslack.File, refused map[string]bool) []db.MediaFound {
	if subtype == "tombstone" {
		return nil
	}
	var out []db.MediaFound
	seen := map[string]bool{}
	for _, f := range files {
		if f.ID == "" || seen[f.ID] || !strings.HasPrefix(strings.ToLower(f.Mimetype), "image/") {
			continue
		}
		seen[f.ID] = true
		mf := db.MediaFound{Kind: "image", Locator: f.ID, Name: f.Name, MediaType: f.Mimetype, Size: int64(f.Size)}
		if f.IsExternal || f.Mode != "hosted" {
			mf.Status = "skipped_type"
		} else {
			mf.FetchURL = cmp.Or(f.URLPrivateDownload, f.URLPrivate)
		}
		out = append(out, mf)
	}
	for _, raw := range linkrule.SlackLinks(text) {
		norm, ok := linkrule.Fetchable(raw, refused)
		if !ok || seen["url:"+norm] {
			continue
		}
		loc := "url:" + norm
		seen[loc] = true
		out = append(out, db.MediaFound{Kind: "link", Locator: loc, ContentKey: loc})
	}
	return out
}

// slackMediaWrite is one message's media for its writer's transaction.
type slackMediaWrite struct {
	channelID, ts, user string // channel and user namespaced
	found               []db.MediaFound
	replace             []string
}

// recordSlackMedia records w in tx. Media is derived data: a failure is
// logged and the page's messages commit as usual.
func (o *Orchestrator) recordSlackMedia(ctx context.Context, tx *sql.Tx, w slackMediaWrite) {
	at, err := parseSlackTS(w.ts)
	if err != nil {
		o.logger.Printf("warning: media of %s not recorded: %v", w.channelID, err)
		return
	}
	p := db.MediaParent{
		Kind: "slack", SlackChannelID: w.channelID, SlackTS: w.ts, ContentAt: at,
		FromOwner: w.user != "" && w.user == o.account.CurrentUserID,
	}
	if _, err := db.RecordMedia(ctx, tx, p, w.found, w.replace...); err != nil {
		o.logger.Printf("warning: recording media of %s/%s: %v", w.channelID, w.ts, err)
	}
}

// slackFileLookup is a search match that shared a file without listing it.
// threadTS is the thread a reply belongs to ("" for a top-level message).
type slackFileLookup struct{ channelID, ts, threadTS string } // channel namespaced

// needsFileLookup reports a search match that shared a file but came
// without its files: only history lists them.
func needsFileLookup(m watchtowerslack.SearchMatch) bool {
	return len(m.Files) == 0 && m.Subtype != "tombstone" && (m.Upload || m.Subtype == "file_share")
}

// lookUpFileShares fetches each message — a thread reply through
// conversations.replies of its thread, any other through
// conversations.history — and saves it on the history path, which records
// its files. At most maxSlackFileLookups per cycle; a failed lookup is
// logged and skipped, and a rate limit ends the lookups for the cycle.
func (o *Orchestrator) lookUpFileShares(ctx context.Context, lookups []slackFileLookup) {
	for _, l := range lookups {
		if ctx.Err() != nil || o.fileLookups >= maxSlackFileLookups {
			return
		}
		o.fileLookups++
		msgs, err := o.fetchFileShare(ctx, l)
		if err != nil {
			o.logger.Printf("warning: looking up the files of %s/%s: %v", l.channelID, l.ts, err)
			if isRateLimitError(err) {
				return
			}
			continue
		}
		for _, m := range msgs {
			if m.Timestamp != l.ts {
				continue
			}
			if _, err := o.upsertMessagePage(ctx, l.channelID, []goslack.Message{m}); err != nil {
				o.logger.Printf("warning: saving the files of %s/%s: %v", l.channelID, l.ts, err)
			}
			break
		}
	}
}

// fetchFileShare reads the messages that hold l: its thread for a reply
// (history never lists replies), else the one history entry at its ts.
func (o *Orchestrator) fetchFileShare(ctx context.Context, l slackFileLookup) ([]goslack.Message, error) {
	_, rawID, _ := watchtowerslack.SplitAccountID(l.channelID)
	if l.threadTS != "" && l.threadTS != l.ts {
		return o.slackClient.GetConversationReplies(ctx, rawID, l.threadTS)
	}
	resp, err := o.slackClient.GetConversationHistory(ctx, watchtowerslack.HistoryOptions{
		ChannelID: rawID, Oldest: l.ts, Latest: l.ts, Limit: 1, Inclusive: true,
	})
	if err != nil {
		return nil, err
	}
	return resp.Messages, nil
}

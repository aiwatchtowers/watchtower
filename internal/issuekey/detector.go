// Package issuekey is the tracker-neutral issue-key detector (spec
// 2026-10-15-linear-integration-design §4.3): it finds "ABC-123" keys in
// Slack messages, tracks and digest decisions and links each to the tracker
// that owns its prefix — a known Jira project key or a known Linear team key —
// in issue_slack_links. A prefix known to both trackers writes one link per
// tracker; readers that need one issue resolve the ambiguity themselves.
//
// It imports no AI, sync-engine or connector package (EXT-04): only the
// dependency-free internal/jirakey pattern, config and db.
package issuekey

import (
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jirakey"
)

// knownKeysTTL bounds how long a daemon-lifetime KeyDetector can serve a stale
// known-key set. A tray-launched daemon runs for weeks; without this, a project
// or team connected (or a new project's first issue synced) after the set first
// populated would never get its keys linked from Slack messages, digests or
// tracks until the daemon restarted — ResetCache exists for that same purpose
// but has no production caller. A tracker sync cycle is on the order of
// minutes, so an hour keeps the reload rare while bounding the staleness
// window well below "for weeks."
const knownKeysTTL = time.Hour

// Trackers, in the order a prefix known to both writes its links.
const (
	trackerJira   = "jira"
	trackerLinear = "linear"
)

// KeyDetector detects issue keys in text and links them to Slack messages,
// tracks and digest decisions.
type KeyDetector struct {
	db        *db.DB
	logger    *log.Logger
	knownKeys map[string][]string // prefix -> trackers that own it
	loadedAt  time.Time
	mu        sync.RWMutex

	// now is the clock knownPrefixes reads to decide staleness; nil means
	// time.Now (a test injects a fake to cross the TTL without a real hour's
	// wait — the internal/sync Orchestrator.now precedent).
	now func() time.Time
}

// NewKeyDetector creates a new KeyDetector.
func NewKeyDetector(database *db.DB) *KeyDetector {
	return &KeyDetector{
		db:     database,
		logger: log.New(os.Stderr, "[issue-keys] ", log.LstdFlags),
	}
}

// clockNow returns the detector's clock (time.Now unless a test overrides now).
func (d *KeyDetector) clockNow() time.Time {
	if d.now != nil {
		return d.now()
	}
	return time.Now()
}

// SetLogger replaces the detector's logger.
func (d *KeyDetector) SetLogger(l *log.Logger) {
	d.logger = l
}

// NewKeyDetectorIfEnabled returns a detector for the pipelines and the sync
// orchestrators to hook, or nil when this install has no issue tracker. It is
// the ONE place the gate is expressed, so a new call site cannot accidentally
// invent a different one.
//
// The gate is cfg.Jira.Enabled || cfg.Linear.Enabled and nothing else. Both are
// false by default and flipped true by `jira add`/`jira login` and `linear
// add`, so the detector runs on exactly the installs that have a tracker
// connected — which is also the only state in which a key prefix can be known.
// Deliberately NOT one of the jira.features.* toggles: this step collects the
// data every tracker surface reads (--jira/--no-jira, the Desktop "Linked Jira
// Issues" badges, get_task_context, find_experts, who-to-ping), and putting it
// behind a per-feature toggle would hide a data-collection step from the owner.
//
// Callers must nil-check rather than pass the result straight to a
// Set…Detector: a typed nil stored in an interface field is not nil.
func NewKeyDetectorIfEnabled(cfg *config.Config, database *db.DB) *KeyDetector {
	if !cfg.Jira.Enabled && !cfg.Linear.Enabled {
		return nil
	}
	return NewKeyDetector(database)
}

// hit is one detected key and the tracker it is linked to.
type hit struct {
	tracker string
	key     string
}

// detect finds every key in text whose prefix a tracker owns, one hit per
// (key, tracker), in text order.
//
// A token is an issue key only if its prefix is one this workspace actually
// synced: unknown means no. Without that rule an empty key set turned every
// [A-Z][A-Z0-9_]+-\d+ token into a "Jira key" — UTF-8, COVID-19, SHA-256,
// RFC-9728 — and wrote it into the links table, which feeds AI prompts, the
// Desktop and the get_task_context dev surface.
func detect(known map[string][]string, text string) []hit {
	if len(known) == 0 {
		return nil
	}
	matches := jirakey.KeyRegexp.FindAllString(text, -1)
	if len(matches) == 0 {
		return nil
	}
	seen := make(map[string]bool)
	var out []hit
	for _, m := range matches {
		if seen[m] {
			continue
		}
		seen[m] = true
		for _, tracker := range known[extractProjectKey(m)] {
			out = append(out, hit{tracker: tracker, key: m})
		}
	}
	return out
}

// DetectKeys finds all issue keys in text whose prefix is a known Jira project
// key or Linear team key, each key once.
func (d *KeyDetector) DetectKeys(text string) []string {
	var result []string
	seen := map[string]bool{}
	for _, h := range detect(d.knownPrefixes(), text) {
		if !seen[h.key] {
			seen[h.key] = true
			result = append(result, h.key)
		}
	}
	return result
}

// knownPrefixes returns the cached prefix set, loading it when the cache is
// still empty or has gone past knownKeysTTL. Only a non-empty result is ever
// memoized: a daemon that starts before the first tracker sync would otherwise
// cache the empty set for its whole lifetime and never detect a key again.
// Reloading is a few SELECT DISTINCTs over small tables. A load error leaves
// whatever was cached before untouched (nil if nothing ever loaded
// successfully, or the previous — now stale — set on a TTL-triggered reload
// that failed) rather than wiping a good set on a transient DB hiccup; unknown
// still means no, never yes.
func (d *KeyDetector) knownPrefixes() map[string][]string {
	d.mu.RLock()
	known := d.knownKeys
	fresh := len(known) > 0 && d.clockNow().Sub(d.loadedAt) < knownKeysTTL
	d.mu.RUnlock()
	if fresh {
		return known
	}

	if err := d.refreshKnownKeys(); err != nil {
		d.logger.Printf("failed to load known issue-key prefixes: %v", err)
		return known
	}

	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.knownKeys
}

// links turns hits into links of one kind via mk.
func links(hits []hit, mk func(tracker, key string) db.IssueSlackLink) []db.IssueSlackLink {
	out := make([]db.IssueSlackLink, 0, len(hits))
	for _, h := range hits {
		out = append(out, mk(h.tracker, h.key))
	}
	return out
}

// upsertEach writes links one by one (the track/decision/single-message
// paths, a handful of keys each) and returns how many it wrote.
func (d *KeyDetector) upsertEach(ls []db.IssueSlackLink) (int, error) {
	for _, l := range ls {
		if err := d.db.UpsertIssueSlackLink(l); err != nil {
			return 0, err
		}
	}
	return len(ls), nil
}

// ProcessMessage detects issue keys in a Slack message and records links.
func (d *KeyDetector) ProcessMessage(channelID, messageTS, text string) (int, error) {
	return d.upsertEach(links(detect(d.knownPrefixes(), text), func(tracker, key string) db.IssueSlackLink {
		return db.IssueSlackLink{Tracker: tracker, IssueKey: key, ChannelID: channelID, MessageTS: messageTS, LinkType: "mention"}
	}))
}

// ProcessMessageBatch detects issue keys across a page of synced Slack
// messages and records every resulting mention link in ONE transaction.
//
// ProcessMessage runs one Exec per detected key outside any transaction, which
// is fine for a handful of calls but not on the message-sync path: a page holds
// up to 200 messages and the DB runs with SetMaxOpenConns(1), so each of those
// writes would serialise against the sync's own. Nothing else differs — the
// links written are exactly what ProcessMessage would write per message.
//
// msgs carry the values already destined for the messages table, so a link's
// (channel_id, message_ts) pair is by construction the same namespaced channel
// id and raw Slack timestamp that messages.(channel_id, ts) holds — which is
// what every reader of a mention link joins back against.
func (d *KeyDetector) ProcessMessageBatch(msgs []db.Message) (int, error) {
	// One key-set load per page rather than one per candidate message: while
	// the set is empty it is deliberately not memoized (see knownPrefixes), so
	// every message carrying a candidate token would otherwise re-run the query.
	known := d.knownPrefixes()
	if len(known) == 0 {
		return 0, nil
	}

	var all []db.IssueSlackLink
	for _, msg := range msgs {
		all = append(all, links(detect(known, msg.Text), func(tracker, key string) db.IssueSlackLink {
			return db.IssueSlackLink{Tracker: tracker, IssueKey: key, ChannelID: msg.ChannelID, MessageTS: msg.TS, LinkType: "mention"}
		})...)
	}
	if len(all) == 0 {
		return 0, nil
	}

	tx, err := d.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("beginning issue slack link transaction: %w", err)
	}
	defer tx.Rollback()

	if err := d.db.UpsertIssueSlackLinkBatch(tx, all); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing issue slack links: %w", err)
	}
	return len(all), nil
}

// ProcessTrack detects issue keys in track text and source refs.
func (d *KeyDetector) ProcessTrack(trackID int, text string, sourceRefs string, channelIDs string) (int, error) {
	// Extract first channel ID from JSON array for link context.
	channelID := extractFirstFromJSONArray(channelIDs)
	tid := trackID
	return d.upsertEach(links(detect(d.knownPrefixes(), text+" "+sourceRefs), func(tracker, key string) db.IssueSlackLink {
		return db.IssueSlackLink{Tracker: tracker, IssueKey: key, ChannelID: channelID, TrackID: &tid, LinkType: "track"}
	}))
}

// ProcessDigestDecision detects issue keys in a digest decision.
func (d *KeyDetector) ProcessDigestDecision(digestID int, channelID string, decisionText string) (int, error) {
	did := digestID
	return d.upsertEach(links(detect(d.knownPrefixes(), decisionText), func(tracker, key string) db.IssueSlackLink {
		return db.IssueSlackLink{Tracker: tracker, IssueKey: key, ChannelID: channelID, DigestID: &did, LinkType: "decision"}
	}))
}

// refreshKnownKeys loads the known Jira project keys and Linear team keys. A
// failure of either keeps the previous set (see knownPrefixes).
func (d *KeyDetector) refreshKnownKeys() error {
	jiraKeys, err := d.db.GetKnownProjectKeys()
	if err != nil {
		return err
	}
	linearKeys, err := d.db.GetKnownLinearTeamKeys()
	if err != nil {
		return err
	}

	known := make(map[string][]string, len(jiraKeys)+len(linearKeys))
	for _, k := range jiraKeys {
		known[k] = append(known[k], trackerJira)
	}
	for _, k := range linearKeys {
		known[k] = append(known[k], trackerLinear)
	}

	d.mu.Lock()
	d.knownKeys = known
	d.loadedAt = d.clockNow()
	d.mu.Unlock()
	return nil
}

// ResetCache clears the known prefix cache, forcing a reload on next use.
func (d *KeyDetector) ResetCache() {
	d.mu.Lock()
	d.knownKeys = nil
	d.loadedAt = time.Time{}
	d.mu.Unlock()
}

// extractProjectKey extracts the prefix from an issue key ("PROJ-123" -> "PROJ").
func extractProjectKey(issueKey string) string {
	if idx := strings.LastIndex(issueKey, "-"); idx > 0 {
		return issueKey[:idx]
	}
	return issueKey
}

// extractFirstFromJSONArray is a simple extractor for the first string in a JSON array like `["C1","C2"]`.
func extractFirstFromJSONArray(s string) string {
	s = strings.TrimSpace(s)
	if len(s) < 4 || s[0] != '[' {
		return ""
	}
	// Find first quoted string.
	start := strings.IndexByte(s, '"')
	if start < 0 {
		return ""
	}
	end := strings.IndexByte(s[start+1:], '"')
	if end < 0 {
		return ""
	}
	return s[start+1 : start+1+end]
}

package jira

import (
	"log"
	"os"
	"regexp"
	"strings"
	"sync"

	"watchtower/internal/db"
)

// jiraKeyPattern matches Jira issue keys like "PROJ-123".
var jiraKeyPattern = regexp.MustCompile(`\b([A-Z][A-Z0-9_]+-\d+)\b`)

// KeyDetector detects Jira issue keys in text and links them to Slack messages.
type KeyDetector struct {
	db            *db.DB
	logger        *log.Logger
	knownKeys     map[string]bool
	knownKeysOnce sync.Once
	mu            sync.RWMutex
}

// NewKeyDetector creates a new KeyDetector.
func NewKeyDetector(database *db.DB) *KeyDetector {
	return &KeyDetector{
		db:     database,
		logger: log.New(os.Stderr, "[jira-keys] ", log.LstdFlags),
	}
}

// DetectKeys finds all Jira issue keys in text, filtering by known project keys.
func (d *KeyDetector) DetectKeys(text string) []string {
	d.knownKeysOnce.Do(func() {
		if err := d.refreshKnownKeys(); err != nil {
			d.logger.Printf("failed to load known project keys: %v", err)
		}
	})

	matches := jiraKeyPattern.FindAllString(text, -1)
	if len(matches) == 0 {
		return nil
	}

	d.mu.RLock()
	known := d.knownKeys
	d.mu.RUnlock()

	seen := make(map[string]bool)
	var result []string
	for _, m := range matches {
		if seen[m] {
			continue
		}
		seen[m] = true

		proj := extractProjectKey(m)
		// If we have no known keys yet, accept all matches.
		if len(known) == 0 || known[proj] {
			result = append(result, m)
		}
	}
	return result
}

// ProcessMessage detects Jira keys in a Slack message and records links.
func (d *KeyDetector) ProcessMessage(channelID, messageTS, text string) (int, error) {
	keys := d.DetectKeys(text)
	for _, key := range keys {
		link := db.JiraSlackLink{
			IssueKey:  key,
			ChannelID: channelID,
			MessageTS: messageTS,
			LinkType:  "mention",
		}
		if err := d.db.UpsertJiraSlackLink(link); err != nil {
			return 0, err
		}
	}
	return len(keys), nil
}

// ProcessTrack detects Jira keys in track text and source refs.
func (d *KeyDetector) ProcessTrack(trackID int, text string, sourceRefs string, channelIDs string) (int, error) {
	combined := text + " " + sourceRefs
	keys := d.DetectKeys(combined)

	// Extract first channel ID from JSON array for link context.
	channelID := extractFirstFromJSONArray(channelIDs)

	tid := trackID
	for _, key := range keys {
		link := db.JiraSlackLink{
			IssueKey:  key,
			ChannelID: channelID,
			TrackID:   &tid,
			LinkType:  "track",
		}
		if err := d.db.UpsertJiraSlackLink(link); err != nil {
			return 0, err
		}
	}
	return len(keys), nil
}

// ProcessDigestDecision detects Jira keys in a digest decision.
func (d *KeyDetector) ProcessDigestDecision(digestID int, channelID string, decisionText string) (int, error) {
	keys := d.DetectKeys(decisionText)

	did := digestID
	for _, key := range keys {
		link := db.JiraSlackLink{
			IssueKey:  key,
			ChannelID: channelID,
			DigestID:  &did,
			LinkType:  "decision",
		}
		if err := d.db.UpsertJiraSlackLink(link); err != nil {
			return 0, err
		}
	}
	return len(keys), nil
}

// refreshKnownKeys loads known project keys from the database.
func (d *KeyDetector) refreshKnownKeys() error {
	keys, err := d.db.GetKnownProjectKeys()
	if err != nil {
		return err
	}

	known := make(map[string]bool, len(keys))
	for _, k := range keys {
		known[k] = true
	}

	d.mu.Lock()
	d.knownKeys = known
	d.mu.Unlock()
	return nil
}

// ResetCache clears the known project keys cache, forcing a reload on next use.
func (d *KeyDetector) ResetCache() {
	d.mu.Lock()
	d.knownKeys = nil
	d.mu.Unlock()
	d.knownKeysOnce = sync.Once{}
}

// extractProjectKey extracts the project key from an issue key ("PROJ-123" -> "PROJ").
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

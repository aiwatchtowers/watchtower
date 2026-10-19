package reactioncmd

import (
	"fmt"
	"regexp"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// The two "file an issue" tools a reaction may dispatch. An emoji mapped to
// either is routed to the tracker the channel's issue keys belong to.
const (
	toolJiraIssue   = "create_jira_issue"
	toolLinearIssue = "create_linear_issue"
)

// channelScanLimit is how many of the channel's newest synced messages the
// router reads for issue keys.
const channelScanLimit = 200

// issueKeyRe matches an issue key (ENG-12, ABC_X-3, A-5) anywhere in a text,
// including inside a tracker URL. Linear allows one-letter team keys; a
// prefix counts only when it is a known project or team key.
var issueKeyRe = regexp.MustCompile(`\b([A-Z][A-Z0-9_]*)-[0-9]+\b`)

func isIssueTool(name string) bool { return name == toolJiraIssue || name == toolLinearIssue }

// trackerEvidence says which trackers' keys a channel mentions. A prefix both
// trackers own counts for neither: it cannot tell them apart.
type trackerEvidence struct{ jira, linear bool }

func scanTrackerEvidence(texts []string, pre db.TrackerPrefixes) trackerEvidence {
	var ev trackerEvidence
	for _, text := range texts {
		for _, m := range issueKeyRe.FindAllStringSubmatch(text, -1) {
			prefix := m[1]
			inJira, inLinear := pre.Jira[prefix], pre.Linear[prefix]
			switch {
			case inJira && !inLinear:
				ev.jira = true
			case inLinear && !inJira:
				ev.linear = true
			}
		}
	}
	return ev
}

// routeIssueTool picks the issue tool for a reaction whose emoji maps to
// mapped (an issue tool): the tracker the channel's keys belong to; for a
// channel mentioning both trackers' keys, or none while both trackers are
// connected, the dictionary's own tool; with no keys and one tracker
// connected, that tracker. why is empty when the dictionary's tool stands for
// the ordinary reason (nothing to route on).
func routeIssueTool(mapped string, ev trackerEvidence, jiraConnected, linearConnected bool) (tool, why string) {
	switch {
	case ev.jira && ev.linear:
		return mapped, "the channel mentions both Jira and Linear keys; keeping the dictionary's tool"
	case ev.jira:
		return toolJiraIssue, "the channel's issue keys are Jira's"
	case ev.linear:
		return toolLinearIssue, "the channel's issue keys are Linear's"
	case jiraConnected && !linearConnected:
		return toolJiraIssue, "only Jira is connected"
	case linearConnected && !jiraConnected:
		return toolLinearIssue, "only Linear is connected"
	default:
		return mapped, ""
	}
}

// prefixCache holds one Run's tracker key prefixes, read on first use.
type prefixCache struct {
	loaded bool
	pre    db.TrackerPrefixes
	err    error
}

func (pc *prefixCache) get(d *db.DB) (db.TrackerPrefixes, error) {
	if !pc.loaded {
		pc.pre, pc.err = d.ReactionTrackerPrefixes()
		pc.loaded = true
	}
	return pc.pre, pc.err
}

// routeIssue returns the registered reaction-surface tool an issue reaction
// files with, from the keys in the reacted message, its thread (thread, the
// lines compose also grounds on) and the channel's newest messages. Routing
// refines the dictionary's choice and never gates it: a read error or a
// routed tool the reaction surface cannot dispatch keeps the dictionary's
// tool (logged).
func (p *Pipeline) routeIssue(c candidate, mapped *tools.Tool, prefixes *prefixCache, thread []string) *tools.Tool {
	pre, err := prefixes.get(p.db)
	if err != nil {
		p.logf("reaction-commands: routing :%s: (keeping %s): %v", c.Emoji, mapped.Name, err)
		return mapped
	}
	recent, err := p.db.RecentChannelTexts(c.ChannelID, channelScanLimit)
	if err != nil {
		p.logf("reaction-commands: routing :%s: (keeping %s): %v", c.Emoji, mapped.Name, err)
		return mapped
	}
	texts := append(append([]string{c.Text}, thread...), recent...)
	name, why := routeIssueTool(mapped.Name, scanTrackerEvidence(texts, pre), len(pre.Jira) > 0, len(pre.Linear) > 0)
	if name == mapped.Name {
		if why != "" {
			p.logf("reaction-commands: :%s: on %s: %s (%s)", c.Emoji, c.ChannelID, why, mapped.Name)
		}
		return mapped
	}
	routed, ok := p.registry.Get(name)
	if !ok || !routed.VisibleOn(reactionSurface) {
		p.logf("reaction-commands: :%s: would file with %s (%s), which the reaction surface cannot dispatch; keeping %s",
			c.Emoji, name, why, mapped.Name)
		return mapped
	}
	p.logf("reaction-commands: :%s: on %s files with %s instead of %s: %s", c.Emoji, c.ChannelID, name, mapped.Name, why)
	return routed
}

// formatLinearTeams renders the teams a Linear reaction may file into; a key
// that exists on several workspaces names its account, so the model can pass
// account_id.
func formatLinearTeams(teams []db.ReactionLinearTeam) []string {
	count := map[string]int{}
	for _, t := range teams {
		count[t.Key]++
	}
	out := make([]string, 0, len(teams))
	for _, t := range teams {
		if count[t.Key] > 1 {
			out = append(out, fmt.Sprintf("%s (account_id %d)", t.Key, t.AccountID))
			continue
		}
		out = append(out, t.Key)
	}
	return out
}

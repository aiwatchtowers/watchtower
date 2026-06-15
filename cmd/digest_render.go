package cmd

import (
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/ui"
)

// showDigestCatchup displays pre-built digests for a catchup period.
// Returns true if digests were shown, false if none were available.
func showDigestCatchup(out interface{ Write([]byte) (int, error) }, database *db.DB, fromUnix float64) bool {
	// Check for daily digest first
	dailyDigests, err := database.GetDigests(db.DigestFilter{
		Type:     "daily",
		FromUnix: fromUnix,
		Limit:    1,
	})
	if err == nil && len(dailyDigests) > 0 {
		d := dailyDigests[0]
		var buf strings.Builder
		fmt.Fprintln(&buf, d.Summary)
		printDigestDetails(&buf, d, database)
		fmt.Fprint(out, ui.RenderMarkdown(buf.String()))
		return true
	}

	// Fall back to channel digests
	channelDigests, err := database.GetDigests(db.DigestFilter{
		Type:     "channel",
		FromUnix: fromUnix,
	})
	if err != nil || len(channelDigests) == 0 {
		return false
	}

	var buf strings.Builder
	for _, d := range channelDigests {
		name := d.ChannelID
		if ch, err := database.GetChannelByID(d.ChannelID); err == nil && ch != nil {
			name = "#" + ch.Name
		}
		fmt.Fprintf(&buf, "**%s** (%d messages)\n%s\n\n", name, d.MessageCount, d.Summary)
		printDigestDetails(&buf, d, database)
	}
	fmt.Fprint(out, ui.RenderMarkdown(buf.String()))
	return true
}

func printDigestDetails(out interface{ Write([]byte) (int, error) }, d db.Digest, database ...*db.DB) {
	// Try topic-structured data first
	var topics []db.DigestTopic
	if len(database) > 0 && database[0] != nil {
		topics, _ = database[0].GetDigestTopics(d.ID)
	}
	if len(topics) > 0 {
		for _, t := range topics {
			fmt.Fprintf(out, "\n**%s**\n", t.Title)
			if t.Summary != "" {
				fmt.Fprintf(out, "%s\n", t.Summary)
			}

			var decisions []struct {
				Text string `json:"text"`
				By   string `json:"by"`
			}
			if err := json.Unmarshal([]byte(t.Decisions), &decisions); err == nil && len(decisions) > 0 {
				for _, dec := range decisions {
					if dec.By != "" {
						fmt.Fprintf(out, "- **Decision:** %s (by %s)\n", dec.Text, dec.By)
					} else {
						fmt.Fprintf(out, "- **Decision:** %s\n", dec.Text)
					}
				}
			}

			var actions []struct {
				Text     string `json:"text"`
				Assignee string `json:"assignee"`
			}
			if err := json.Unmarshal([]byte(t.ActionItems), &actions); err == nil && len(actions) > 0 {
				for _, a := range actions {
					assignee := ""
					if a.Assignee != "" {
						assignee = " -> " + a.Assignee
					}
					fmt.Fprintf(out, "- %s%s\n", a.Text, assignee)
				}
			}
		}
		return
	}

	// Fallback to old flat fields for legacy digests
	var decisions []struct {
		Text string `json:"text"`
		By   string `json:"by"`
	}
	if err := json.Unmarshal([]byte(d.Decisions), &decisions); err == nil && len(decisions) > 0 {
		fmt.Fprintln(out, "\n**Decisions:**")
		fmt.Fprintln(out)
		for _, dec := range decisions {
			if dec.By != "" {
				fmt.Fprintf(out, "- %s (by %s)\n", dec.Text, dec.By)
			} else {
				fmt.Fprintf(out, "- %s\n", dec.Text)
			}
		}
	}

	var actions []struct {
		Text     string `json:"text"`
		Assignee string `json:"assignee"`
	}
	if err := json.Unmarshal([]byte(d.ActionItems), &actions); err == nil && len(actions) > 0 {
		fmt.Fprintln(out, "\n**Action Items:**")
		fmt.Fprintln(out)
		for _, a := range actions {
			assignee := ""
			if a.Assignee != "" {
				assignee = " -> " + a.Assignee
			}
			fmt.Fprintf(out, "- %s%s\n", a.Text, assignee)
		}
	}
}

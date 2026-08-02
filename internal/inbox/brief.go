package inbox

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

const (
	maxBriefTracks = 15
	maxBriefJira   = 10
	maxBriefEvents = 10
)

// buildSecretaryBrief assembles the user-knowledge block injected into both
// inbox AI prompts. Every source is best-effort: a failing or empty source
// just omits its section. The function itself never fails.
func buildSecretaryBrief(database *db.DB, currentUserID string, now time.Time) string {
	var b strings.Builder
	b.WriteString("=== SECRETARY BRIEF ===\n")

	writeProfileSection(&b, database)
	writeRoleSection(&b, database, currentUserID)
	writeOwnerEmailsSection(&b, database)
	writeSlackWorkspacesSection(&b, database)
	writeTracksSection(&b, database)
	writeJiraSection(&b, database, currentUserID)
	writeCalendarSection(&b, database, now)

	return b.String()
}

// writeOwnerEmailsSection appends the owner's known email addresses (Gmail
// accounts + connected IMAP/Outlook accounts), so the AI can recognize
// messages addressed to any of them as involving the owner. Omitted
// entirely when no address is known, keeping single/no-account output
// byte-identical to before this section existed.
func writeOwnerEmailsSection(b *strings.Builder, database *db.DB) {
	var addrs []string
	if accounts, err := database.ListGoogleAccounts(); err == nil {
		for _, a := range accounts {
			if a.Email != "" {
				addrs = append(addrs, a.Email)
			}
		}
	}
	if accounts, err := database.ListEmailAccounts(); err == nil {
		for _, a := range accounts {
			if a.EmailAddress != "" {
				addrs = append(addrs, a.EmailAddress)
			}
		}
	}
	if len(addrs) == 0 {
		return
	}
	fmt.Fprintf(b, "Owner email addresses: %s\n\n", strings.Join(addrs, ", "))
}

// writeSlackWorkspacesSection lists the connected Slack workspaces when more
// than one is connected, so triage/composer prompts understand a message may
// come from any of them (mirroring the Gmail owner-addresses line's purpose).
// Omitted entirely for the single/no-account case, keeping that output
// byte-identical to before this section existed.
func writeSlackWorkspacesSection(b *strings.Builder, database *db.DB) {
	accounts, err := database.ListSlackAccounts()
	if err != nil || len(accounts) <= 1 {
		return
	}
	parts := make([]string, 0, len(accounts))
	for _, a := range accounts {
		label := a.Label
		if label == "" {
			label = a.TeamName
		}
		if a.TeamName != "" && a.TeamName != label {
			parts = append(parts, fmt.Sprintf("%s (%s)", label, a.TeamName))
		} else {
			parts = append(parts, label)
		}
	}
	fmt.Fprintf(b, "Connected Slack workspaces: %s\n\n", strings.Join(parts, ", "))
}

// writeProfileSection appends the user's own secretary instructions, if set.
func writeProfileSection(b *strings.Builder, database *db.DB) {
	if profile, err := database.GetSecretaryProfile(); err == nil && profile != "" {
		b.WriteString("USER'S OWN INSTRUCTIONS (highest authority):\n")
		b.WriteString(profile + "\n\n")
	}
}

// writeRoleSection appends the user's role/team, if known.
func writeRoleSection(b *strings.Builder, database *db.DB, currentUserID string) {
	if up, err := database.GetUserProfile(currentUserID); err == nil && up != nil && up.Role != "" {
		fmt.Fprintf(b, "ROLE: %s", up.Role)
		if up.Team != "" {
			fmt.Fprintf(b, " (team: %s)", up.Team)
		}
		b.WriteString("\n\n")
	}
}

// writeTracksSection appends up to maxBriefTracks active narrative tracks.
func writeTracksSection(b *strings.Builder, database *db.DB) {
	if tracks, err := database.GetAllActiveTracks(); err == nil && len(tracks) > 0 {
		b.WriteString("ACTIVE TRACKS (the user's ongoing storylines):\n")
		for i, tr := range tracks {
			if i >= maxBriefTracks {
				break
			}
			// BallOn holds a raw user id; track text can carry <@U...> mentions.
			// Resolve both — the AI treats whatever appears here as the person's
			// name and copies it into situation titles verbatim.
			ballOn, _ := database.UserNameByID(tr.BallOn)
			fmt.Fprintf(b, "- [%s] %s (ball on: %s)\n", tr.Priority, enrichSnippet(tr.Text, database), ballOn)
		}
		b.WriteString("\n")
	}
}

// writeJiraSection appends up to maxBriefJira open Jira issues for the user.
func writeJiraSection(b *strings.Builder, database *db.DB, currentUserID string) {
	issues, err := database.GetJiraIssuesForUser(currentUserID, "")
	if err != nil {
		return
	}
	var open []db.JiraIssue
	for _, is := range issues {
		if is.StatusCategory != "done" {
			open = append(open, is)
		}
	}
	if len(open) > 0 {
		b.WriteString("MY OPEN JIRA:\n")
		for i, is := range open {
			if i >= maxBriefJira {
				break
			}
			fmt.Fprintf(b, "- %s %s (%s)\n", is.Key, is.Summary, is.Status)
		}
		b.WriteString("\n")
	}
}

// writeCalendarSection appends up to maxBriefEvents of today's calendar events.
func writeCalendarSection(b *strings.Builder, database *db.DB, now time.Time) {
	if events, err := database.GetCalendarEventsForDate(now.Format("2006-01-02")); err == nil && len(events) > 0 {
		b.WriteString("TODAY'S CALENDAR:\n")
		for i, ev := range events {
			if i >= maxBriefEvents {
				break
			}
			fmt.Fprintf(b, "- %s %s\n", ev.StartTime, ev.Title)
		}
		b.WriteString("\n")
	}
}

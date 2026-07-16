package dayplan

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/briefing"
	"watchtower/internal/db"
	"watchtower/internal/memory"
)

// noMemoryOpenLoops is the sentinel rendered into the MEMORY OPEN LOOPS
// placeholder when the gate is off, no vault exists, or nothing qualifies. The
// template instructs the model to ignore memory entirely when it sees this text,
// so the placeholder is always safe to pass as a Sprintf arg (arg count is fixed).
const noMemoryOpenLoops = "(no memory open loops)"

// maxMemoryOpenLoops caps the block at ten lines so the day-plan prompt stays
// focused; memory loops are context, not the schedulable task list.
const maxMemoryOpenLoops = 10

// gatherMemoryOpenLoops builds the MEMORY OPEN LOOPS block: for each ACTIVE
// entity in the vault whose "## Open loops" section is non-empty, one
// "- <entity title>: <loop bullet>" line per bullet, capped at ten. It is a pure
// reader of the vault (MEM-14): it never creates a vault (OpenExistingVault), never
// writes, and always returns a string safe to pass as a Sprintf arg — the sentinel
// when the gate is off, no vault exists, or nothing qualifies.
//
// Vault content is framed model-mediated in the template ("open loops the
// secretary tracks in its memory — model-derived, verify before acting"), never
// as fact.
func (p *Pipeline) gatherMemoryOpenLoops() string {
	if !p.cfg.Memory.Surfaces.DayPlan {
		return noMemoryOpenLoops
	}

	vault, err := memory.OpenExistingVault(filepath.Join(p.cfg.WorkspaceDir(), "memory"))
	if err != nil {
		// ErrVaultNotInitialized is the benign "memory never run" case — degrade
		// silently. Any OTHER open failure is logged before degrading, so a real
		// problem is not swallowed as if the vault simply did not exist (P3).
		if !errors.Is(err, memory.ErrVaultNotInitialized) && p.logger != nil {
			p.logger.Printf("dayplan: opening memory vault for open loops: %v", err)
		}
		return noMemoryOpenLoops
	}

	nodes, err := p.db.ListMemoryNodes()
	if err != nil {
		if p.logger != nil {
			p.logger.Printf("dayplan: error listing memory nodes: %v", err)
		}
		return noMemoryOpenLoops
	}

	var lines []string
	for _, n := range nodes {
		if n.Type != "entity" || n.Status != "active" {
			continue
		}
		node, err := vault.ReadNode(n.ID)
		if err != nil {
			// Index/vault drift (a file removed since indexing): skip, don't fail.
			continue
		}
		title := strings.TrimSpace(node.Title)
		if title == "" {
			title = node.ID
		}
		for _, bullet := range openLoopBullets(node.Body) {
			lines = append(lines, "- "+title+": "+bullet)
			if len(lines) >= maxMemoryOpenLoops {
				break
			}
		}
		if len(lines) >= maxMemoryOpenLoops {
			break
		}
	}

	if len(lines) == 0 {
		return noMemoryOpenLoops
	}
	return strings.Join(lines, "\n")
}

// openLoopBullets returns the bullet texts under a node's "## Open loops" section
// (each "- …" line, with the "- " marker stripped), in file order. Empty when the
// section is absent or carries no bullets.
func openLoopBullets(body string) []string {
	var bullets []string
	in := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			in = trimmed == "## Open loops"
			continue
		}
		if !in {
			continue
		}
		if strings.HasPrefix(trimmed, "- ") {
			if b := strings.TrimSpace(strings.TrimPrefix(trimmed, "- ")); b != "" {
				bullets = append(bullets, b)
			}
		}
	}
	return bullets
}

// gatherTargets returns active targets (todo, in_progress, blocked), ordered by priority.
func (p *Pipeline) gatherTargets() ([]db.Target, error) {
	rows, err := p.db.Query(`SELECT id, text, intent, level, custom_label, period_start, period_end,
		parent_id, status, priority, ownership,
		ball_on, due_date, snooze_until, blocking, tags, sub_items, notes,
		progress, source_type, source_id, ai_level_confidence, created_at, updated_at
		FROM targets
		WHERE status IN ('todo', 'in_progress', 'blocked')
		ORDER BY
			CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 END,
			CASE WHEN due_date = '' THEN 1 ELSE 0 END,
			due_date ASC,
			created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("querying active targets: %w", err)
	}
	defer rows.Close()

	var targets []db.Target
	for rows.Next() {
		var t db.Target
		if err := rows.Scan(
			&t.ID, &t.Text, &t.Intent, &t.Level, &t.CustomLabel, &t.PeriodStart, &t.PeriodEnd,
			&t.ParentID, &t.Status, &t.Priority, &t.Ownership,
			&t.BallOn, &t.DueDate, &t.SnoozeUntil, &t.Blocking, &t.Tags, &t.SubItems, &t.Notes,
			&t.Progress, &t.SourceType, &t.SourceID, &t.AILevelConfidence, &t.CreatedAt, &t.UpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("scanning target: %w", err)
		}
		targets = append(targets, t)
	}
	return targets, rows.Err()
}

// gatherCalendarEvents returns all calendar events occurring on the given date (YYYY-MM-DD).
func (p *Pipeline) gatherCalendarEvents(date string) ([]db.CalendarEvent, error) {
	events, err := p.db.GetCalendarEventsForDate(date)
	if err != nil {
		return nil, fmt.Errorf("querying calendar events for %s: %w", date, err)
	}
	return events, nil
}

// gatherBriefing returns today's briefing for the user, falling back to yesterday's.
// Returns nil if neither exists (not an error).
func (p *Pipeline) gatherBriefing(userID, date string) *db.Briefing {
	b, err := p.db.GetBriefing(userID, date)
	if err == nil && b != nil {
		return b
	}

	// Try yesterday.
	t, err2 := time.Parse("2006-01-02", date)
	if err2 != nil {
		return nil
	}
	yesterday := t.AddDate(0, 0, -1).Format("2006-01-02")
	b, err = p.db.GetBriefing(userID, yesterday)
	if err == nil && b != nil {
		return b
	}
	return nil
}

// gatherJira returns active Jira issues assigned to the user.
// Errors are logged and an empty slice is returned (graceful degradation).
func (p *Pipeline) gatherJira(userID string) []db.JiraIssue {
	issues, err := p.db.GetJiraIssuesByAssigneeSlackID(userID)
	if err != nil {
		if p.logger != nil {
			p.logger.Printf("dayplan: gatherJira: %v", err)
		}
		return nil
	}
	return issues
}

// gatherPeople returns the latest active people cards.
// Errors are logged and an empty slice is returned (graceful degradation).
func (p *Pipeline) gatherPeople() []db.PeopleCard {
	cards, err := p.db.GetPeopleCards(db.PeopleCardFilter{Limit: 50})
	if err != nil {
		if p.logger != nil {
			p.logger.Printf("dayplan: gatherPeople: %v", err)
		}
		return nil
	}
	// Filter to active / ready cards only.
	var active []db.PeopleCard
	for _, c := range cards {
		if c.Status == "active" || c.Status == "ready" {
			active = append(active, c)
		}
	}
	return active
}

// gatherManualItems returns only manually added items for an existing plan.
func (p *Pipeline) gatherManualItems(planID int64) ([]db.DayPlanItem, error) {
	all, err := p.db.GetDayPlanItems(planID)
	if err != nil {
		return nil, fmt.Errorf("getting plan items for %d: %w", planID, err)
	}
	var manual []db.DayPlanItem
	for _, it := range all {
		if it.SourceType == "manual" {
			manual = append(manual, it)
		}
	}
	return manual, nil
}

// gatherPreviousPlan returns the most recent day plan for the user before the given date.
// Returns nil if none found.
func (p *Pipeline) gatherPreviousPlan(userID, date string) *db.DayPlan {
	plans, err := p.db.ListDayPlans(userID, 10)
	if err != nil {
		if p.logger != nil {
			p.logger.Printf("dayplan: gatherPreviousPlan: %v", err)
		}
		return nil
	}
	for i := range plans {
		if plans[i].PlanDate < date {
			return &plans[i]
		}
	}
	return nil
}

// formatBriefingContext formats the attention and coaching sections of a briefing
// into a human-readable string for injection into the day plan prompt.
// Returns "(none)" if the briefing is nil or both sections are empty.
func formatBriefingContext(b *db.Briefing) string {
	if b == nil {
		return "(none)"
	}

	var attn []briefing.AttentionItem
	if b.Attention != "" && b.Attention != "null" {
		_ = json.Unmarshal([]byte(b.Attention), &attn)
	}

	var coaching []briefing.CoachingItem
	if b.Coaching != "" && b.Coaching != "null" {
		_ = json.Unmarshal([]byte(b.Coaching), &coaching)
	}

	if len(attn) == 0 && len(coaching) == 0 {
		return "(none)"
	}

	var sb strings.Builder
	sb.WriteString("Attention items:\n")
	for _, a := range attn {
		fmt.Fprintf(&sb, "- [%s:%s] %s (priority: %s; reason: %s)\n",
			a.SourceType, a.SourceID, a.Text, a.Priority, a.Reason)
	}
	sb.WriteString("Coaching hints:\n")
	for _, c := range coaching {
		fmt.Fprintf(&sb, "- %s\n", c.Text)
	}
	return strings.TrimRight(sb.String(), "\n")
}

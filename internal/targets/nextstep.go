package targets

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// NextStep is the AI-suggested single most important next action for a target.
// It is persisted as JSON in targets.next_step and rendered as the "next step"
// card in the Desktop target detail view.
type NextStep struct {
	Title         string           `json:"title"`          // the action, imperative, one line
	Rationale     string           `json:"rationale"`      // why this is the next step (1-2 sentences)
	Urgency       string           `json:"urgency"`        // deadline | blocked | stale | normal
	UrgencyDetail string           `json:"urgency_detail"` // short relative hint, e.g. "6 days"
	Actions       []NextStepAction `json:"actions"`        // up to 3 suggested buttons
}

// NextStepAction is one button on the next-step card. Kind selects how the
// Desktop UI wires the button; the backend only proposes them.
//
//	assistant  → open the target assistant chat prefilled with Prompt
//	open_links → reveal the target's links / referenced items
//	mark_done  → mark the target done
//	dismiss    → dismiss the target
type NextStepAction struct {
	Label  string `json:"label"`
	Kind   string `json:"kind"`
	Prompt string `json:"prompt,omitempty"` // prefill for kind=assistant
}

var validNextStepKinds = map[string]bool{
	"assistant": true, "open_links": true, "mark_done": true, "dismiss": true,
}

const nextStepSystemPrompt = `You are an execution coach embedded in a goal-tracking app. Given ONE target (a goal/task the operator owns) with its full context, decide the single most important NEXT ACTION the operator should take right now to move it forward.

Return ONLY a JSON object (no markdown, no prose) with this shape:
{
  "title": "imperative one-line action, max ~80 chars",
  "rationale": "1-2 sentences: why this is the next step and what it unblocks",
  "urgency": "deadline | blocked | stale | normal",
  "urgency_detail": "short hint like \"6 days\" (days to due) or \"\"",
  "actions": [
    {"label": "short button text", "kind": "assistant", "prompt": "what to ask the assistant"},
    {"label": "Show tickets", "kind": "open_links"},
    {"label": "Different plan", "kind": "assistant", "prompt": "Suggest a different next step for this target"}
  ]
}

Rules:
- Exactly one concrete next action in "title" — not a list, not a summary of the goal.
- Pick "urgency": "deadline" if a due date is near/passed, "blocked" if status is blocked or someone else holds the ball, "stale" if it has not moved in a while, else "normal".
- "urgency_detail" is a SHORT hint (e.g. days remaining). Leave "" if nothing meaningful.
- Provide 1-3 actions. The FIRST is the primary action. Always include a final {"kind":"assistant","prompt":"Suggest a different next step for this target"} option labelled like "Different plan" unless it would be the only action.
- Use "open_links" only if the target has links/referenced items.
- Keep everything in the operator's language (match the target's text language).`

// GenerateNextStep computes and persists the next-step suggestion for a single
// target. It returns the parsed suggestion. The call routes to the default
// (quality) model since it requires prioritisation reasoning.
func (p *Pipeline) GenerateNextStep(ctx context.Context, targetID int) (*NextStep, error) {
	target, err := p.db.GetTargetByID(targetID)
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", targetID, err)
	}

	prompt := p.buildNextStepPrompt(target)
	ctx2 := digest.WithSource(ctx, "targets.next_step")
	sys := nextStepSystemPrompt + "\n\n" + prompts.Directive(p.lang)
	raw, _, _, err := p.gen.Generate(ctx2, sys,
		"Decide the single next action for this target.\n\n"+prompt, "")
	if err != nil {
		return nil, fmt.Errorf("next-step AI call for target %d: %w", targetID, err)
	}

	ns, err := parseNextStep(raw)
	if err != nil {
		return nil, fmt.Errorf("parsing next-step for target %d: %w", targetID, err)
	}

	encoded, err := json.Marshal(ns)
	if err != nil {
		return nil, fmt.Errorf("encoding next-step for target %d: %w", targetID, err)
	}
	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	if err := p.db.SetTargetNextStep(targetID, string(encoded), now); err != nil {
		return nil, err
	}
	return ns, nil
}

// GenerateAllNextSteps refreshes next-step suggestions for every active target
// whose suggestion is missing or stale. It returns the number successfully
// generated. Failures on individual targets are logged and skipped so one bad
// target does not abort the batch.
func (p *Pipeline) GenerateAllNextSteps(ctx context.Context) (int, error) {
	limit := 50
	if p.cfg != nil && p.cfg.Resolver.ActiveSnapshotLimit > 0 {
		limit = p.cfg.Resolver.ActiveSnapshotLimit
	}
	targets, err := p.db.GetTargetsNeedingNextStep(limit)
	if err != nil {
		return 0, err
	}
	if len(targets) == 0 {
		return 0, nil
	}

	const workers = 4
	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		done int
	)
	sem := make(chan struct{}, workers)
	for i := range targets {
		t := targets[i]
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			if ctx.Err() != nil {
				return
			}
			if _, err := p.GenerateNextStep(ctx, t.ID); err != nil {
				p.logger.Printf("targets/nextstep: target %d: %v", t.ID, err)
				return
			}
			mu.Lock()
			done++
			mu.Unlock()
		}()
	}
	wg.Wait()
	return done, ctx.Err()
}

// buildNextStepPrompt renders the target and its surrounding context into the
// user message for the next-step call.
func (p *Pipeline) buildNextStepPrompt(t *db.Target) string {
	var b strings.Builder
	now := time.Now()
	fmt.Fprintf(&b, "Today: %s\n\n", now.Format("2006-01-02"))
	fmt.Fprintf(&b, "TARGET: %s\n", t.Text)
	if t.Intent != "" {
		fmt.Fprintf(&b, "Why it matters: %s\n", t.Intent)
	}
	fmt.Fprintf(&b, "Status: %s | Priority: %s | Ownership: %s\n", t.Status, t.Priority, t.Ownership)
	if t.Level != "" {
		fmt.Fprintf(&b, "Horizon: %s (%s – %s)\n", t.Level, t.PeriodStart, t.PeriodEnd)
	}
	if t.DueDate != "" {
		fmt.Fprintf(&b, "Due: %s\n", t.DueDate)
	}
	if t.BallOn != "" {
		fmt.Fprintf(&b, "Ball on: %s\n", t.BallOn)
	}
	if t.Blocking != "" {
		fmt.Fprintf(&b, "Blocking: %s\n", t.Blocking)
	}

	// Parent for context on the bigger goal.
	if t.ParentID.Valid {
		if parent, err := p.db.GetTargetByID(int(t.ParentID.Int64)); err == nil {
			fmt.Fprintf(&b, "Part of larger target: %s\n", parent.Text)
		}
	}

	// Sub-items / checklist, flagging stuck (overdue) ones.
	if items := parseSubItems(t.SubItems); len(items) > 0 {
		b.WriteString("\nChecklist:\n")
		for _, it := range items {
			mark := "[ ]"
			if it.Done {
				mark = "[x]"
			}
			line := fmt.Sprintf("  %s %s", mark, it.Text)
			if !it.Done && subItemOverdue(it, now) {
				line += " (STUCK: overdue)"
			}
			b.WriteString(line + "\n")
		}
	}

	// Existing links signal that "open_links" is a valid action.
	if links, err := p.db.GetLinksForTarget(int64(t.ID), "both"); err == nil && len(links) > 0 {
		fmt.Fprintf(&b, "\nThis target has %d linked item(s).\n", len(links))
	}

	return b.String()
}

func parseSubItems(raw string) []storedSubItem {
	if raw == "" || raw == "[]" {
		return nil
	}
	var items []storedSubItem
	if err := json.Unmarshal([]byte(raw), &items); err != nil {
		return nil
	}
	return items
}

func subItemOverdue(it storedSubItem, now time.Time) bool {
	if it.DueDate == "" {
		return false
	}
	for _, layout := range []string{"2006-01-02T15:04", "2006-01-02"} {
		if d, err := time.Parse(layout, it.DueDate); err == nil {
			return d.Before(now)
		}
	}
	return false
}

// parseNextStep extracts and validates a NextStep from a raw AI response,
// tolerating markdown fences and surrounding prose.
func parseNextStep(raw string) (*NextStep, error) {
	obj, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return nil, err
	}
	var ns NextStep
	if err := json.Unmarshal([]byte(obj), &ns); err != nil {
		return nil, err
	}
	if strings.TrimSpace(ns.Title) == "" {
		return nil, fmt.Errorf("next-step has empty title")
	}
	ns.Urgency = normalizeUrgency(ns.Urgency)
	// Drop actions with unknown kinds rather than surfacing dead buttons.
	cleaned := ns.Actions[:0]
	for _, a := range ns.Actions {
		if validNextStepKinds[a.Kind] && strings.TrimSpace(a.Label) != "" {
			cleaned = append(cleaned, a)
		}
	}
	ns.Actions = cleaned
	return &ns, nil
}

func normalizeUrgency(u string) string {
	switch strings.ToLower(strings.TrimSpace(u)) {
	case "deadline", "blocked", "stale":
		return strings.ToLower(strings.TrimSpace(u))
	default:
		return "normal"
	}
}

// Package inboxlegacy turns the Inbox's legacy root entries (inbox.feed's
// typed legacy sections, mobile Inbox spec §4.4) into block documents the
// phone draws with its artifact renderer: Morning brief, Track my threads and
// Idea finder as mockup §5, Thread briefs as a list of rows, and Messages as
// a notice with its Mac text and "On your Mac". The Mac draws the sections
// with its own views; sub-project C deletes each section and its projection.
package inboxlegacy

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/tower/api"
)

// The words the documents carry (the phone shows them as written).
const (
	attentionHeading = "Attention"
	recentTitle      = "Recent"
	onYourMac        = "On your Mac"
	noPlan           = "No plan for this day yet."
	untitled         = "Untitled"
	doneMark         = "✓ "
)

// validateOptions admit the action refs of Thread briefs (as a built-in's)
// and the plan_item refs of a Morning brief (the hub only).
var validateOptions = blocks.Options{BuiltIn: true, PlanItemRefs: true}

// Project is s as a canonical block document. loc is the zone a plan item's
// time is written in (the hub's, the owner's Mac). A list longer than the
// document caps keeps its first rows and says how many more are on the Mac.
func Project(s api.LegacySection, loc *time.Location) (string, error) {
	if loc == nil {
		loc = time.UTC
	}
	var err error
	// A document over the caps (rows, bytes) is built again with half the
	// rows per list, down to one.
	for limit := blocks.MaxListRows; limit >= 1; limit /= 2 {
		var raw []any
		if raw, err = document(s, loc, limit); err != nil {
			return "", err
		}
		var doc blocks.Document
		if doc, err = blocks.Validate("inboxlegacy", raw, validateOptions); err != nil {
			continue
		}
		b, err := doc.Canonical()
		if err != nil {
			return "", err
		}
		return string(b), nil
	}
	return "", err
}

// document is s as the validator's input (goja's shapes: []any, map[string]any,
// int64), each list cut to limit rows.
func document(s api.LegacySection, loc *time.Location, limit int) ([]any, error) {
	switch s.Kind {
	case api.LegacyMorningBrief:
		return morningBrief(s, loc, limit), nil
	case api.LegacyTracks:
		var active, stopped []api.LegacyItem
		for _, it := range s.Items {
			if it.Stopped {
				stopped = append(stopped, it)
			} else {
				active = append(active, it)
			}
		}
		var out []any
		if len(active) > 0 {
			out = append(out, list("", active, limit, trackRow)...)
		}
		if len(stopped) > 0 {
			out = append(out, list(StoppedTitle(len(stopped)), stopped, limit, trackRow)...)
		}
		return out, nil
	case api.LegacyIdeas:
		var judge, rest []api.LegacyItem
		for _, it := range s.Items {
			if it.Unread {
				judge = append(judge, it)
			} else {
				rest = append(rest, it)
			}
		}
		var out []any
		if len(judge) > 0 {
			out = append(out, list(ToJudgeTitle(len(judge)), judge, limit, ideaRow)...)
		}
		if len(rest) > 0 {
			out = append(out, list(recentTitle, rest, limit, ideaRow)...)
		}
		return out, nil
	case api.LegacyThreadBriefs:
		return list("", s.Items, limit, briefRow), nil
	case api.LegacyMessages:
		return []any{
			text(strconv.Itoa(len(s.Items)) + " waiting · Mentions, DMs and replies"),
			text(onYourMac),
		}, nil
	default:
		return nil, errors.New("inboxlegacy: unknown legacy kind " + strconv.Quote(string(s.Kind)))
	}
}

// PlanHeading is a Morning brief's plan heading: "Plan · 2 of 6" (done of
// all).
func PlanHeading(done, all int) string { return fmt.Sprintf("Plan · %d of %d", done, all) }

// ToJudgeTitle is Idea finder's first list: "To judge · N".
func ToJudgeTitle(n int) string { return "To judge · " + strconv.Itoa(n) }

// StoppedTitle is Track my threads' stopped list: "Stopped · N".
func StoppedTitle(n int) string { return "Stopped · " + strconv.Itoa(n) }

// MoreOnYourMac is the line under a list cut by the caps.
func MoreOnYourMac(n int) string { return strconv.Itoa(n) + " more on your Mac" }

// morningBrief is a day's plan (a heading "Plan · done of all" and its items
// with their times) and its attention lines.
func morningBrief(s api.LegacySection, loc *time.Location, limit int) []any {
	var out []any
	if len(s.Items) > 0 {
		done := 0
		for _, it := range s.Items {
			if it.Done {
				done++
			}
		}
		out = append(out, heading(PlanHeading(done, len(s.Items))))
		out = append(out, list("", s.Items, limit, func(it api.LegacyItem) map[string]any {
			return planRow(it, loc)
		})...)
	}
	if len(s.Attention) > 0 {
		out = append(out, heading(attentionHeading))
		rows := make([]api.LegacyItem, 0, len(s.Attention))
		for _, a := range s.Attention {
			// An attention line is no record: no ref; High carries its priority.
			rows = append(rows, api.LegacyItem{Title: a.Text, Subtitle: a.Reason, High: a.Priority == "high"})
		}
		out = append(out, list("", rows, limit, attentionRow)...)
	}
	if len(out) == 0 {
		out = append(out, text(noPlan))
	}
	return out
}

// list is a list block of items' rows (at most limit) and, when some were
// cut, the line saying how many more are on the Mac.
func list(title string, items []api.LegacyItem, limit int, row func(api.LegacyItem) map[string]any) []any {
	kept := items[:min(len(items), limit)]
	rows := make([]any, 0, len(kept))
	for _, it := range kept {
		rows = append(rows, row(it))
	}
	l := map[string]any{"type": blocks.TypeList, "rows": rows}
	if title != "" {
		l["title"] = clip(title, blocks.MaxListTitleChars)
	}
	out := []any{l}
	if more := len(items) - len(kept); more > 0 {
		out = append(out, text(MoreOnYourMac(more)))
	}
	return out
}

// planRow is a plan item: "✓ " before a done one's title, its source as the
// subtitle, its time (a block's range) as the badge, its plan_item ref.
func planRow(it api.LegacyItem, loc *time.Location) map[string]any {
	title := titleOf(it)
	if it.Done {
		title = doneMark + title
	}
	r := row(title, it.Subtitle, it)
	if at := timeRange(it, loc); at != "" {
		r["badge"] = map[string]any{"text": at}
	}
	return r
}

// trackRow is a track: "Track", its "N new" as an accent badge.
func trackRow(it api.LegacyItem) map[string]any {
	r := row(titleOf(it), it.Subtitle, it)
	if it.Preview != "" {
		r["badge"] = map[string]any{"text": clip(it.Preview, blocks.MaxBadgeChars), "tone": "accent"}
	}
	return r
}

// ideaRow is an idea or a decision: its source line and its essence.
func ideaRow(it api.LegacyItem) map[string]any {
	return row(titleOf(it), joinNonEmpty(" — ", it.Subtitle, it.Preview), it)
}

// briefRow is a thread brief: its reason and its summary.
func briefRow(it api.LegacyItem) map[string]any {
	return row(titleOf(it), it.Preview, it)
}

// attentionRow is an attention line: its reason below, danger when high.
func attentionRow(it api.LegacyItem) map[string]any {
	r := row(titleOf(it), it.Subtitle, it)
	if it.High {
		r["tone"] = "danger"
	}
	return r
}

// row is a list row with title, subtitle (when any) and it's ref (when it
// names a record).
func row(title, subtitle string, it api.LegacyItem) map[string]any {
	r := map[string]any{"title": clip(title, blocks.MaxRowTitleChars)}
	if s := strings.TrimSpace(subtitle); s != "" {
		r["subtitle"] = clip(s, blocks.MaxRowSubtitleChars)
	}
	if it.RefKind != "" && it.ID > 0 {
		r["ref"] = map[string]any{"kind": string(it.RefKind), "id": it.ID}
	}
	return r
}

func titleOf(it api.LegacyItem) string {
	if t := strings.TrimSpace(it.Title); t != "" {
		return t
	}
	return untitled
}

// timeRange is a plan item's start, or "start–end" for a time block, in loc;
// "" for a backlog item.
func timeRange(it api.LegacyItem, loc *time.Location) string {
	start, err := time.Parse(time.RFC3339, it.Stamp)
	if err != nil {
		return ""
	}
	out := start.In(loc).Format("15:04")
	if end, err := time.Parse(time.RFC3339, it.End); err == nil {
		out += "–" + end.In(loc).Format("15:04")
	}
	return out
}

func heading(t string) map[string]any {
	return map[string]any{"type": blocks.TypeHeading, "text": clip(t, blocks.MaxHeadingChars), "level": int64(2)}
}

func text(markdown string) map[string]any {
	return map[string]any{"type": blocks.TypeText, "markdown": markdown}
}

func joinNonEmpty(sep string, parts ...string) string {
	var kept []string
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, sep)
}

// clip is s trimmed and cut to at most n characters, the last one an
// ellipsis when cut (the validator refuses a longer string).
func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return strings.TrimSpace(string(r[:n-1])) + "…"
}

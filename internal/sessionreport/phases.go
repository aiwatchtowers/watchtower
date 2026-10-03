package sessionreport

import (
	"context"
	"fmt"
	"slices"

	"watchtower/internal/db"
)

// span is when one target first moved to in_progress and last moved to done,
// from target_status_history; "" = never.
type span struct{ started, finished string }

// statusSpans is the span of every target of workbench projectID that has
// history.
func statusSpans(ctx context.Context, d *db.DB, projectID int64) (map[int64]span, error) {
	rows, err := d.QueryContext(ctx, `SELECT h.target_id,
		COALESCE(MIN(CASE WHEN h.to_status = 'in_progress' THEN h.changed_at END), ''),
		COALESCE(MAX(CASE WHEN h.to_status = 'done' THEN h.changed_at END), '')
		FROM target_status_history h JOIN targets t ON t.id = h.target_id
		WHERE t.project_id = ? GROUP BY h.target_id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading workbench %d status history: %w", projectID, err)
	}
	defer rows.Close()
	out := map[int64]span{}
	for rows.Next() {
		var id int64
		var s span
		if err := rows.Scan(&id, &s.started, &s.finished); err != nil {
			return nil, fmt.Errorf("reading workbench %d status history: %w", projectID, err)
		}
		out[id] = s
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading workbench %d status history: %w", projectID, err)
	}
	return out, nil
}

// phases is one Phase per parent of an in-scope leaf, in board order. A
// phase counts every counted leaf under its parent, touched or not; its items
// are the parent's own leaf children. The session's own target is a phase
// only when it is a flat ticket: with sub-parents its phase would repeat the
// report's progress, so its own leaves count in progress, now and next only.
func (s scope) phases(spans map[int64]span) []Phase {
	var parents []*boardEntry
	for _, e := range s.leaves() {
		if s.session != 0 && e.parent == s.session && s.b.hasSubParents(e.parent) {
			continue
		}
		if p, ok := s.b.byID[e.parent]; ok && !slices.Contains(parents, p) {
			parents = append(parents, p)
		}
	}
	slices.SortFunc(parents, func(a, b *boardEntry) int { return a.order - b.order })
	out := make([]Phase, 0, len(parents))
	for _, p := range parents {
		ph := Phase{TargetID: p.id(), Text: p.target.Text, Items: []Item{}}
		finished := ""
		for _, l := range s.b.leavesUnder(p.id()) {
			ph.Total++
			if l.target.Status == "done" {
				ph.Done++
			}
			sp := spans[l.id()]
			if sp.started != "" && (ph.StartedAt == "" || sp.started < ph.StartedAt) {
				ph.StartedAt = sp.started
			}
			finished = max(finished, sp.finished)
		}
		if ph.Total > 0 && ph.Done == ph.Total {
			ph.FinishedAt = finished
		}
		for _, c := range p.children {
			if e := s.b.byID[c]; e.leaf() && e.counted() {
				ph.Items = append(ph.Items, itemOf(e))
			}
		}
		out = append(out, ph)
	}
	return out
}

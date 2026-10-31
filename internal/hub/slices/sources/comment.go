package sources

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"time"

	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
)

// Caps of the comment slice (WorkbenchCommentSlice).
const (
	maxCommentsPerTarget = 200
	maxAgentLabel        = 60
	maxCommentBody       = 4000
)

// WorkbenchComments is the `workbench_comment` slice (mobile POC spec §4.4),
// record `workbench_comment-<project_comments.id>`: the comments on the
// published board targets (the board window, published workbenches only),
// the newest 200 per target. A reply that names only its parent counts
// toward its root's target. The phone never marks comments read. Wire
// shape: the Kit mirror WatchtowerKit.WorkbenchComment. now (nil =
// time.Now) is the window's clock.
func WorkbenchComments(d *db.DB, now func() time.Time) hubslices.Source {
	if now == nil {
		now = time.Now
	}
	return &commentSource{d: d, now: now}
}

type commentSource struct {
	d   *db.DB
	now func() time.Time
}

func (s *commentSource) Kind() hubslices.Kind { return "workbench_comment" }

type commentPayload struct {
	ID                int64     `json:"id"`
	WorkbenchID       int64     `json:"workbench_id"`
	TargetID          *int64    `json:"target_id,omitempty"`
	ParentID          *int64    `json:"parent_id,omitempty"`
	Author            string    `json:"author"`
	AgentLabel        string    `json:"agent_label"`
	AgentLabelClipped *bool     `json:"agent_label_clipped,omitempty"`
	Body              string    `json:"body"`
	BodyClipped       *bool     `json:"body_clipped,omitempty"`
	Status            string    `json:"status"`
	CreatedAt         wire.Time `json:"created_at"`
	Read              bool      `json:"read"`
}

func (s *commentSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	var items []hubslices.Item
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		refs, err := publishedRefs(ctx, tx)
		if err != nil || len(refs) == 0 {
			return err
		}
		workbenches := make(map[int64]bool, len(refs))
		for _, r := range refs {
			workbenches[r.id] = true
		}
		window, err := loadTargetWindow(ctx, tx, s.now())
		if err != nil {
			return err
		}
		err = scanRows(ctx, tx, `
SELECT id, project_id, target_id, parent_id, author, agent_label, body, status, created_at, read_at, board_target
FROM (
    SELECT c.id, c.project_id, c.target_id, c.parent_id, c.author, c.agent_label, c.body, c.status,
           c.created_at, c.read_at, COALESCE(c.target_id, root.target_id) AS board_target,
           ROW_NUMBER() OVER (
               PARTITION BY COALESCE(c.target_id, root.target_id)
               ORDER BY c.created_at DESC, c.id DESC
           ) AS rank
    FROM project_comments c
    LEFT JOIN project_comments root ON root.id = c.parent_id
)
WHERE board_target IS NOT NULL AND rank <= ?
ORDER BY id`, []any{maxCommentsPerTarget}, func(r *sql.Rows) error {
			var (
				p                   commentPayload
				target, parent      sql.NullInt64
				label, body, readAt string
				createdAt           string
				boardTarget         int64
			)
			if err := r.Scan(&p.ID, &p.WorkbenchID, &target, &parent, &p.Author, &label, &body, &p.Status,
				&createdAt, &readAt, &boardTarget); err != nil {
				return err
			}
			if _, ok := window.published[boardTarget]; !ok || !workbenches[p.WorkbenchID] {
				return nil
			}
			p.TargetID, p.ParentID = nullInt(target), nullInt(parent)
			p.AgentLabel, p.AgentLabelClipped = clipText(label, maxAgentLabel)
			p.Body, p.BodyClipped = clipText(body, maxCommentBody)
			id := strconv.FormatInt(p.ID, 10)
			p.CreatedAt = requiredDate(createdAt, "created_at", "workbench_comment-"+id)
			p.Read = readAt != ""
			b, err := wire.Marshal(p)
			if err != nil {
				return err
			}
			items = append(items, hubslices.Item{ID: id, Payload: b})
			return nil
		})
		if err != nil {
			return fmt.Errorf("reading the comments: %w", err)
		}
		return nil
	})
	return items, err
}

// nullInt is v as an optional wire value.
func nullInt(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	n := v.Int64
	return &n
}

package db

import (
	"database/sql"
	"fmt"
	"time"
)

// SkillPackOverlay is one owner-approved line rendered into a Watchtower
// pack skill's installed copies (skill_pack_overlays, spec 2026-11-03 §4.3).
// ProposalID 0 = no proposal (or the proposal is gone).
type SkillPackOverlay struct {
	ID         int64
	Skill      string
	Text       string
	ProposalID int64
	CreatedAt  time.Time
}

// ListSkillPackOverlays returns skill's overlay lines, oldest first.
func (db *DB) ListSkillPackOverlays(skill string) ([]SkillPackOverlay, error) {
	rows, err := db.Query(`SELECT id, skill, text, COALESCE(proposal_id, 0), created_at
		FROM skill_pack_overlays WHERE skill = ? ORDER BY id`, skill)
	if err != nil {
		return nil, fmt.Errorf("listing skill pack overlays: %w", err)
	}
	defer rows.Close()
	var out []SkillPackOverlay
	for rows.Next() {
		var o SkillPackOverlay
		var created string
		if err := rows.Scan(&o.ID, &o.Skill, &o.Text, &o.ProposalID, &created); err != nil {
			return nil, fmt.Errorf("scanning skill pack overlay: %w", err)
		}
		if o.CreatedAt, err = parseCoachStamp(created); err != nil {
			return nil, fmt.Errorf("parsing skill pack overlay created_at: %w", err)
		}
		out = append(out, o)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing skill pack overlays: %w", err)
	}
	return out, nil
}

// EditSkillPackOverlays removes removeIDs (each must be a row of skill, else
// ErrCoachStateChanged and nothing changes) and adds add, in one transaction;
// it returns the added ids in order. The EditPromptAdditions shape.
func (db *DB) EditSkillPackOverlays(skill string, removeIDs []int64, add []SkillPackOverlay, now time.Time) ([]int64, error) {
	var added []int64
	err := db.WithTx(func(tx *sql.Tx) error {
		for _, id := range removeIDs {
			res, err := tx.Exec(`DELETE FROM skill_pack_overlays WHERE id = ? AND skill = ?`, id, skill)
			if err != nil {
				return fmt.Errorf("removing skill pack overlay %d: %w", id, err)
			}
			if err := requireAffected(res, fmt.Errorf("skill pack overlay %d: %w", id, ErrCoachStateChanged)); err != nil {
				return err
			}
		}
		for _, o := range add {
			var pid any
			if o.ProposalID != 0 {
				pid = o.ProposalID
			}
			res, err := tx.Exec(`INSERT INTO skill_pack_overlays (skill, text, proposal_id, created_at) VALUES (?, ?, ?, ?)`,
				skill, o.Text, pid, coachStamp(now))
			if err != nil {
				return fmt.Errorf("adding skill pack overlay: %w", err)
			}
			id, err := res.LastInsertId()
			if err != nil {
				return fmt.Errorf("adding skill pack overlay: %w", err)
			}
			added = append(added, id)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return added, nil
}

// AllSkillPackOverlays maps every skill with overlay lines to its texts,
// oldest first: what an install renders.
func (db *DB) AllSkillPackOverlays() (map[string][]string, error) {
	rows, err := db.Query(`SELECT skill, text FROM skill_pack_overlays ORDER BY skill, id`)
	if err != nil {
		return nil, fmt.Errorf("listing skill pack overlays: %w", err)
	}
	defer rows.Close()
	out := map[string][]string{}
	for rows.Next() {
		var skill, text string
		if err := rows.Scan(&skill, &text); err != nil {
			return nil, fmt.Errorf("scanning skill pack overlay: %w", err)
		}
		out[skill] = append(out[skill], text)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing skill pack overlays: %w", err)
	}
	return out, nil
}

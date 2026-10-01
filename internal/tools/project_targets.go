package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/projectfiles"
)

// ---- create_targets ----------------------------------------------------

type newTargetItem struct {
	Key       string   `json:"key,omitempty" jsonschema:"a short handle for this item, unique in the call, so a later item can name it as parent_key"`
	Text      string   `json:"text" jsonschema:"the target title, imperative, at most 200 characters"`
	Intent    string   `json:"intent,omitempty" jsonschema:"why it matters / what done means; for a plan task, the plan path and task number"`
	Priority  string   `json:"priority,omitempty" jsonschema:"high | medium | low; default medium"`
	ParentID  int64    `json:"parent_id,omitempty" jsonschema:"an existing target of this project to nest under"`
	ParentKey string   `json:"parent_key,omitempty" jsonschema:"the key of an EARLIER item in this call to nest under"`
	Images    []string `json:"images,omitempty" jsonschema:"absolute paths of image files (PNG, JPEG, GIF or WebP, at most 5 MB each) to attach, e.g. a screenshot the owner shared in the message this target comes from; Watchtower keeps its own copy"`
}

type createTargetsArgs struct {
	Items  []newTargetItem `json:"items" jsonschema:"the targets to create, parents before their children"`
	Reason string          `json:"reason" jsonschema:"one sentence: why these targets, e.g. the plan they come from"`
}

type createdTarget struct {
	Key      string `json:"key,omitempty"`
	TargetID int64  `json:"target_id"`
}

// NewCreateTargets creates a batch of project targets in one transaction —
// a whole plan in one call. Nesting is by parent_id (an existing target of
// the project) or parent_key (an earlier item). An item's images are copied
// into store before the transaction. All or nothing.
func NewCreateTargets(store projectfiles.Store) *Tool {
	return &Tool{
		Name: "create_targets",
		Description: "Create targets on this project's board in one all-or-nothing call — e.g. a feature " +
			"target plus one sub-target per plan task. Nest with parent_id (an existing target of this " +
			"project) or parent_key (the key of an earlier item in the same call). Optional priority " +
			"high | medium | low (default medium). Optional images: absolute paths of image files to " +
			"attach to that target (PNG, JPEG, GIF or WebP, at most 5 MB each). Applied immediately.",
		InputSchema: mustSchema[createTargetsArgs]("create_targets"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a createTargetsArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			return validateTargetItems(a.Items)
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a createTargetsArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return scopeTargetItems(ctx, d, a.Items, b)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a createTargetsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_targets args: %w", err)
			}
			created, err := insertTargetItems(d, store, call.Binding.ProjectID, a.Items)
			if err != nil {
				return nil, err
			}
			return map[string]any{"created": created}, nil
		},
	}
}

// validateTargetItems checks the batch shape without the database: a
// non-empty batch under the cap, every text present, keys unique, at most one
// parent per item, and every parent_key naming an EARLIER item — so the
// insert order is always parents first and a key cycle is impossible.
func validateTargetItems(items []newTargetItem) error {
	if len(items) == 0 || len(items) > maxBatchTargets {
		return &ValidationError{Msg: fmt.Sprintf("items must hold 1 to %d targets", maxBatchTargets)}
	}
	seen := map[string]bool{}
	for i, it := range items {
		if err := validateTargetItem(i, it, seen); err != nil {
			return err
		}
		if it.Key != "" {
			seen[it.Key] = true
		}
	}
	return nil
}

func validateTargetItem(i int, it newTargetItem, earlier map[string]bool) error {
	if _, err := requireText(fmt.Sprintf("items[%d].text", i), it.Text, 200); err != nil {
		return err
	}
	switch {
	case it.Key != "" && earlier[it.Key]:
		return &ValidationError{Msg: fmt.Sprintf("items[%d].key %q is used twice", i, it.Key)}
	case it.ParentID != 0 && it.ParentKey != "":
		return &ValidationError{Msg: fmt.Sprintf("items[%d] has both parent_id and parent_key; give one", i)}
	case it.ParentKey != "" && !earlier[it.ParentKey]:
		return &ValidationError{Msg: fmt.Sprintf("items[%d].parent_key %q names no earlier item", i, it.ParentKey)}
	}
	if err := validateImagePaths(fmt.Sprintf("items[%d].images", i), it.Images); err != nil {
		return err
	}
	return validateEnum(fmt.Sprintf("items[%d].priority", i), it.Priority, db.TargetPriorities...)
}

// scopeTargetItems checks every parent_id belongs to the bound project.
func scopeTargetItems(ctx context.Context, d *db.DB, items []newTargetItem, b Binding) error {
	if _, err := projectOf(ctx, d, b); err != nil {
		return err
	}
	for _, it := range items {
		if it.ParentID == 0 {
			continue
		}
		if _, err := targetInProject(d, b.ProjectID, it.ParentID); err != nil {
			return err
		}
	}
	return nil
}

// insertTargetItems copies every item's images in, then inserts the batch
// and the image rows in one transaction through db.CreateProjectTargetsTx,
// which also rolls progress up into every parent. A parent_key becomes the
// 1-based BatchParent of the earlier item holding that key
// (validateTargetItems guaranteed it is earlier). On a failed write the
// copies no row names are removed again.
func insertTargetItems(d *db.DB, store projectfiles.Store, projectID int64, items []newTargetItem) ([]createdTarget, error) {
	var paths []string
	for _, it := range items {
		paths = append(paths, it.Images...)
	}
	images, err := ingestImages(d, store, projectID, paths)
	if err != nil {
		return nil, err
	}
	inputs := targetInputs(items)
	var ids []int64
	err = d.WithTx(func(tx *sql.Tx) error {
		var err error
		if ids, err = d.CreateProjectTargetsTx(tx, projectID, inputs); err != nil {
			return err
		}
		for i, it := range items {
			if err := images.attach(tx, projectID, ids[i], it.Images); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		_ = images.discardUnreferenced(d, projectID) // the write's error is the one to report
		var verr *ValidationError
		if errors.As(err, &verr) {
			return nil, err
		}
		return nil, fmt.Errorf("creating targets: %w", err)
	}
	created := make([]createdTarget, 0, len(ids))
	for i, id := range ids {
		created = append(created, createdTarget{Key: items[i].Key, TargetID: id})
	}
	return created, nil
}

func targetInputs(items []newTargetItem) []db.ProjectTargetInput {
	position := map[string]int{} // key -> 1-based batch position
	inputs := make([]db.ProjectTargetInput, 0, len(items))
	for i, it := range items {
		in := db.ProjectTargetInput{Title: strings.TrimSpace(it.Text), Intent: strings.TrimSpace(it.Intent), Priority: it.Priority}
		if it.ParentKey != "" {
			in.BatchParent = position[it.ParentKey]
		} else if it.ParentID != 0 {
			in.ParentID = sql.NullInt64{Int64: it.ParentID, Valid: true}
		}
		if it.Key != "" {
			position[it.Key] = i + 1
		}
		inputs = append(inputs, in)
	}
	return inputs
}

// ---- update_target -----------------------------------------------------

type updateTargetArgs struct {
	TargetID int64    `json:"target_id" jsonschema:"the project target to change"`
	Status   string   `json:"status,omitempty" jsonschema:"todo | in_progress | in_review | blocked | done | dismissed"`
	Progress *float64 `json:"progress,omitempty" jsonschema:"0.0 to 1.0; set after status (a status change resets a leaf's progress)"`
	Text     string   `json:"text,omitempty" jsonschema:"new title, at most 200 characters"`
	Intent   string   `json:"intent,omitempty" jsonschema:"new intent"`
	Priority string   `json:"priority,omitempty" jsonschema:"high | medium | low"`
	// AddImages / RemoveImageIDs attach and detach images (board target #117).
	AddImages      []string `json:"add_images,omitempty" jsonschema:"absolute paths of image files (PNG, JPEG, GIF or WebP, at most 5 MB each) to attach"`
	RemoveImageIDs []int64  `json:"remove_image_ids,omitempty" jsonschema:"ids of this target's images to detach (from get_target)"`
	Reason         string   `json:"reason" jsonschema:"one sentence: why, e.g. 'task 3 passed review'"`
}

// NewUpdateTarget changes one project target's status, progress, title,
// intent or priority, and attaches or detaches its images (copied into
// store).
func NewUpdateTarget(store projectfiles.Store) *Tool {
	return &Tool{
		Name: "update_target",
		Description: "Change a target on this project's board: status (todo, in_progress, in_review, blocked, done, " +
			"dismissed; in_review while the work is being reviewed), progress (0..1), title, intent or priority (high, medium, low); " +
			"attach images (add_images: absolute paths of PNG, JPEG, GIF or WebP files, at most 5 MB each) or detach them " +
			"(remove_image_ids, from get_target). Applied immediately.",
		InputSchema: mustSchema[updateTargetArgs]("update_target"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a updateTargetArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			return validateTargetUpdate(a)
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a updateTargetArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			if _, err := projectOf(ctx, d, b); err != nil {
				return err
			}
			if _, err := targetInProject(d, b.ProjectID, a.TargetID); err != nil {
				return err
			}
			return scopeImageIDs(d, a.TargetID, a.RemoveImageIDs)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a updateTargetArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding update_target args: %w", err)
			}
			return applyTargetUpdate(d, store, call.Binding.ProjectID, a)
		},
	}
}

func validateTargetUpdate(a updateTargetArgs) error {
	if a.Status == "" && a.Progress == nil && a.Priority == "" && len(a.AddImages) == 0 && len(a.RemoveImageIDs) == 0 &&
		strings.TrimSpace(a.Text) == "" && strings.TrimSpace(a.Intent) == "" {
		return &ValidationError{Msg: "give at least one of status, progress, text, intent, priority, add_images, remove_image_ids"}
	}
	if err := validateImagePaths("add_images", a.AddImages); err != nil {
		return err
	}
	if a.Progress != nil && (*a.Progress < 0 || *a.Progress > 1) {
		return &ValidationError{Msg: "progress must be between 0 and 1"}
	}
	if len([]rune(strings.TrimSpace(a.Text))) > 200 {
		return &ValidationError{Msg: "text must be at most 200 characters"}
	}
	if err := validateEnum("priority", a.Priority, db.TargetPriorities...); err != nil {
		return err
	}
	return validateEnum("status", a.Status, "todo", "in_progress", "in_review", "blocked", "done", "dismissed")
}

// applyTargetUpdate copies add_images in, then writes title/intent and
// priority, then status, then progress — status first because a status
// change re-derives a leaf's progress — and the image rows in one
// transaction, so a failure part-way leaves the target untouched. A detached
// image's copy is removed once no row names it.
func applyTargetUpdate(d *db.DB, store projectfiles.Store, projectID int64, a updateTargetArgs) (map[string]any, error) {
	t, err := targetInProject(d, projectID, a.TargetID)
	if err != nil {
		return nil, err
	}
	images, err := ingestImages(d, store, projectID, a.AddImages)
	if err != nil {
		return nil, err
	}
	var detached []string
	err = d.WithTx(func(tx *sql.Tx) error {
		if err := applyTargetFields(d, tx, t, a); err != nil {
			return err
		}
		for _, id := range a.RemoveImageIDs {
			path, err := db.RemoveProjectTargetImageTx(tx, projectID, int64(t.ID), id)
			if err != nil {
				return err
			}
			detached = append(detached, path)
		}
		return images.attach(tx, projectID, int64(t.ID), a.AddImages)
	})
	if err != nil {
		_ = images.discardUnreferenced(d, projectID) // the write's error is the one to report
		return nil, err
	}
	out := map[string]any{"target_id": a.TargetID}
	// The write is committed; a copy left behind is reported, never undone.
	if err := images.discardUnreferenced(d, projectID, detached...); err != nil {
		out["cleanup_warning"] = "detached image files could not all be removed: " + err.Error()
	}
	return out, nil
}

func applyTargetFields(d *db.DB, tx *sql.Tx, t *db.Target, a updateTargetArgs) error {
	if err := applyTargetText(d, tx, t, a); err != nil {
		return err
	}
	if a.Priority != "" && a.Priority != t.Priority {
		if err := d.UpdateTargetPriorityTx(tx, t.ID, a.Priority); err != nil {
			return fmt.Errorf("updating priority: %w", err)
		}
	}
	if a.Status != "" && a.Status != t.Status {
		if err := d.UpdateTargetStatusAsTx(tx, t.ID, a.Status, db.ActorAgent); err != nil {
			return fmt.Errorf("updating status: %w", err)
		}
	}
	if a.Progress != nil {
		if err := d.SetTargetProgressTx(tx, t.ID, *a.Progress); err != nil {
			return fmt.Errorf("updating progress: %w", err)
		}
	}
	return nil
}

// scopeImageIDs refuses a remove_image_ids entry that is not one of the
// target's own images.
func scopeImageIDs(d *db.DB, targetID int64, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	images, err := d.ListProjectTargetImages(targetID)
	if err != nil {
		return err
	}
	own := map[int64]bool{}
	for _, img := range images {
		own[img.ID] = true
	}
	for _, id := range ids {
		if !own[id] {
			return &ValidationError{Msg: fmt.Sprintf("image %d is not an image of target %d", id, targetID), Err: db.ErrNotInProject}
		}
	}
	return nil
}

func applyTargetText(d *db.DB, tx *sql.Tx, t *db.Target, a updateTargetArgs) error {
	text, intent := strings.TrimSpace(a.Text), strings.TrimSpace(a.Intent)
	if text == "" && intent == "" {
		return nil
	}
	if text != "" {
		t.Text = text
	}
	if intent != "" {
		t.Intent = intent
	}
	// A targeted UPDATE (I4): db.UpdateTarget rewrites the whole row and
	// re-derives progress from status for a leaf, which would silently
	// reset a progress set earlier just because the agent renamed the
	// target in the same call that leaves status alone.
	if err := d.UpdateTargetTextTx(tx, t.ID, t.Text, t.Intent); err != nil {
		return fmt.Errorf("updating target: %w", err)
	}
	return nil
}

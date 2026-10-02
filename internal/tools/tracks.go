package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type createTrackArgs struct {
	Text    string `json:"text" jsonschema:"the track title / what to watch, at most 200 characters"`
	Context string `json:"context,omitempty" jsonschema:"why it matters / what to watch for"`
	Reason  string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// NewCreateTrack builds the create_track write tool: a new narrative track to
// watch a topic over time, in the owner manual-create shape
// (origin='custom', enabled=1) via db.CreateCustomTrack. Visible on the
// reaction path and in the main chat.
func NewCreateTrack() *Tool {
	schema, err := jsonschema.For[createTrackArgs](nil)
	if err != nil {
		panic("create_track schema: " + err.Error())
	}
	return &Tool{
		Name: "create_track",
		Description: "Propose a new narrative track to watch a topic over time in the owner's Watchtower " +
			"tracks list. The owner approves it in the chat before it is created. Use it when the owner asks to " +
			"keep an eye on or follow something over time.",
		InputSchema: schema,
		Access:      AccessWrite,
		// The reaction path (REACT-02 binds the reacted message) and the main
		// chat, where the owner asks for it directly. Never the target chat:
		// its mandate forbids creating work outside the target's vertical line
		// (TGT-BRIEF-01 axis 3).
		Surfaces: []string{"reaction", "main"},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a createTrackArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			text := strings.TrimSpace(a.Text)
			switch {
			case text == "":
				return &ValidationError{Msg: "text is required"}
			case len([]rune(text)) > 200:
				return &ValidationError{Msg: "text must be at most 200 characters"}
			}
			return nil
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a createTrackArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_track args: %w", err)
			}
			id, err := d.CreateCustomTrack(db.Track{
				Text:    strings.TrimSpace(a.Text),
				Context: strings.TrimSpace(a.Context),
			})
			if err != nil {
				return nil, fmt.Errorf("creating track: %w", err)
			}
			return map[string]any{"track_id": id}, nil
		},
	}
}

// trackFilterArgs is the selection get_track_counts and dismiss_tracks share.
type trackFilterArgs struct {
	Origin        string `json:"origin,omitempty" jsonschema:"auto (found by the pipeline) or custom (created by the owner); empty = both"`
	UpdatedBefore string `json:"updated_before,omitempty" jsonschema:"YYYY-MM-DD: only tracks with no update since this date"`
	CreatedBefore string `json:"created_before,omitempty" jsonschema:"YYYY-MM-DD: only tracks created before this date"`
}

// selection validates the filter and turns it into a db.TrackSelection.
func (f trackFilterArgs) selection() (db.TrackSelection, error) {
	updated, err := dateBound(f.UpdatedBefore, "updated_before", "T00:00:00Z")
	if err != nil {
		return db.TrackSelection{}, err
	}
	created, err := dateBound(f.CreatedBefore, "created_before", "T00:00:00Z")
	if err != nil {
		return db.TrackSelection{}, err
	}
	if err := validateEnum("origin", f.Origin, "auto", "custom"); err != nil {
		return db.TrackSelection{}, err
	}
	return db.TrackSelection{Origin: f.Origin, UpdatedBefore: updated, CreatedBefore: created}, nil
}

// describe is the filter in the owner's words, for the proposal card.
func (f trackFilterArgs) describe() []string {
	var parts []string
	if f.Origin != "" {
		parts = append(parts, f.Origin+" tracks only")
	}
	if f.UpdatedBefore != "" {
		parts = append(parts, "no update since "+f.UpdatedBefore)
	}
	if f.CreatedBefore != "" {
		parts = append(parts, "created before "+f.CreatedBefore)
	}
	return parts
}

// NewGetTrackCounts builds the get_track_counts read tool: how many tracks a filter
// matches, grouped, without paging the rows into the model's context.
func NewGetTrackCounts() *Tool {
	return &Tool{
		Name: "get_track_counts",
		Description: "Count tracks without listing them: active and dismissed totals, active tracks grouped by origin " +
			"(auto/custom), ownership, priority and last-update age (7d/30d/90d/older), plus the 3 most recently " +
			"updated. Optional filters: origin, updated_before, created_before. Use it to answer \"how many tracks\" " +
			"and before proposing dismiss_tracks.",
		InputSchema: mustSchema[trackFilterArgs]("get_track_counts"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a trackFilterArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			sel, err := a.selection()
			if err != nil {
				return nil, err
			}
			counts, err := d.CountTracks(sel, time.Now())
			if err != nil {
				return nil, fmt.Errorf("counting tracks: %w", err)
			}
			return counts, nil
		},
	}
}

type dismissTracksFilter struct {
	trackFilterArgs
	ExceptIDs []int `json:"except_ids,omitempty" jsonschema:"ids of tracks to keep"`
}

// selection is the filter plus the ids it keeps.
func (f dismissTracksFilter) selection() (db.TrackSelection, error) {
	sel, err := f.trackFilterArgs.selection()
	if err != nil {
		return sel, err
	}
	sel.ExceptIDs = f.ExceptIDs
	return sel, nil
}

// dismissTracksArgs is both the model's call and the stored proposal. The
// resolved_* fields and summary/sample_titles are pinned by Normalize at
// propose time; Execute dismisses resolved_ids and nothing else.
type dismissTracksArgs struct {
	IDs          []int                `json:"ids,omitempty" jsonschema:"ids of the tracks to dismiss; pass ids OR filter"`
	Filter       *dismissTracksFilter `json:"filter,omitempty" jsonschema:"dismiss every active track matching this filter; an empty object means every active track"`
	Reason       string               `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
	ResolvedIDs  []int                `json:"resolved_ids,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	Summary      string               `json:"summary,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	SampleTitles []string             `json:"sample_titles,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
}

// dismissSampleSize is how many titles the proposal card previews.
const dismissSampleSize = 5

// NewDismissTracks builds the dismiss_tracks write tool: a bulk soft dismiss
// (dismissed_at, reversible from the Tracks tab) of explicit ids or of every
// active track a filter matches. The filter is resolved to concrete ids at
// propose time, so Approve applies exactly the set the card counted.
// AlwaysAsk: never auto-executed, whatever the owner's trust settings.
func NewDismissTracks() *Tool {
	schema, err := jsonschema.For[dismissTracksArgs](nil)
	if err != nil {
		panic("dismiss_tracks schema: " + err.Error())
	}
	return &Tool{
		Name: "dismiss_tracks",
		Description: "Propose dismissing tracks in bulk (a soft, reversible dismiss: they leave the Tracks list and can " +
			"be restored). Pass ids, or filter for every active track matching origin/updated_before/created_before " +
			"minus except_ids — {} means all active tracks. The owner sees the count and sample titles and approves " +
			"in the chat. Call get_track_counts first to see what a filter matches.",
		InputSchema: schema,
		Access:      AccessWrite,
		AlwaysAsk:   true,
		// The main chat only: the target chat's mandate stays on its own
		// vertical line (TGT-BRIEF-01 axis 3), the reaction path has no
		// track to bind to.
		Surfaces:  []string{"main"},
		Validate:  validateDismissTracks,
		Normalize: normalizeDismissTracks,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a dismissTracksArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding dismiss_tracks args: %w", err)
			}
			if len(a.ResolvedIDs) == 0 {
				return nil, errors.New("dismiss_tracks proposal carries no pinned track ids")
			}
			n, err := d.DismissTracks(a.ResolvedIDs)
			if err != nil {
				return nil, err
			}
			result := map[string]any{"dismissed": n, "skipped": len(a.ResolvedIDs) - n}
			if skipped := len(a.ResolvedIDs) - n; skipped > 0 {
				// The card shows a result warning: the owner approved a count
				// that no longer held.
				result["warning"] = fmt.Sprintf("%d of %d tracks were already dismissed or deleted since the proposal", skipped, len(a.ResolvedIDs))
			}
			return result, nil
		},
	}
}

func validateDismissTracks(_ context.Context, _ *db.DB, raw json.RawMessage) error {
	var a dismissTracksArgs
	if err := decodeStrict(raw, &a); err != nil {
		return err
	}
	if len(a.ResolvedIDs) > 0 || a.Summary != "" || len(a.SampleTitles) > 0 {
		return &ValidationError{Msg: "resolved_ids, summary and sample_titles are filled in automatically; do not set them"}
	}
	switch {
	case len(a.IDs) > 0 && a.Filter != nil:
		return &ValidationError{Msg: "pass ids or filter, not both"}
	case len(a.IDs) == 0 && a.Filter == nil:
		return &ValidationError{Msg: "pass ids, or filter ({} for every active track)"}
	case a.Filter != nil:
		if _, err := a.Filter.selection(); err != nil {
			return err
		}
		return validTrackIDs(a.Filter.ExceptIDs)
	}
	return validTrackIDs(a.IDs)
}

// normalizeDismissTracks pins the proposal: the active tracks the call
// selects right now become resolved_ids, with the card's summary line and a
// few sample titles. Selecting nothing is a model-facing refusal.
func normalizeDismissTracks(_ context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
	var a dismissTracksArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, fmt.Errorf("decoding dismiss_tracks args: %w", err)
	}
	pick := pickTracksByID
	if a.Filter != nil {
		pick = pickTracksByFilter
	}
	picked, notes, err := pick(d, a)
	if err != nil {
		return nil, err
	}
	a.ResolvedIDs = make([]int, len(picked))
	a.SampleTitles = nil
	for i, b := range picked {
		a.ResolvedIDs[i] = b.ID
		if i < dismissSampleSize {
			a.SampleTitles = append(a.SampleTitles, b.Text)
		}
	}
	noun := "tracks"
	if len(picked) == 1 {
		noun = "track"
	}
	a.Summary = fmt.Sprintf("Dismiss %d %s", len(picked), noun)
	if len(notes) > 0 {
		a.Summary += " (" + strings.Join(notes, "; ") + ")"
	}
	return json.Marshal(a)
}

// pickTracksByFilter selects every active track the filter matches.
func pickTracksByFilter(d *db.DB, a dismissTracksArgs) ([]db.TrackBrief, []string, error) {
	// An id to keep that does not exist is a typo the card would hide
	// behind "keeping #N" while the meant track gets dismissed.
	if _, err := knownTracks(d, a.Filter.ExceptIDs); err != nil {
		return nil, nil, err
	}
	sel, err := a.Filter.selection()
	if err != nil {
		return nil, nil, err
	}
	picked, err := d.ActiveTracksMatching(sel)
	if err != nil {
		return nil, nil, err
	}
	if len(picked) == 0 {
		return nil, nil, &ValidationError{Msg: "no active track matches — nothing to dismiss"}
	}
	notes := a.Filter.describe()
	if len(a.Filter.ExceptIDs) > 0 {
		notes = append(notes, "keeping "+idList(a.Filter.ExceptIDs))
	}
	return picked, notes, nil
}

// pickTracksByID selects the given ids that are still active.
func pickTracksByID(d *db.DB, a dismissTracksArgs) ([]db.TrackBrief, []string, error) {
	briefs, err := knownTracks(d, a.IDs)
	if err != nil {
		return nil, nil, err
	}
	var picked []db.TrackBrief
	for _, b := range briefs {
		if !b.Dismissed {
			picked = append(picked, b)
		}
	}
	if len(picked) == 0 {
		return nil, nil, &ValidationError{Msg: "all of these tracks are already dismissed — nothing to dismiss"}
	}
	var notes []string
	if dismissed := len(briefs) - len(picked); dismissed > 0 {
		notes = append(notes, fmt.Sprintf("%d already dismissed", dismissed))
	}
	return picked, notes, nil
}

// validTrackIDs refuses a non-positive id.
func validTrackIDs(ids []int) error {
	for _, id := range ids {
		if id <= 0 {
			return &ValidationError{Msg: fmt.Sprintf("invalid track id %d", id)}
		}
	}
	return nil
}

// knownTracks reads the given tracks (dismissed ones flagged), newest update
// first; an id with no track is a model-facing error.
func knownTracks(d *db.DB, ids []int) ([]db.TrackBrief, error) {
	ids = slices.Compact(slices.Sorted(slices.Values(ids)))
	briefs, err := d.TrackBriefsByID(ids)
	if err != nil {
		return nil, err
	}
	found := make(map[int]bool, len(briefs))
	for _, b := range briefs {
		found[b.ID] = true
	}
	var missing []int
	for _, id := range ids {
		if !found[id] {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		return nil, &ValidationError{Msg: "no track with id " + idList(missing)}
	}
	return briefs, nil
}

// idList renders ids as "#1, #2, #3" — at most ten, then "and N more".
func idList(ids []int) string {
	const shown = 10
	parts := make([]string, 0, shown)
	for i, id := range ids {
		if i == shown {
			break
		}
		parts = append(parts, "#"+strconv.Itoa(id))
	}
	s := strings.Join(parts, ", ")
	if len(ids) > shown {
		s += fmt.Sprintf(" and %d more", len(ids)-shown)
	}
	return s
}

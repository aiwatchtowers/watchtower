package tools

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// trackActionFixture is a target, a custom track linked to it and the
// registry carrying apply_track_action.
type trackActionFixture struct {
	db       *db.DB
	reg      *Registry
	targetID int
	trackID  int
}

func newTrackActionFixture(t *testing.T) trackActionFixture {
	t.Helper()
	d := openDB(t)
	targetID, err := d.CreateTarget(db.Target{Text: "Ship the billing migration", Status: "todo",
		Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	trackID, err := d.CreateCustomTrack(db.Track{Text: "Billing migration", LinkedTargetID: int(targetID)})
	require.NoError(t, err)
	reg := New(d)
	require.NoError(t, reg.Register(NewApplyTrackAction()))
	return trackActionFixture{db: d, reg: reg, targetID: int(targetID), trackID: int(trackID)}
}

// event adds a track event proposing action (status pending).
func (f trackActionFixture) event(t *testing.T, action string) int {
	t.Helper()
	return f.eventOn(t, f.trackID, action, "pending")
}

func (f trackActionFixture) eventOn(t *testing.T, trackID int, action, status string) int {
	t.Helper()
	id, err := f.db.InsertTrackEvent(db.TrackEvent{TrackID: trackID, Summary: "Rollout finished",
		ProposedAction: action, ActionStatus: status})
	require.NoError(t, err)
	return id
}

func trackActionArgs(eventID int) json.RawMessage {
	return json.RawMessage(`{"event_id":` + strconv.Itoa(eventID) + `}`)
}

func inboxBinding(eventID int) Binding {
	return Binding{Surface: InboxSurface, ContextType: "track_event", ContextID: strconv.Itoa(eventID)}
}

// press is the owner's one press: propose, approve, apply.
func (f trackActionFixture) press(t *testing.T, eventID int) *db.AgentAction {
	t.Helper()
	id := f.propose(t, eventID)
	return f.approveApply(t, id)
}

func (f trackActionFixture) propose(t *testing.T, eventID int) int64 {
	t.Helper()
	rc, err := f.reg.Propose(context.Background(), "apply_track_action", trackActionArgs(eventID), inboxBinding(eventID))
	require.NoError(t, err)
	require.Equal(t, "pending", rc.Status, "AlwaysAsk: the press approves it, never trust")
	return rc.ActionID
}

func (f trackActionFixture) approveApply(t *testing.T, id int64) *db.AgentAction {
	t.Helper()
	ok, err := f.reg.Approve(context.Background(), id, nil)
	require.NoError(t, err)
	require.True(t, ok)
	row, err := f.reg.Apply(context.Background(), id)
	require.NoError(t, err)
	return row
}

func (f trackActionFixture) target(t *testing.T) *db.Target {
	t.Helper()
	tg, err := f.db.GetTargetByID(f.targetID)
	require.NoError(t, err)
	return tg
}

func (f trackActionFixture) eventStatus(t *testing.T, id int) string {
	t.Helper()
	e, err := f.db.GetTrackEvent(id)
	require.NoError(t, err)
	return e.ActionStatus
}

func (f trackActionFixture) actionRows(t *testing.T) int {
	t.Helper()
	var n int
	require.NoError(t, f.db.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n))
	return n
}

// targetDump is the whole targets row as text, column by column.
func (f trackActionFixture) targetDump(t *testing.T) map[string]string {
	t.Helper()
	rows, err := f.db.Query(`SELECT * FROM targets WHERE id = ?`, f.targetID)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	require.True(t, rows.Next())
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	require.NoError(t, rows.Scan(ptrs...))
	out := map[string]string{}
	for i, c := range cols {
		out[c] = toText(vals[i])
	}
	require.NoError(t, rows.Err())
	return out
}

func toText(v any) string {
	switch x := v.(type) {
	case nil:
		return "<nil>"
	case []byte:
		return string(x)
	default:
		b, _ := json.Marshal(x)
		return string(b)
	}
}

func resultOf(t *testing.T, row *db.AgentAction) map[string]any {
	t.Helper()
	var out map[string]any
	require.NoError(t, json.Unmarshal([]byte(row.ResultJSON), &out), row.ResultJSON)
	return out
}

func TestApplyTrackAction_UpdateStatus(t *testing.T) {
	f := newTrackActionFixture(t)
	ev := f.event(t, `{"type":"update_status","reason":"rollout finished","status":"done"}`)
	// The history trigger clears status_actor after the write (00086), so
	// record the actor the write itself claimed.
	_, err := f.db.Exec(`CREATE TABLE seen_actor (actor TEXT)`)
	require.NoError(t, err)
	_, err = f.db.Exec(`CREATE TRIGGER record_actor BEFORE UPDATE OF status ON targets
		BEGIN INSERT INTO seen_actor VALUES (NEW.status_actor); END`)
	require.NoError(t, err)

	row := f.press(t, ev)

	require.Equal(t, "applied", row.Status, row.Error)
	tg := f.target(t)
	assert.Equal(t, "done", tg.Status)
	var actor string
	require.NoError(t, f.db.QueryRow(`SELECT COALESCE(actor,'') FROM seen_actor`).Scan(&actor))
	assert.Equal(t, db.ActorOwner, actor, "status_actor='owner'")
	assert.Equal(t, "applied", f.eventStatus(t, ev))
	assert.Equal(t, map[string]any{"target_id": float64(f.targetID), "applied": "set status to done"}, resultOf(t, row))
	assert.Equal(t, "inbox", row.Surface)
	assert.Equal(t, "track_event", row.ContextType)
	assert.Equal(t, strconv.Itoa(ev), row.ContextID)
}

func TestApplyTrackAction_ProgressNotesSubItem(t *testing.T) {
	cases := []struct {
		name    string
		action  string
		applied string
		check   func(t *testing.T, f trackActionFixture)
	}{
		{"progress", `{"type":"update_progress","progress":40}`, "set progress to 40%",
			func(t *testing.T, f trackActionFixture) { assert.InDelta(t, 0.4, f.target(t).Progress, 1e-9) }},
		{"note", `{"type":"update_notes","note":"  Rollout done on staging  "}`, "added a note",
			func(t *testing.T, f trackActionFixture) {
				var notes []db.TargetNote
				require.NoError(t, json.Unmarshal([]byte(f.target(t).Notes), &notes))
				require.Len(t, notes, 1)
				assert.Equal(t, "Rollout done on staging", notes[0].Text, "trimmed, as the Desktop's addNote")
				assert.NotEmpty(t, notes[0].CreatedAt)
			}},
		{"sub item", `{"type":"add_sub_item","text":"Notify finance"}`, "added a sub-item",
			func(t *testing.T, f trackActionFixture) {
				assert.JSONEq(t, `[{"text":"Notify finance","done":false}]`, f.target(t).SubItems)
			}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newTrackActionFixture(t)
			ev := f.event(t, tc.action)
			row := f.press(t, ev)
			require.Equal(t, "applied", row.Status, row.Error)
			assert.Equal(t, tc.applied, resultOf(t, row)["applied"])
			assert.Equal(t, "applied", f.eventStatus(t, ev))
			tc.check(t, f)
		})
	}
}

// Replaces the Swift testApplyTwoAddSubItemActions_BothPersistToLinkedTarget
// assertion: each press reads the list inside its own write.
func TestApplyTrackAction_TwoAddSubItemsBothPersist(t *testing.T) {
	f := newTrackActionFixture(t)
	first := f.event(t, `{"type":"add_sub_item","text":"Notify finance"}`)
	second := f.event(t, `{"type":"add_sub_item","text":"Archive the old tables"}`)

	require.Equal(t, "applied", f.press(t, first).Status)
	require.Equal(t, "applied", f.press(t, second).Status)

	assert.JSONEq(t, `[{"text":"Notify finance","done":false},{"text":"Archive the old tables","done":false}]`,
		f.target(t).SubItems)
}

func TestApplyTrackAction_SecondApplyRefusedTargetUnchanged(t *testing.T) {
	t.Run("a fresh propose after the apply", func(t *testing.T) {
		f := newTrackActionFixture(t)
		ev := f.event(t, `{"type":"add_sub_item","text":"Notify finance"}`)
		require.Equal(t, "applied", f.press(t, ev).Status)
		before, rowsBefore := f.targetDump(t), f.actionRows(t)

		_, err := f.reg.Propose(context.Background(), "apply_track_action", trackActionArgs(ev), inboxBinding(ev))

		var verr *ValidationError
		require.ErrorAs(t, err, &verr)
		assert.Equal(t, "This change was already applied.", verr.Msg)
		assert.Equal(t, rowsBefore, f.actionRows(t), "a refusal writes no row")
		assert.Equal(t, before, f.targetDump(t))
	})
	// The claim: two presses both proposed while the event was pending; the
	// second apply loses the event's claim and writes nothing.
	t.Run("propose twice, apply twice", func(t *testing.T) {
		f := newTrackActionFixture(t)
		ev := f.event(t, `{"type":"add_sub_item","text":"Notify finance"}`)
		a, b := f.propose(t, ev), f.propose(t, ev)
		require.Equal(t, "applied", f.approveApply(t, a).Status)
		before := f.targetDump(t)

		row := f.approveApply(t, b)

		assert.Equal(t, "failed", row.Status)
		assert.Equal(t, "This change was already applied.", row.Error)
		assert.Equal(t, before, f.targetDump(t))
		assert.Equal(t, "applied", f.eventStatus(t, ev))
	})
}

func TestApplyTrackAction_ValidationRefusals(t *testing.T) {
	cases := []struct {
		name string
		args func(t *testing.T, f trackActionFixture) json.RawMessage
		msg  string
	}{
		{"unknown event", func(*testing.T, trackActionFixture) json.RawMessage { return trackActionArgs(9999) },
			"This track event no longer exists."},
		{"empty proposed_action", func(t *testing.T, f trackActionFixture) json.RawMessage {
			return trackActionArgs(f.eventOn(t, f.trackID, "", "pending"))
		}, "This track event proposes no change."},
		{"no proposed change (status none)", func(t *testing.T, f trackActionFixture) json.RawMessage {
			return trackActionArgs(f.eventOn(t, f.trackID, "", "none"))
		}, "This track event proposes no change."},
		{"dismissed", func(t *testing.T, f trackActionFixture) json.RawMessage {
			return trackActionArgs(f.eventOn(t, f.trackID, `{"type":"update_status","status":"done"}`, "dismissed"))
		}, "This change was dismissed."},
		{"track not linked", func(t *testing.T, f trackActionFixture) json.RawMessage {
			standalone, err := f.db.CreateCustomTrack(db.Track{Text: "Standalone"})
			require.NoError(t, err)
			return trackActionArgs(f.eventOn(t, int(standalone), `{"type":"update_status","status":"done"}`, "pending"))
		}, "This track is not linked to a task."},
		{"linked target deleted", func(t *testing.T, f trackActionFixture) json.RawMessage {
			ev := f.event(t, `{"type":"update_status","status":"done"}`)
			// The link names a target that is gone (the FK would null it;
			// an older row or a copied database may still carry the id).
			_, err := f.db.Exec(`PRAGMA foreign_keys = OFF`)
			require.NoError(t, err)
			_, err = f.db.Exec(`DELETE FROM targets WHERE id = ?`, f.targetID)
			require.NoError(t, err)
			_, err = f.db.Exec(`PRAGMA foreign_keys = ON`)
			require.NoError(t, err)
			return trackActionArgs(ev)
		}, "The task this track is linked to no longer exists."},
		{"unsupported type", func(t *testing.T, f trackActionFixture) json.RawMessage {
			return trackActionArgs(f.event(t, `{"type":"link_target","target_id":3,"relation":"blocks"}`))
		}, "This kind of change can't be applied from the Inbox."},
		{"progress 101", func(t *testing.T, f trackActionFixture) json.RawMessage {
			return trackActionArgs(f.event(t, `{"type":"update_progress","progress":101}`))
		}, "The proposed progress must be between 0 and 100."},
		{"empty note", func(t *testing.T, f trackActionFixture) json.RawMessage {
			return trackActionArgs(f.event(t, `{"type":"update_notes","note":"   "}`))
		}, "The proposed note is empty."},
		{"unknown status", func(t *testing.T, f trackActionFixture) json.RawMessage {
			return trackActionArgs(f.event(t, `{"type":"update_status","status":"in_review"}`))
		}, "The proposed status is not one a task can take here."},
		{"extra key", func(t *testing.T, f trackActionFixture) json.RawMessage {
			ev := f.event(t, `{"type":"update_status","status":"done"}`)
			return json.RawMessage(`{"event_id":` + strconv.Itoa(ev) + `,"reason":"mine"}`)
		}, `validating root: unexpected additional properties ["reason"]`}, // the schema gate, ahead of decodeStrict
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newTrackActionFixture(t)
			args := tc.args(t, f)
			_, err := f.reg.Propose(context.Background(), "apply_track_action", args, Binding{Surface: InboxSurface})
			var verr *ValidationError
			require.ErrorAs(t, err, &verr)
			assert.Equal(t, tc.msg, verr.Msg)
			assert.Zero(t, f.actionRows(t), "a refusal writes no agent_actions row")
		})
	}
}

func TestApplyTrackAction_OnlyOnTheInboxSurface(t *testing.T) {
	f := newTrackActionFixture(t)
	tool, ok := f.reg.Get("apply_track_action")
	require.True(t, ok)
	assert.Equal(t, []string{InboxSurface}, tool.Surfaces)
	assert.True(t, tool.AlwaysAsk)
	assert.False(t, tool.External)
	assert.Equal(t, AccessWrite, tool.Access)

	ev := f.event(t, `{"type":"update_status","status":"done"}`)
	_, err := f.reg.Propose(context.Background(), "apply_track_action", trackActionArgs(ev), Binding{Surface: "main"})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Zero(t, f.actionRows(t))

	// SetTrust checks AlwaysAsk before the surface (an order other guards
	// pin), so execute is refused as ErrAlwaysAsk; any level on the inbox
	// is refused as no trust place.
	err = f.reg.SetTrust("apply_track_action", InboxSurface, TrustExecute)
	assert.True(t, errors.Is(err, ErrAlwaysAsk), "got %v", err)
	err = f.reg.SetTrust("apply_track_action", InboxSurface, TrustAsk)
	assert.True(t, errors.Is(err, ErrSurfaceNotOffered), "got %v", err)
	trust, err := f.reg.Trust("apply_track_action", InboxSurface)
	require.NoError(t, err)
	assert.Equal(t, TrustAsk, trust, "no trust row was written")
	assert.Empty(t, TrustSurfaces(tool))
	assert.Empty(t, f.reg.List("main"), "no chat surface lists it")
}

// The target vanishing between Execute's read and its transaction: the status
// write touches no row, so the apply fails and the event's claim rolls back
// instead of reporting a change that was never written. The deletion runs
// from a trigger on the claim itself, inside the same transaction.
func TestApplyTrackAction_TargetGoneBeforeTheWriteRollsBackTheClaim(t *testing.T) {
	f := newTrackActionFixture(t)
	ev := f.event(t, `{"type":"update_status","status":"done"}`)
	id := f.propose(t, ev)
	_, err := f.db.Exec(`PRAGMA foreign_keys = OFF`)
	require.NoError(t, err)
	_, err = f.db.Exec(`CREATE TRIGGER drop_target AFTER UPDATE OF action_status ON track_events
		BEGIN DELETE FROM targets WHERE id = ` + strconv.Itoa(f.targetID) + `; END`)
	require.NoError(t, err)

	row := f.approveApply(t, id)

	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "no rows")
	assert.Equal(t, "pending", f.eventStatus(t, ev), "the claim rolled back with the failed write")
}

package cmd

import (
	"encoding/json"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/ownerconfirm"
)

// runPropose runs `actions propose …` and resets its own flags (runActions
// resets the shared ones), so a flag never leaks into the next run.
func runPropose(t *testing.T, args ...string) (string, error) {
	t.Helper()
	out, err := runActions(t, append([]string{"propose"}, args...)...)
	actionsProposeFlagTool = ""
	actionsProposeFlagSurface = ""
	actionsProposeFlagContextType = ""
	actionsProposeFlagContextID = ""
	actionsProposeFlagArgs = ""
	actionsProposeFlagApprove = false
	return out, err
}

// seedTrackEvent is a target, a custom track linked to it and one event
// proposing to set the target done; it returns the target and event ids.
func seedTrackEvent(t *testing.T, database *db.DB) (int, int) {
	t.Helper()
	targetID, err := database.CreateTarget(db.Target{Text: "Ship the billing migration", Status: "todo",
		Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	trackID, err := database.CreateCustomTrack(db.Track{Text: "Billing migration", LinkedTargetID: int(targetID)})
	require.NoError(t, err)
	eventID, err := database.InsertTrackEvent(db.TrackEvent{TrackID: int(trackID), Summary: "Rollout finished",
		ProposedAction: `{"type":"update_status","reason":"rollout finished","status":"done"}`, ActionStatus: "pending"})
	require.NoError(t, err)
	return int(targetID), eventID
}

// pressArgs is the Desktop's press (Task 6's TrackActionPress), --approve
// added by the caller.
func pressArgs(eventID int, extra ...string) []string {
	id := strconv.Itoa(eventID)
	return append([]string{"--tool", "apply_track_action", "--surface", "inbox", "--context-type", "track_event",
		"--context-id", id, "--args", `{"event_id":` + id + `}`, "--json"}, extra...)
}

type proposeEnvelope struct {
	OK        bool   `json:"ok"`
	AppliedOK bool   `json:"applied_ok"`
	Error     string `json:"error"`
	Action    struct {
		ID      int64           `json:"id"`
		Tool    string          `json:"tool"`
		Status  string          `json:"status"`
		Surface string          `json:"surface"`
		Result  json.RawMessage `json:"result"`
	} `json:"action"`
}

func actionRowCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n))
	return n
}

func targetStatus(t *testing.T, database *db.DB, id int) string {
	t.Helper()
	tg, err := database.GetTargetByID(id)
	require.NoError(t, err)
	return tg.Status
}

func TestActionsPropose_ApproveAppliesOnce(t *testing.T) {
	database := writeActionsConfig(t)
	targetID, eventID := seedTrackEvent(t, database)

	out, err := runPropose(t, pressArgs(eventID, "--approve")...)
	require.NoError(t, err, out)

	var env proposeEnvelope
	require.NoError(t, json.Unmarshal([]byte(out), &env), out)
	assert.True(t, env.OK)
	assert.True(t, env.AppliedOK)
	assert.Empty(t, env.Error)
	assert.Equal(t, "applied", env.Action.Status)
	assert.Equal(t, "inbox", env.Action.Surface)
	assert.Equal(t, "apply_track_action", env.Action.Tool)
	assert.JSONEq(t, `{"target_id":`+strconv.Itoa(targetID)+`,"applied":"set status to done"}`, string(env.Action.Result))

	assert.Equal(t, 1, actionRowCount(t, database))
	var ctxType, ctxID string
	require.NoError(t, database.QueryRow(`SELECT context_type, context_id FROM agent_actions`).Scan(&ctxType, &ctxID))
	assert.Equal(t, "track_event", ctxType)
	assert.Equal(t, strconv.Itoa(eventID), ctxID)
	assert.Equal(t, "done", targetStatus(t, database, targetID))

	// A second press of the same card: refused before a row (Validate),
	// non-zero exit, the target as it was.
	out, err = runPropose(t, pressArgs(eventID, "--approve")...)
	require.Error(t, err, out)
	assert.Contains(t, err.Error(), "This change was already applied.")
	assert.Equal(t, 1, actionRowCount(t, database))
}

func TestActionsPropose_ContextComesFromTheArgsEvent(t *testing.T) {
	cases := map[string]func(id string) []string{
		"a context id naming another event": func(id string) []string {
			return []string{"--context-type", "track_event", "--context-id", "999"}
		},
		"another context type": func(id string) []string {
			return []string{"--context-type", "target", "--context-id", id}
		},
		"no context flags": func(string) []string { return nil },
	}
	for name, flags := range cases {
		t.Run(name, func(t *testing.T) {
			database := writeActionsConfig(t)
			_, eventID := seedTrackEvent(t, database)
			id := strconv.Itoa(eventID)
			args := append([]string{"--tool", "apply_track_action", "--surface", "inbox",
				"--args", `{"event_id":` + id + `}`, "--json"}, flags(id)...)
			out, err := runPropose(t, args...)
			require.NoError(t, err, out)
			var ctxType, ctxID string
			require.NoError(t, database.QueryRow(`SELECT context_type, context_id FROM agent_actions`).Scan(&ctxType, &ctxID))
			assert.Equal(t, "track_event", ctxType)
			assert.Equal(t, id, ctxID)
		})
	}
}

func TestActionsPropose_WithoutApproveLeavesPending(t *testing.T) {
	database := writeActionsConfig(t)
	targetID, eventID := seedTrackEvent(t, database)

	out, err := runPropose(t, pressArgs(eventID)...)
	require.NoError(t, err, out)

	var env proposeEnvelope
	require.NoError(t, json.Unmarshal([]byte(out), &env), out)
	assert.True(t, env.OK)
	assert.False(t, env.AppliedOK)
	assert.Equal(t, "pending", env.Action.Status)
	assert.Equal(t, "todo", targetStatus(t, database, targetID), "target unchanged")
	e, err := database.GetTrackEvent(eventID)
	require.NoError(t, err)
	assert.Equal(t, "pending", e.ActionStatus)
}

func TestActionsPropose_RefusesOtherSurfaces(t *testing.T) {
	database := writeActionsConfig(t)
	targetID, eventID := seedTrackEvent(t, database)
	id := strconv.Itoa(eventID)
	cases := map[string][]string{
		"main surface": {"--tool", "apply_track_action", "--surface", "main", "--context-type", "track_event",
			"--context-id", id, "--args", `{"event_id":` + id + `}`, "--approve", "--json"},
		"a tool not on the inbox": {"--tool", "create_target", "--surface", "inbox",
			"--args", `{"text":"x","reason":"r"}`, "--approve", "--json"},
		"a tool not on the inbox, its own surface": {"--tool", "create_target", "--surface", "main",
			"--args", `{"text":"x","reason":"r"}`, "--approve", "--json"},
		"unknown tool": {"--tool", "no_such_tool", "--surface", "inbox", "--args", `{}`, "--json"},
	}
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			out, err := runPropose(t, args...)
			require.Error(t, err, out)
			assert.Zero(t, actionRowCount(t, database), "no row")
		})
	}
	assert.Equal(t, "todo", targetStatus(t, database, targetID))
	targets, err := database.GetTargets(db.TargetFilter{})
	require.NoError(t, err)
	assert.Len(t, targets, 1, "create_target never ran")
}

// AGENT-07: the press is the owner's approve, so under every agent marker it
// is refused before anything is read or written — with or without --approve.
func TestActionsPropose_RefusedUnderAgentMarkers(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			database := writeActionsConfig(t)
			targetID, eventID := seedTrackEvent(t, database)
			t.Setenv(marker, "1")

			for _, extra := range [][]string{{"--approve"}, nil} {
				out, err := runPropose(t, pressArgs(eventID, extra...)...)
				require.Error(t, err, out)
				assert.Contains(t, err.Error(), marker)
			}
			assert.Zero(t, actionRowCount(t, database))
			assert.Equal(t, "todo", targetStatus(t, database, targetID))
		})
	}
}

// Without a marker --approve still needs the owner's Confirm in the Desktop
// (AGENT-07, board #568): a Deny writes nothing.
func TestActionsPropose_ApproveNeedsTheOwnersConfirmation(t *testing.T) {
	database := writeActionsConfig(t)
	targetID, eventID := seedTrackEvent(t, database)
	got := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Denied}, nil)

	out, err := runPropose(t, pressArgs(eventID, "--approve")...)

	require.Error(t, err, out)
	require.Len(t, *got, 1)
	assert.Contains(t, (*got)[0].Detail, "apply_track_action")
	assert.Contains(t, (*got)[0].Detail, `{"event_id":`+strconv.Itoa(eventID)+`}`)
	assert.Zero(t, actionRowCount(t, database))
	assert.Equal(t, "todo", targetStatus(t, database, targetID))
}

// The owner's press is no assistant tool: Settings → Assistant tools never
// lists it (actions tools --json), while workbench-only tools stay listed.
func TestActionsTools_SkipsInboxOnlyTools(t *testing.T) {
	writeActionsConfig(t)
	out, err := runActions(t, "tools", "--json")
	require.NoError(t, err)
	var listed []struct {
		Name string `json:"name"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &listed), out)
	names := map[string]bool{}
	for _, l := range listed {
		names[l.Name] = true
	}
	assert.False(t, names["apply_track_action"], "the Inbox press is not an assistant tool")
	assert.True(t, names["update_target"], "workbench tools stay listed")
	assert.True(t, names["create_target"])
}

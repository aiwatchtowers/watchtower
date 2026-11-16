package inboxfeed

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// The other Mac screens' write commands (plan Task 9, spec §5.2): Home and
// the Inbox strip, Tracks, Ideas and Decisions, Digests, Day plan,
// Catch-Up and the targets' status. Each is a guarded write (its done
// ledger row commits with it) over one Go writer: inbox.act's own path
// where the Inbox has the same write (outputs, reminders, inbox items,
// briefings, a track's Done, Stop and Restore), else a writer in
// internal/db ported from its Swift query. None is an AGENT-07 owner
// gesture (no CLI twin in its list), so none needs the signed Desktop or a
// hub grant. The SQL lives in internal/db: this package's own queries are
// the feed's (TestChangeTables_CoverEveryTableBuildReads).

// screenTables are what each group of commands writes (Spec.ChangeTables).
var (
	tablesTracks     = []string{"tracks", "digests", "decision_reads", "track_events", "automations", "feedback"}
	tablesIdeas      = []string{"ideas", "idea_mentions", "chat_messages", "chat_conversations"}
	tablesTargets    = []string{"targets", "inbox_items", "target_status_history"}
	tablesPlan       = []string{"day_plan_items", "targets", "inbox_items", "target_status_history"}
	tablesDigests    = []string{"digests", "decision_reads"}
	tablesCatchUp    = []string{"digests", "stream_digests", "tracks", "inbox_items", "briefings", "catchup_recaps"}
	tablesOutputs    = []string{"automation_outputs"}
	tablesBriefings  = []string{"briefings"}
	tablesInboxItems = []string{"inbox_items"}
)

// screenPhrases are each command's verb phrase: a refusal or a fault reads
// "Couldn't <phrase>: <reason>". A command that runs inbox.act's path
// words its refusals as that verb's.
var screenPhrases = map[string]string{
	"outputs.read":               "mark it read",
	"outputs.done":               "mark it done",
	"outputs.dismiss":            "dismiss it",
	"reminders.done":             "mark it done",
	"reminders.snooze":           "snooze",
	"inbox_items.read":           "mark it read",
	"tracks.done":                "mark it done",
	"tracks.restore":             "restore it",
	"briefing.read":              "mark it read",
	"tracks.read":                "mark it read",
	"tracks.stop":                "stop watching",
	"tracks.priority":            "change the priority",
	"tracks.ownership":           "change the ownership",
	"tracks.sub_items":           "update the sub-item",
	"tracks.enabled":             "update the watch",
	"tracks.instruction":         "save the instruction",
	"tracks.delete":              "delete it",
	"tracks.event_status":        "update the event",
	"tracks.events_read":         "mark it read",
	"ideas.status":               "update the idea",
	"ideas.snooze":               "put it off",
	"ideas.merge":                "merge it",
	"ideas.supersede":            "supersede it",
	"ideas.rating":               "rate it",
	"ideas.create":               "save the idea",
	"ideas.delete":               "delete it",
	"ideas.converted":            "convert it",
	"ideas.decision_seen":        "mark it seen",
	"ideas.decisions_seen_all":   "mark them seen",
	"ideas.create_from_chat":     "save it to knowledge",
	"ideas.undo_chat":            "undo it",
	"dayplan.done":               "check it off",
	"dayplan.pending":            "uncheck it",
	"dayplan.delete":             "delete it",
	"dayplan.reorder":            "reorder the plan",
	"dayplan.add":                "add it to the plan",
	"targets.set_status":         "change the status",
	"targets.set_column":         "move it",
	"targets.snooze":             "snooze it",
	"targets.work_on":            "start it",
	"catchup.acknowledge":        "mark it caught up",
	"digests.read":               "mark it read",
	"digests.decision_read":      "mark it read",
	"digests.decisions_read_all": "mark them read",
}

// reasonRecapNotReady refuses catchup.acknowledge of a recap still building
// or failed.
const reasonRecapNotReady = "this recap isn't ready."

// RegisterScreens registers the screens' write commands. deps is inbox.act's
// (the reminder hook's Wake).
func RegisterScreens(r *tower.Registry, deps ActDeps) {
	// Home and the Inbox strip: inbox.act's own paths.
	screen(r, "outputs.read", tablesOutputs, outputMark(deps, api.ActRead))
	screen(r, "outputs.done", tablesOutputs, outputMark(deps, api.ActDone))
	screen(r, "outputs.dismiss", tablesOutputs, outputMark(deps, api.ActDismiss))
	screen(r, "reminders.done", ChangeTables, reminderWrite(deps, api.RefDone))
	screen(r, "reminders.snooze", ChangeTables, reminderWrite(deps, api.RefSnooze))
	screen(r, "briefing.read", tablesBriefings, briefingRead)
	screen(r, "inbox_items.read", tablesInboxItems, inboxItemRead(deps))
	// Tracks.
	screen(r, "tracks.read", tablesTracks, tracksRead)
	screen(r, "tracks.done", tablesTracks, trackVerb(deps, api.RefDone))
	screen(r, "tracks.stop", tablesTracks, tracksStop(deps))
	screen(r, "tracks.restore", tablesTracks, trackVerb(deps, api.RefRestore))
	screen(r, "tracks.priority", tablesTracks, trackPriority)
	screen(r, "tracks.ownership", tablesTracks, trackOwnership)
	screen(r, "tracks.sub_items", tablesTracks, trackSubItem)
	screen(r, "tracks.enabled", tablesTracks, trackEnabled)
	screen(r, "tracks.instruction", tablesTracks, trackInstruction)
	screen(r, "tracks.delete", tablesTracks, trackDelete)
	screen(r, "tracks.event_status", tablesTracks, trackEventStatus)
	screen(r, "tracks.events_read", tablesTracks, trackEventsRead)
	// Ideas and Decisions.
	screen(r, "ideas.status", tablesIdeas, ideaStatus)
	screen(r, "ideas.snooze", tablesIdeas, ideaSnooze)
	screen(r, "ideas.merge", tablesIdeas, ideaMerge)
	screen(r, "ideas.supersede", tablesIdeas, ideaSupersede)
	screen(r, "ideas.rating", tablesIdeas, ideaRating)
	screen(r, "ideas.create", tablesIdeas, ideaCreate)
	screen(r, "ideas.delete", tablesIdeas, ideaDelete)
	screen(r, "ideas.converted", tablesIdeas, ideaConverted)
	screen(r, "ideas.decision_seen", tablesIdeas, decisionSeen)
	screen(r, "ideas.decisions_seen_all", tablesIdeas, decisionsSeenAll)
	screen(r, "ideas.create_from_chat", tablesIdeas, ideaFromChat)
	screen(r, "ideas.undo_chat", tablesIdeas, ideaUndoChat)
	// Day plan.
	screen(r, "dayplan.done", tablesPlan, planItemStatus("done"))
	screen(r, "dayplan.pending", tablesPlan, planItemStatus("pending"))
	screen(r, "dayplan.delete", tablesPlan, planDelete)
	screen(r, "dayplan.reorder", tablesPlan, planReorder)
	screen(r, "dayplan.add", tablesPlan, planAdd)
	// Targets (PROJ-05, PROJ-06, PROJ-19, INBOX-02).
	screen(r, "targets.set_status", tablesTargets, targetSetStatus)
	screen(r, "targets.set_column", tablesTargets, targetSetColumn)
	screen(r, "targets.snooze", tablesTargets, targetSnooze)
	screen(r, "targets.work_on", tablesTargets, targetWorkOn)
	// Catch-Up and Digests.
	screen(r, "catchup.acknowledge", tablesCatchUp, catchUpAcknowledge)
	screen(r, "digests.read", tablesDigests, digestsRead)
	screen(r, "digests.decision_read", tablesDigests, digestDecisionRead)
	screen(r, "digests.decisions_read_all", tablesDigests, digestDecisionsReadAll)
}

// screenHandler is one screen command's body.
type screenHandler[Req, Resp any] func(ctx context.Context, c *tower.Ctx, req Req) (Resp, error)

// screen registers name as a guarded write of tables whose faults and
// missing rows are worded by its phrase.
func screen[Req, Resp any](r *tower.Registry, name string, tables []string, h screenHandler[Req, Resp]) {
	phrase := screenPhrases[name]
	tower.Register(r, name, func(ctx context.Context, c *tower.Ctx, req Req) (Resp, error) {
		res, err := h(ctx, c, req)
		return res, screenFault(phrase, err)
	}, tower.Spec{Idempotent: true, ChangeTables: tables})
}

// screenFault words a writer's error: a refusal passes as is; a missing row
// is not_found, a mismatched board column unsupported with the trigger's
// words, a recap not ready changed; any other error a fault with phrase.
func screenFault(phrase string, err error) error {
	var r *tower.RefusalError
	switch {
	case err == nil, errors.As(err, &r):
		return err
	case errors.Is(err, db.ErrRowNotFound):
		return tower.Refuse(api.CodeNotFound, "Couldn't "+phrase+": "+reasonNotFound)
	case errors.Is(err, db.ErrColumnMismatch):
		return tower.Refuse(api.CodeUnsupported, "Couldn't "+phrase+": "+db.ErrColumnMismatch.Error()+".")
	case errors.Is(err, db.ErrRecapNotReady):
		return tower.Refuse(api.CodeChanged, "Couldn't "+phrase+": "+reasonRecapNotReady)
	}
	var f *actFault
	if errors.As(err, &f) {
		return err
	}
	return &actFault{phrase: phrase, err: err}
}

// writeScreen runs fn in the command's one write transaction.
func writeScreen[T any](ctx context.Context, c *tower.Ctx, fn func(tx *sql.Tx) (T, error)) (T, error) {
	out, err := c.Write(ctx, func(tx *sql.Tx) (any, error) { return fn(tx) })
	if err != nil {
		var zero T
		return zero, err
	}
	return out.(T), nil
}

// done answers a write that changed something; already one that found it
// in place.
func done(already bool, err error) (api.ActResult, error) {
	return api.ActResult{Already: already}, err
}

func ints(ids []int64) []int {
	out := make([]int, len(ids))
	for i, id := range ids {
		out[i] = int(id)
	}
	return out
}

// --- inbox.act's own paths ---

// actAs is an inbox.act actor for one of its verbs, so a screen command
// runs the Inbox's write, guard and words.
func actAs(deps ActDeps, c *tower.Ctx, verb api.ActVerb, p api.ActParams) actor {
	return actor{deps: deps, c: c, req: api.ActRequest{Verb: verb, Params: p}}
}

func outputMark(deps ActDeps, verb api.ActVerb) screenHandler[api.OutputMarkRequest, api.ActResult] {
	return func(ctx context.Context, c *tower.Ctx, req api.OutputMarkRequest) (api.ActResult, error) {
		a := actAs(deps, c, verb, api.ActParams{ContentHash: req.ContentHash})
		res, err := a.stampOutput(ctx, req.ID, map[api.ActVerb]outputStamp{
			api.ActRead: db.MarkOutputReadTx, api.ActDone: db.MarkOutputDoneTx, api.ActDismiss: db.DismissOutputTx,
		}[verb])
		return res, faultOf(a.req, err)
	}
}

func reminderWrite(deps ActDeps, verb api.RefVerb) screenHandler[api.ReminderWriteRequest, api.ActResult] {
	return func(ctx context.Context, c *tower.Ctx, req api.ReminderWriteRequest) (api.ActResult, error) {
		a := actAs(deps, c, api.ActRef, api.ActParams{RefKind: api.RefReminder, RefID: req.ID, RefVerb: verb, Until: req.Until})
		res, err := a.refReminder(ctx, req.ID)
		return res, faultOf(a.req, err)
	}
}

func inboxItemRead(deps ActDeps) screenHandler[api.ScreenIDRequest, api.ActResult] {
	return func(ctx context.Context, c *tower.Ctx, req api.ScreenIDRequest) (api.ActResult, error) {
		a := actAs(deps, c, api.ActRead, api.ActParams{RefKind: api.RefInboxItem, RefID: req.ID})
		res, err := a.readInboxItem(ctx, req.ID)
		return res, faultOf(a.req, err)
	}
}

func trackVerb(deps ActDeps, verb api.RefVerb) screenHandler[api.ScreenIDRequest, api.ActResult] {
	return func(ctx context.Context, c *tower.Ctx, req api.ScreenIDRequest) (api.ActResult, error) {
		a := actAs(deps, c, api.ActRef, api.ActParams{RefKind: api.RefTrack, RefID: req.ID, RefVerb: verb})
		res, err := a.refTrack(ctx, req.ID)
		return res, faultOf(a.req, err)
	}
}

// tracksStop is inbox.act's Stop on each of ids in one transaction; already
// when every one was stopped already.
func tracksStop(deps ActDeps) screenHandler[api.ScreenIDsRequest, api.ActResult] {
	return func(ctx context.Context, c *tower.Ctx, req api.ScreenIDsRequest) (api.ActResult, error) {
		a := actAs(deps, c, api.ActRef, api.ActParams{RefKind: api.RefTrack, RefVerb: api.RefStop})
		bound := make([]bool, len(req.IDs))
		for i, id := range req.IDs {
			b, err := a.boundRecipeGate(ctx, int(id), api.RefStop)
			if err != nil {
				return api.ActResult{}, err
			}
			bound[i] = b
		}
		res, err := writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
			all := true
			for i, id := range req.IDs {
				r, err := a.trackVerbTx(tx, int(id), api.RefStop, bound[i])
				if err != nil {
					return api.ActResult{}, err
				}
				all = all && r.Already
			}
			return api.ActResult{Already: all}, nil
		})
		return res, faultOf(a.req, err)
	}
}

func briefingRead(ctx context.Context, c *tower.Ctx, req api.ScreenIDsRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		unread, err := db.UnreadBriefingIDsTx(tx, ints(req.IDs))
		if err != nil || len(unread) == 0 {
			return already, err
		}
		return api.ActResult{}, db.MarkBriefingReadTx(tx, unread)
	})
}

// --- tracks ---

func tracksRead(ctx context.Context, c *tower.Ctx, req api.ScreenIDsRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.MarkTracksReadTx(tx, ints(req.IDs))
	})
}

func trackPriority(ctx context.Context, c *tower.Ctx, req api.TrackPriorityRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.SetTrackPriorityTx(tx, int(req.ID), req.Priority)
	})
}

func trackOwnership(ctx context.Context, c *tower.Ctx, req api.TrackOwnershipRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.SetTrackOwnershipTx(tx, int(req.ID), req.Ownership)
	})
}

func trackSubItem(ctx context.Context, c *tower.Ctx, req api.TrackSubItemRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.SetTrackSubItemTx(tx, int(req.ID), req.Index, req.Done))
	})
}

func trackEnabled(ctx context.Context, c *tower.Ctx, req api.TrackEnabledRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.SetTrackEnabledTx(tx, int(req.ID), req.Enabled)
	})
}

func trackInstruction(ctx context.Context, c *tower.Ctx, req api.TrackInstructionRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.SetTrackInstructionTx(tx, int(req.ID), req.Instruction)
	})
}

func trackDelete(ctx context.Context, c *tower.Ctx, req api.ScreenIDRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.DeleteTrackTx(tx, int(req.ID)))
	})
}

func trackEventStatus(ctx context.Context, c *tower.Ctx, req api.TrackEventStatusRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.SetTrackEventStatusTx(tx, int(req.EventID), req.Status))
	})
}

func trackEventsRead(ctx context.Context, c *tower.Ctx, req api.TrackEventsReadRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.MarkTrackEventsReadTx(tx, int(req.TrackID), int(req.EventID))
	})
}

// --- ideas ---

func ideaStatus(ctx context.Context, c *tower.Ctx, req api.IdeaStatusRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.SetIdeaStatusTx(tx, int(req.ID), req.Status))
	})
}

func ideaSnooze(ctx context.Context, c *tower.Ctx, req api.IdeaSnoozeRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.SnoozeIdeaUntilTx(tx, int(req.ID), req.Until))
	})
}

func ideaMerge(ctx context.Context, c *tower.Ctx, req api.IdeaMergeRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.MergeIdeaTx(tx, int(req.ID), int(req.Into)))
	})
}

func ideaSupersede(ctx context.Context, c *tower.Ctx, req api.IdeaSupersedeRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.SupersedeIdeaTx(tx, int(req.ID), req.By))
	})
}

func ideaRating(ctx context.Context, c *tower.Ctx, req api.IdeaRatingRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.SetIdeaRatingTx(tx, int(req.ID), req.Rating, req.Comment)
	})
}

func ideaCreate(ctx context.Context, c *tower.Ctx, req api.IdeaCreateRequest) (api.CreatedResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.CreatedResult, error) {
		id, err := c.DB.CreateManualIdeaTx(tx, req.Kind, req.Title, req.Essence, c.Now())
		return api.CreatedResult{ID: id}, err
	})
}

func ideaDelete(ctx context.Context, c *tower.Ctx, req api.ScreenIDRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.DeleteIdeaTx(tx, int(req.ID)))
	})
}

func ideaConverted(ctx context.Context, c *tower.Ctx, req api.IdeaConvertedRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.MarkIdeaConvertedTx(tx, int(req.ID), req.TargetID))
	})
}

func decisionSeen(ctx context.Context, c *tower.Ctx, req api.ScreenIDRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.MarkDecisionSeenTx(tx, int(req.ID))
	})
}

func decisionsSeenAll(ctx context.Context, c *tower.Ctx, _ api.DecisionsSeenAllRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.MarkAllDecisionsSeenTx(tx)
	})
}

func ideaFromChat(ctx context.Context, c *tower.Ctx, req api.IdeaFromChatRequest) (api.CreatedResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.CreatedResult, error) {
		id, err := db.CreateIdeaFromChatTx(tx, req.Kind, req.Body, req.ConversationID, req.MessageID)
		return api.CreatedResult{ID: id}, err
	})
}

func ideaUndoChat(ctx context.Context, c *tower.Ctx, req api.IdeaUndoChatRequest) (api.UndoChatResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.UndoChatResult, error) {
		undone, err := db.UndoChatIdeaTx(tx, req.ID, req.CreatedUpdatedAt)
		return api.UndoChatResult{Undone: undone}, err
	})
}

// --- day plan ---

// planItemStatus checks an item off or back (DayPlanViewModel.
// setItemStatus): with cascade its task follows as the owner's write; a
// task deleted meanwhile leaves the item marked alone, with Swift's line.
func planItemStatus(status string) screenHandler[api.PlanItemStatusRequest, api.ActResult] {
	return func(ctx context.Context, c *tower.Ctx, req api.PlanItemStatusRequest) (api.ActResult, error) {
		return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
			cur, err := db.PlanItemStatusTx(tx, req.ItemID)
			if err != nil {
				return api.ActResult{}, err
			}
			if cur == status {
				return already, nil
			}
			var res api.ActResult
			cascade := req.Cascade
			if cascade {
				taskID, gone, err := db.PlanItemTaskGoneTx(tx, req.ItemID)
				if err != nil {
					return api.ActResult{}, err
				}
				if gone {
					cascade = false
					res.Note = fmt.Sprintf("Updated the plan item only: target #%d no longer exists (it may have been deleted elsewhere)", taskID)
				}
			}
			return res, db.SetPlanItemStatusTx(tx, req.ItemID, status, cascade)
		})
	}
}

func planDelete(ctx context.Context, c *tower.Ctx, req api.PlanItemRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return done(db.DeleteOwnerPlanItemTx(tx, req.ItemID))
	})
}

func planReorder(ctx context.Context, c *tower.Ctx, req api.PlanReorderRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.ReorderPlanItemsTx(tx, req.PlanID, req.OrderedIDs)
	})
}

func planAdd(ctx context.Context, c *tower.Ctx, req api.PlanAddRequest) (api.CreatedResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.CreatedResult, error) {
		id, err := db.AddManualPlanItemTx(tx, req.PlanID, db.ManualPlanItem{
			Kind: req.Kind, Title: req.Title, StartTime: req.StartTime, EndTime: req.EndTime,
		})
		return api.CreatedResult{ID: id}, err
	})
}

// --- targets ---

func targetSetStatus(ctx context.Context, c *tower.Ctx, req api.TargetStatusRequest) (api.TargetStatusResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.TargetStatusResult, error) {
		rolled, err := db.SetTargetStatusOwnerTx(tx, req.ID, req.Status)
		return api.TargetStatusResult{RolledUp: rolled}, err
	})
}

func targetSetColumn(ctx context.Context, c *tower.Ctx, req api.TargetColumnRequest) (api.TargetStatusResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.TargetStatusResult, error) {
		rolled, err := db.SetTargetColumnOwnerTx(tx, req.ID, req.Status, req.ColumnID)
		return api.TargetStatusResult{RolledUp: rolled}, err
	})
}

func targetSnooze(ctx context.Context, c *tower.Ctx, req api.TargetSnoozeRequest) (api.TargetStatusResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.TargetStatusResult, error) {
		rolled, err := db.SnoozeTargetOwnerTx(tx, req.ID, req.Until)
		return api.TargetStatusResult{RolledUp: rolled}, err
	})
}

func targetWorkOn(ctx context.Context, c *tower.Ctx, req api.ScreenIDRequest) (api.WorkOnResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.WorkOnResult, error) {
		moved, rolled, err := db.MarkInProgressOnWorkOnTx(tx, req.ID)
		return api.WorkOnResult{Moved: moved, RolledUp: rolled}, err
	})
}

// --- catch-up and digests ---

func catchUpAcknowledge(ctx context.Context, c *tower.Ctx, req api.ScreenIDRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.AcknowledgeCatchupTx(tx, req.ID)
	})
}

func digestsRead(ctx context.Context, c *tower.Ctx, req api.ScreenIDsRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.MarkDigestsReadTx(tx, ints(req.IDs))
	})
}

func digestDecisionRead(ctx context.Context, c *tower.Ctx, req api.DigestDecisionReadRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.MarkDecisionReadTx(tx, int(req.DigestID), req.Idx)
	})
}

func digestDecisionsReadAll(ctx context.Context, c *tower.Ctx, req api.DigestRequest) (api.ActResult, error) {
	return writeScreen(ctx, c, func(tx *sql.Tx) (api.ActResult, error) {
		return api.ActResult{}, db.MarkDigestDecisionsReadTx(tx, int(req.DigestID))
	})
}

package cmd

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/workbenchmethod"
)

// TestProj13_ModeTable is spec 2026-10-15 §7.1: what each ask guard mode and
// the finish check change against the Part 4.5 table (strict with the finish
// check on is decideStop itself, guarded by the existing PROJ-13 tests).
func TestProj13_ModeTable(t *testing.T) {
	chat := &askGuardVerdict{Request: askRequestChat, Question: "Q?"}
	full := &askGuardVerdict{Request: askRequestFull}
	done := &askGuardVerdict{Request: askRequestNone, CompleteUnreported: true}
	chatDone := &askGuardVerdict{Request: askRequestChat, Question: "Q?", CompleteUnreported: true}
	covered := &askGuardVerdict{Request: askRequestFull, NamesAsk: true}
	present := askGuardResolution{Matched: true, Recordable: true, Present: true}
	away := askGuardResolution{Matched: true, Recordable: true}
	outside := askGuardResolution{}
	strictNoFinish := askGuardModes{askGuard: workbenchmethod.AskGuardStrict}
	soft := askGuardModes{askGuard: workbenchmethod.AskGuardSoft, finishCheck: true}
	softNoFinish := askGuardModes{askGuard: workbenchmethod.AskGuardSoft}
	off := askGuardModes{askGuard: workbenchmethod.AskGuardOff, finishCheck: true}
	offNoFinish := askGuardModes{askGuard: workbenchmethod.AskGuardOff}
	for _, tc := range []struct {
		name   string
		m      askGuardModes
		active bool
		v      *askGuardVerdict
		r      askGuardResolution
		want   stopDecision
	}{
		{"strict, finish off: an away chat is still sent back", strictNoFinish, false, chat, away, stopDecision{Reason: askGuardReasonAway, Clear: true}},
		{"strict, finish off: a full request is still sent back", strictNoFinish, false, full, present, stopDecision{Reason: askGuardReasonFull, Clear: true}},
		{"strict, finish off: complete work passes", strictNoFinish, false, done, present, stopDecision{Clear: true}},
		{"strict, finish off: a present chat is recorded", strictNoFinish, false, chat, present, stopDecision{Record: true}},
		{"soft: an away chat is recorded", soft, false, chat, away, stopDecision{Record: true}},
		{"soft: a present chat is recorded", soft, false, chat, present, stopDecision{Record: true}},
		{"soft: a full request is recorded as full", soft, false, full, away, stopDecision{Record: true, Full: true}},
		{"soft: the named ask covers itself", soft, false, covered, away, stopDecision{Clear: true}},
		{"soft: outside a Desktop row there is nothing to record", soft, false, chat, outside, stopDecision{Clear: true}},
		{"soft: complete work is sent back by the finish check", soft, false, done, away, stopDecision{Reason: askGuardReasonFinish, Clear: true}},
		{"soft: complete work with a question", soft, false, chatDone, away, stopDecision{Reason: askGuardReasonFinishAsk, Clear: true}},
		{"soft, finish off: complete work passes", softNoFinish, false, done, away, stopDecision{Clear: true}},
		{"soft, finish off: a full request is recorded", softNoFinish, false, full, away, stopDecision{Record: true, Full: true}},
		{"soft, continued: a full request is recorded, never blocked", soft, true, full, away, stopDecision{Record: true, Full: true}},
		{"soft, continued: complete work never blocks", soft, true, done, away, stopDecision{Clear: true}},
		{"off: a chat passes, nothing recorded or cleared", off, false, chat, away, stopDecision{}},
		{"off: a full request passes", off, false, full, away, stopDecision{}},
		{"off: complete work is sent back by the finish check", off, false, done, away, stopDecision{Reason: askGuardReasonFinish}},
		{"off, continued: never blocks", off, true, done, away, stopDecision{}},
		{"off, finish off: complete work passes", offNoFinish, false, done, away, stopDecision{}},
	} {
		assert.Equal(t, tc.want, decideStopMode(tc.m, tc.active, false, tc.v, tc.r), tc.name)
	}
	assert.Equal(t, stopDecision{}, decideStopMode(off, false, true, nil, away), "off: an empty message clears nothing")
	assert.Equal(t, stopDecision{Clear: true}, decideStopMode(soft, false, true, nil, away), "soft: an empty message clears")
	assert.Equal(t, decideStop(false, false, chat, away), decideStopMode(strictModes, false, false, chat, away),
		"strict and on is the Part 4.5 table")
}

// TestProj13_SoftNeverSendsBackAndAlwaysRecords: under soft, with the owner
// away, a short question and a full request both pass and are recorded — the
// full one with the message's own text, marked Full (spec §7.1).
func TestProj13_SoftNeverSendsBackAndAlwaysRecords(t *testing.T) {
	const fullMessage = "Please review docs/specs/a.md and run the staging check before I go on."
	for _, tc := range []struct {
		name, message, verdict string
		want                   db.ChatQuestion
	}{
		{"chat", e1Message, e1Verdict, db.ChatQuestion{Question: "Use snake_case or camelCase for the new keys?",
			Options: []db.ChatQuestionOption{{Label: "snake_case"}, {Label: "camelCase"}}}},
		{"full", fullMessage, verdictJSON("full"),
			db.ChatQuestion{Question: fullMessage, Options: []db.ChatQuestionOption{}, Level: asks.LevelFull}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := stopGuardFixture(t)
			require.NoError(t, database.SetWorkbenchMethodology(pid, db.WorkbenchMethodology{AskGuard: workbenchmethod.AskGuardSoft}))
			useAskGuardGen(t, &stubAskGuardGen{reply: tc.verdict})

			out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(tc.message, false)))

			require.NoError(t, err)
			assert.Empty(t, out, "soft never sends a request back")
			assert.Equal(t, &tc.want, storedChatQuestion(t, database, row))
		})
	}
}

func TestAskGuardFullTextKeepsTheEnd(t *testing.T) {
	assert.Equal(t, "short", askGuardFullText("  short \n"))
	long := strings.Repeat("a", 10) + strings.Repeat("b", askGuardFullQuestionRunes)
	got := askGuardFullText(long)
	assert.Equal(t, askGuardFullQuestionRunes, len([]rune(got)))
	assert.True(t, strings.HasPrefix(got, "…b"))
}

// TestProj13_OffWithFinishOffCallsNoModel: with both checks off — set in
// the app or in the folder file — the Stop guard ends the turn before any
// model call and records or clears nothing (spec §7.1).
func TestProj13_OffWithFinishOffCallsNoModel(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(t *testing.T, database *db.DB, pid int64)
	}{
		{"personal", func(t *testing.T, database *db.DB, pid int64) {
			require.NoError(t, database.SetWorkbenchMethodology(pid, db.WorkbenchMethodology{
				AskGuard: workbenchmethod.AskGuardOff, FinishCheck: workbenchmethod.FinishOff}))
		}},
		{"folder file", func(t *testing.T, database *db.DB, pid int64) {
			writeWorkbenchWorkflow(t, database, pid, "---\nask_guard: off\nfinish_check: off\n---\n")
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := stopGuardFixture(t)
			tc.set(t, database, pid)
			seedOlderQuestion(t, database, pid, row)
			gen := &stubAskGuardGen{reply: verdictJSON("full")}
			useAskGuardGen(t, gen)

			out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload("Review the spec, please.", false)))

			require.NoError(t, err)
			assert.Empty(t, out)
			assert.Zero(t, gen.calls, "no model call")
			q := storedChatQuestion(t, database, row)
			require.NotNil(t, q, "nothing cleared")
			assert.Equal(t, "An older question?", q.Question)
		})
	}
}

// TestProj13_UnreadableModeIsStrict: when the modes cannot be read the
// guard runs strict with the finish check on, whatever the folder file says
// (spec §7: a database failure resolves to strict + on).
func TestProj13_UnreadableModeIsStrict(t *testing.T) {
	database, pid, _ := stopGuardFixture(t)
	writeWorkbenchWorkflow(t, database, pid, "---\nask_guard: off\nfinish_check: off\n---\n")
	_, err := database.Exec(`ALTER TABLE projects DROP COLUMN ask_guard_mode`)
	require.NoError(t, err)
	useAskGuardGen(t, &stubAskGuardGen{reply: verdictJSON("full")})

	out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload("Review the spec, please.", false)))

	require.NoError(t, err)
	assert.Equal(t, guardBlock(t, askGuardReasonFull), out, "strict: a full request is sent back")
	assert.Equal(t, strictModes, askGuardModesFor(filepath.Join(t.TempDir(), "missing.db"), askGuardTarget{workbenchID: pid}),
		"no database at all reads as strict")
}

// The Codex Stop guard follows the modes through its row.
func TestProj13_CodexStopFollowsTheMode(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	require.NoError(t, database.SetWorkbenchMethodology(pid, db.WorkbenchMethodology{AskGuard: workbenchmethod.AskGuardSoft}))
	useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})

	out, _ := runCodexAskStop(t, codexPayload(t, "stop", map[string]any{"last_assistant_message": e1Message}))

	assert.Empty(t, out, "soft: an away question is not sent back")
	q := storedChatQuestion(t, database, row)
	require.NotNil(t, q)
	assert.Equal(t, "Use snake_case or camelCase for the new keys?", q.Question)
}

// writeWorkbenchWorkflow writes the workflow.md of workbench pid's folder.
func writeWorkbenchWorkflow(t *testing.T, database *db.DB, pid int64, content string) {
	t.Helper()
	var folder string
	require.NoError(t, database.QueryRow(`SELECT folder_path FROM projects WHERE id = ?`, pid).Scan(&folder))
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".watchtower"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, workbenchmethod.FileRel), []byte(content), 0o644))
}

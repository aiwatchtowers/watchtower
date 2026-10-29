package cmd

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/instructions"
)

func runInstructions(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetIn(strings.NewReader(stdin))
	rootCmd.SetArgs(append([]string{"instructions"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	rootCmd.SetIn(nil)
	resetSetFlags(append(instructionsCmd.Commands(), instructionsSuggestionCmd.Commands()...)...)
	resetSetFlags(instructionsCmd, instructionsSuggestionCmd, rootCmd)
	return out.String(), err
}

func decodeInstructions(t *testing.T, out string) map[string]any {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	return m
}

func instrKeys(m map[string]any) []string {
	var ks []string
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}

func addSuggestion(t *testing.T, d *db.DB, text string, f db.InstructionField, wb sql.NullInt64, fp string, at time.Time) {
	t.Helper()
	require.NoError(t, d.UpsertInstructionSuggestion(db.InstructionSuggestion{
		Text: text, Field: f, WorkbenchID: wb, SessionCount: 4, WorkbenchCount: 1, Fingerprint: fp}, at))
}

func TestInstructionsShow_PinnedKeys(t *testing.T) {
	d, pid, _ := methodologyWorkbench(t)
	addSuggestion(t, d, "Run the linter first", db.InstructionSession, sql.NullInt64{}, "fp1", time.Now())

	out, err := runInstructions(t, "", "show", "--json", "--workbench", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	m := decodeInstructions(t, out)
	assert.ElementsMatch(t, []string{"ok", "limit", "global", "workbench", "suggestions", "chat_lines"}, instrKeys(m))
	assert.EqualValues(t, instructions.MaxRunes, m["limit"])
	assert.ElementsMatch(t, []string{"session", "procedure", "chat"}, instrKeys(m["global"].(map[string]any)))
	assert.ElementsMatch(t, []string{"id", "session", "procedure"}, instrKeys(m["workbench"].(map[string]any)))
	sugg := m["suggestions"].([]any)
	require.Len(t, sugg, 1)
	s := sugg[0].(map[string]any)
	assert.ElementsMatch(t, []string{"id", "text", "field", "workbench_id", "session_count", "workbench_count", "first_seen_at", "last_seen_at"}, instrKeys(s))
	assert.Nil(t, s["workbench_id"])

	out, err = runInstructions(t, "", "show", "--json")
	require.NoError(t, err)
	m = decodeInstructions(t, out)
	assert.Nil(t, m["workbench"])
	assert.Contains(t, m, "workbench")
}

func TestInstructionsSet_StdinAndLimit(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)

	_, err := runInstructions(t, "Answer in short sentences.\n", "set", "--field", "session", "--stdin", "--json")
	require.NoError(t, err)
	g, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Answer in short sentences.", g.Session)

	out, err := runInstructions(t, strings.Repeat("ж", instructions.MaxRunes+1), "set", "--field", "session", "--stdin", "--json")
	require.Error(t, err)
	m := decodeInstructions(t, out)
	assert.Equal(t, false, m["ok"])
	assert.Contains(t, m["error"], "session instructions")
	g, _ = d.GetOwnerInstructions()
	assert.Equal(t, "Answer in short sentences.", g.Session)

	_, err = runInstructions(t, "", "set", "--field", "session", "--stdin", "--json")
	require.NoError(t, err)
	g, _ = d.GetOwnerInstructions()
	assert.Empty(t, g.Session)
}

func TestInstructionsSuggestionAdd_AppendsAndMarks(t *testing.T) {
	d, pid, _ := methodologyWorkbench(t)
	require.NoError(t, d.SetWorkbenchInstruction(pid, db.InstructionProcedure, "Write a test first."))
	addSuggestion(t, d, "Update the changelog", db.InstructionProcedure, sql.NullInt64{Int64: pid, Valid: true}, "fp1", time.Now())
	s := mustOpenSuggestion(t, d)

	out, err := runInstructions(t, "", "suggestion", "add", strconv.FormatInt(s.ID, 10), "--json")
	require.NoError(t, err)
	assert.Equal(t, true, decodeInstructions(t, out)["ok"])
	wb, err := d.GetWorkbenchInstructions(pid)
	require.NoError(t, err)
	assert.Equal(t, "Write a test first.\nUpdate the changelog", wb.Procedure)
	got, err := d.GetInstructionSuggestion(s.ID)
	require.NoError(t, err)
	assert.Equal(t, "added", got.Status)
}

func TestInstructionsSuggestionAdd_ChatFieldAppendsToChat(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "SHARED"))
	require.NoError(t, d.SetOwnerInstruction(db.InstructionChat, "Typed in Settings"))
	line, outcome, err := d.RememberChatLine("Answer in Russian", 1, 2, time.Now(), instructions.MaxRunes)
	require.NoError(t, err)
	require.Equal(t, db.RememberAdded, outcome)
	addSuggestion(t, d, "Answer briefly", db.InstructionChat, sql.NullInt64{}, "fp1", time.Now())
	s := mustOpenSuggestion(t, d)

	_, err = runInstructions(t, "", "suggestion", "add", strconv.FormatInt(s.ID, 10), "--json")
	require.NoError(t, err)
	g, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "SHARED", g.Session)
	assert.Equal(t, "Typed in Settings\nAnswer in Russian\nAnswer briefly", g.Chat)
	present, err := d.ListPresentChatLines()
	require.NoError(t, err)
	require.Len(t, present, 1)
	assert.Equal(t, line.ID, present[0].ID)
}

func mustOpenSuggestion(t *testing.T, d *db.DB) db.InstructionSuggestion {
	t.Helper()
	list, err := d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	require.NotEmpty(t, list)
	return list[0]
}

func TestInstructionsSuggestionAdd_OverLimitKeepsOpen(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	long := strings.Repeat("a", instructions.MaxRunes-2)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, long))
	addSuggestion(t, d, "Be brief", db.InstructionSession, sql.NullInt64{}, "fp1", time.Now())
	s := mustOpenSuggestion(t, d)

	out, err := runInstructions(t, "", "suggestion", "add", strconv.FormatInt(s.ID, 10), "--json")
	require.Error(t, err)
	m := decodeInstructions(t, out)
	assert.Equal(t, false, m["ok"])
	assert.Equal(t, "session instructions: adding this line would go over the 1000-character limit — shorten the text first", m["error"])
	got, _ := d.GetInstructionSuggestion(s.ID)
	assert.Equal(t, "open", got.Status)
	g, _ := d.GetOwnerInstructions()
	assert.Equal(t, long, g.Session)

	_, err = runInstructions(t, "", "suggestion", "dismiss", strconv.FormatInt(s.ID, 10), "--json")
	require.NoError(t, err)
	got, _ = d.GetInstructionSuggestion(s.ID)
	assert.Equal(t, "dismissed", got.Status)
}

func TestInstructionsSuggestion_CapsFivePerScope(t *testing.T) {
	d, pid, _ := methodologyWorkbench(t)
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 7; i++ {
		addSuggestion(t, d, "global "+strconv.Itoa(i), db.InstructionSession, sql.NullInt64{}, "g"+strconv.Itoa(i), base.Add(time.Duration(i)*time.Hour))
		addSuggestion(t, d, "wb "+strconv.Itoa(i), db.InstructionSession, sql.NullInt64{Int64: pid, Valid: true}, "w"+strconv.Itoa(i), base.Add(time.Duration(i)*time.Hour))
	}
	out, err := runInstructions(t, "", "show", "--json")
	require.NoError(t, err)
	sugg := decodeInstructions(t, out)["suggestions"].([]any)
	assert.Len(t, sugg, 10)
	assert.Equal(t, "wb 6", sugg[0].(map[string]any)["text"])
}

func TestInstructionsPreview_MatchesBriefSlot(t *testing.T) {
	d, pid, _ := methodologyWorkbench(t)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Be brief."))
	require.NoError(t, d.SetWorkbenchInstruction(pid, db.InstructionProcedure, "Add a test. Never touch issue #0."))
	id := strconv.FormatInt(pid, 10)

	out, err := runInstructions(t, "", "preview", "--json", "--workbench", id)
	require.NoError(t, err)
	m := decodeInstructions(t, out)
	texts, err := instructions.Load(d, pid)
	require.NoError(t, err)
	assert.Equal(t, instructions.BriefSlot(texts), m["brief_slot"])
	assert.Equal(t, instructions.ProcedureFor(texts, "N"), m["procedure"])
	assert.Contains(t, m["procedure"], "follow it for #N:")
	assert.Contains(t, m["procedure"], "Never touch issue #0.", "owner text is not rewritten")
}

func rememberArgs(conv, msg string) []string {
	return []string{"remember", "--conversation", conv, "--message", msg, "--stdin", "--json"}
}

func TestInstructionsRemember_AddsVerbatim(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	out, err := runInstructions(t, "запомни: Отвечай коротко", rememberArgs("3", "7")...)
	require.NoError(t, err)
	m := decodeInstructions(t, out)
	assert.Equal(t, "added", m["outcome"])
	assert.NotNil(t, m["line_id"])
	g, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Отвечай коротко", g.Chat)
}

func TestInstructionsRemember_AlreadyPresent_NoLedgerRow(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	_, err := runInstructions(t, "remember: Be brief", rememberArgs("3", "7")...)
	require.NoError(t, err)
	out, err := runInstructions(t, "Remember:  Be   brief", rememberArgs("3", "8")...)
	require.NoError(t, err)
	m := decodeInstructions(t, out)
	assert.Equal(t, "already_present", m["outcome"])
	assert.Len(t, m["chat_lines"], 1)
	rows, err := d.ChatLinesForMessages([]int64{8})
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestInstructionsRemember_TooLong(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	out, err := runInstructions(t, "remember: "+strings.Repeat("ж", instructions.MaxRunes+1), rememberArgs("3", "7")...)
	require.Error(t, err)
	m := decodeInstructions(t, out)
	assert.Equal(t, false, m["ok"])
	assert.Equal(t, "too_long", m["code"])
	g, _ := d.GetOwnerInstructions()
	assert.Empty(t, g.Chat)
}

func TestInstructionsRemember_Empty(t *testing.T) {
	methodologyWorkbench(t)
	out, err := runInstructions(t, "remember:   ", rememberArgs("3", "7")...)
	require.Error(t, err)
	assert.Equal(t, "empty", decodeInstructions(t, out)["code"])
}

func TestInstructionsRemember_NotACommand(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	out, err := runInstructions(t, "please remember: x", rememberArgs("3", "7")...)
	require.Error(t, err)
	assert.Equal(t, "not_a_command", decodeInstructions(t, out)["code"])
	g, _ := d.GetOwnerInstructions()
	assert.Empty(t, g.Chat)
}

func TestInstructionsRemember_NeedsIDs(t *testing.T) {
	methodologyWorkbench(t)
	_, err := runInstructions(t, "remember: x", "remember", "--stdin", "--json")
	require.Error(t, err)
}

func TestInstructionsForget_Removed(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	out, err := runInstructions(t, "remember: Be brief", rememberArgs("3", "7")...)
	require.NoError(t, err)
	id := strconv.FormatInt(int64(decodeInstructions(t, out)["line_id"].(float64)), 10)
	out, err = runInstructions(t, "", "forget", id, "--json")
	require.NoError(t, err)
	m := decodeInstructions(t, out)
	assert.Equal(t, true, m["removed"])
	assert.Empty(t, m["chat_lines"])
	g, _ := d.GetOwnerInstructions()
	assert.Empty(t, g.Chat)
}

func TestInstructionsForget_EditedAway(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	out, err := runInstructions(t, "remember: Be brief", rememberArgs("3", "7")...)
	require.NoError(t, err)
	id := strconv.FormatInt(int64(decodeInstructions(t, out)["line_id"].(float64)), 10)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionChat, "Something else"))
	out, err = runInstructions(t, "", "forget", id, "--json")
	require.NoError(t, err)
	assert.Equal(t, false, decodeInstructions(t, out)["removed"])
	g, _ := d.GetOwnerInstructions()
	assert.Equal(t, "Something else", g.Chat)

	out, err = runInstructions(t, "", "forget", "9999", "--json")
	require.Error(t, err)
	assert.Equal(t, "not_found", decodeInstructions(t, out)["code"])
}

func TestInstructionsShow_ChatKeys(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	_, err := runInstructions(t, "remember: One", rememberArgs("3", "7")...)
	require.NoError(t, err)
	_, err = runInstructions(t, "remember: Two", rememberArgs("3", "8")...)
	require.NoError(t, err)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionChat, "Two"))
	out, err := runInstructions(t, "", "show", "--json")
	require.NoError(t, err)
	m := decodeInstructions(t, out)
	assert.Equal(t, "Two", m["global"].(map[string]any)["chat"])
	lines := m["chat_lines"].([]any)
	require.Len(t, lines, 1, "only present lines")
	l := lines[0].(map[string]any)
	assert.ElementsMatch(t, []string{"id", "line", "conversation_id", "message_id", "added_at"}, instrKeys(l))
	assert.Equal(t, "Two", l["line"])
}

func TestInstructionsPreview_ChatSlot(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionChat, "Be brief"))
	out, err := runInstructions(t, "", "preview", "--json")
	require.NoError(t, err)
	g, _ := d.GetOwnerInstructions()
	assert.Equal(t, instructions.ChatSlot(g), decodeInstructions(t, out)["chat_slot"])
	assert.Contains(t, decodeInstructions(t, out)["chat_slot"], "Be brief")
}

func TestInstructionsSet_ChatWithWorkbenchRefused(t *testing.T) {
	d, pid, _ := methodologyWorkbench(t)
	_, err := runInstructions(t, "Be brief", "set", "--field", "chat", "--stdin", "--workbench", strconv.FormatInt(pid, 10))
	require.Error(t, err)
	_, err = runInstructions(t, "Be brief", "set", "--field", "chat", "--stdin")
	require.NoError(t, err)
	g, _ := d.GetOwnerInstructions()
	assert.Equal(t, "Be brief", g.Chat)
}

// A suggestion folded into the coach is decided only there: add and dismiss
// refuse it and change nothing.
func TestSuggestionVerbs_RefuseMovedRow(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	addSuggestion(t, d, "Be brief", db.InstructionSession, sql.NullInt64{}, "fp1", time.Now())
	s := mustOpenSuggestion(t, d)
	pid, err := d.InsertCoachProposal(db.CoachProposal{Fingerprint: "fp", Kind: "add", Destination: "session",
		Title: "Be brief", Why: "w", Metric: "owner_loop", AfterText: "Be brief", Sources: 4}, time.Now())
	require.NoError(t, err)
	require.NoError(t, d.MoveInstructionSuggestion(s.ID, pid))

	for _, verb := range []string{"add", "dismiss"} {
		out, err := runInstructions(t, "", "suggestion", verb, strconv.FormatInt(s.ID, 10), "--json")
		require.ErrorIs(t, err, db.ErrSuggestionMoved, verb)
		m := decodeInstructions(t, out)
		assert.Equal(t, false, m["ok"])
		assert.Contains(t, m["error"], fmt.Sprintf("moved to the coach (proposal #%d)", pid), verb)
	}
	got, err := d.GetInstructionSuggestion(s.ID)
	require.NoError(t, err)
	assert.Equal(t, "open", got.Status)
	g, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Empty(t, g.Session)
}

package cmd

import (
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/instructions"
	"watchtower/internal/workbenchcheck"
)

const (
	slotHeader   = "Owner's instructions (follow in every turn):"
	slotWbHeader = "For this workbench:"
)

func setSessionTexts(t *testing.T, database *db.DB, pid int64, global, wb string) {
	t.Helper()
	require.NoError(t, database.SetOwnerInstruction(db.InstructionSession, global))
	require.NoError(t, database.SetWorkbenchInstruction(pid, db.InstructionSession, wb))
}

func TestProj22_BriefCarriesOwnerInstructions(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	setSessionTexts(t, database, pid, "Answer briefly.", "Use the staging db.")
	unsetTerminalEnv(t)

	out, _ := runBriefHook(t, pid, "")

	want := slotHeader + "\nAnswer briefly.\n" + slotWbHeader + "\nUse the staging db."
	assert.Contains(t, out, want)
}

func TestProj22_BriefOmitsSlotWhenEmpty(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	unsetTerminalEnv(t)

	out, _ := runBriefHook(t, pid, "")

	assert.NotContains(t, out, slotHeader)
}

func TestProj22_FullBoardKeepsWholeSlot(t *testing.T) {
	text := strings.Repeat("я", instructions.MaxRunes)
	slot := instructions.BriefSlot(instructions.Texts{
		Global:    db.OwnerInstructions{Session: text, Procedure: "p"},
		Workbench: db.OwnerInstructions{Session: text},
	})
	var board []db.BoardNode
	for i := 1; i <= 300; i++ {
		board = append(board, briefNode(i, "todo", strings.Repeat("Implement the next part of the plan ", 8)))
	}

	out := renderSessionBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), briefRules,
		"", "Cleanup: /usr/local/bin/watchtower workbench cleanup --session 3", slot)

	assert.Contains(t, out, slot, "the board gives way, never the slot")
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxCharsFor(slot))
	assert.Contains(t, out, "more targets (workbench_board)")
}

// Without instructions the brief keeps today's 4000-rune cap: the cap grows by
// the rendered slot only, never by its maximum.
func TestProj22_NoInstructionsKeepsTodaysBudget(t *testing.T) {
	assert.Equal(t, 4000, briefMaxCharsFor(""))
	assert.Equal(t, 4000+len("x")+1, briefMaxCharsFor("x"), "the slot and its joining newline")

	var board []db.BoardNode
	for i := 1; i <= 300; i++ {
		board = append(board, briefNode(i, "todo", strings.Repeat("Implement the next part of the plan ", 8)))
	}
	out := renderSessionBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), briefRules, "", "", "")
	assert.LessOrEqual(t, utf8.RuneCountInString(out), 4000)
	assert.Greater(t, utf8.RuneCountInString(out), 3900, "a full board uses today's room")

	slot := instructions.BriefSlot(instructions.Texts{Global: db.OwnerInstructions{Session: "Answer briefly."}})
	withSlot := renderSessionBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), briefRules, "", "", slot)
	assert.Equal(t, out+"\n"+slot, withSlot, "the board keeps exactly the same room")
}

func TestProj22_CodexBriefCarriesSlot(t *testing.T) {
	database, pid, _ := codexRowFixture(t, "")
	setSessionTexts(t, database, pid, "Answer briefly.", "")

	out := runCodexBriefHook(t, string(codexHookFixture(t, "session_start_startup")))

	assert.Contains(t, out, slotHeader+"\nAnswer briefly.")
}

func TestProj22_RememberWritesOwnerWordsVerbatim(t *testing.T) {
	d, _, _ := methodologyWorkbench(t)
	_, err := runInstructions(t, "  Запомни:   Отвечай\n коротко,\tбез воды  ", "remember", "--conversation", "1", "--message", "2", "--stdin", "--json")
	require.NoError(t, err)
	g, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Отвечай коротко, без воды", g.Chat, "the owner's words after the prefix, whitespace collapsed")
	assert.Empty(t, g.Session)
	assert.Empty(t, g.Procedure)
	lines, err := d.ListPresentChatLines()
	require.NoError(t, err)
	require.Len(t, lines, 1)
	assert.Equal(t, g.Chat, lines[0].Line)
}

func TestProj22_WorkbenchTextsNeverInChatSlot(t *testing.T) {
	d, pid, _ := methodologyWorkbench(t)
	require.NoError(t, d.SetWorkbenchInstruction(pid, db.InstructionSession, "WB-ONLY-SESSION"))
	require.NoError(t, d.SetWorkbenchInstruction(pid, db.InstructionProcedure, "WB-ONLY-PROCEDURE"))
	require.NoError(t, d.SetOwnerInstruction(db.InstructionProcedure, "GLOBAL-PROCEDURE"))
	require.NoError(t, d.SetOwnerInstruction(db.InstructionChat, "Be brief"))
	out, err := runInstructions(t, "", "preview", "--json", "--workbench", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	slot, _ := decodeInstructions(t, out)["chat_slot"].(string)
	assert.Contains(t, slot, "Be brief")
	for _, banned := range []string{"WB-ONLY-SESSION", "WB-ONLY-PROCEDURE", "GLOBAL-PROCEDURE"} {
		assert.NotContains(t, slot, banned)
	}
}

package cmd

import (
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
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.Contains(t, out, "more targets (workbench_board)")
}

func TestProj22_CodexBriefCarriesSlot(t *testing.T) {
	database, pid, _ := codexRowFixture(t, "")
	setSessionTexts(t, database, pid, "Answer briefly.", "")

	out := runCodexBriefHook(t, string(codexHookFixture(t, "session_start_startup")))

	assert.Contains(t, out, slotHeader+"\nAnswer briefly.")
}

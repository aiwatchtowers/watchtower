package cmd

import (
	"io"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const watchmanBriefLine = "The owner handed this session to Watchman; asks are answered by his twin; do not wait, keep working."

func armBriefSession(t *testing.T, database *db.DB, row int64) {
	t.Helper()
	require.NoError(t, database.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: row, ArmedAt: time.Now(), ArmedBy: "cli"}))
}

// claudeRowFixture is a workbench with a claude terminal row the hook env points at.
func claudeRowFixture(t *testing.T) (database *db.DB, pid, row int64) {
	t.Helper()
	database, pid, _ = codexRowFixture(t, "")
	row = insertHookRow(t, database, pid, "claude")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	return database, pid, row
}

func TestProj12_BriefCarriesWatchmanLineWhileArmed(t *testing.T) {
	database, pid, row := claudeRowFixture(t)
	setSessionTexts(t, database, pid, "Answer briefly.", "")
	armBriefSession(t, database, row)

	out, _ := runBriefHook(t, pid, "")

	slot := slotHeader + "\nAnswer briefly."
	require.Contains(t, out, slot+"\n"+watchmanBriefLine, "the line follows the owner's instructions block")
	require.Contains(t, out, strconv.FormatInt(pid, 10))
}

func TestProj12_BriefWithoutWatchmanLineWhenUnarmed(t *testing.T) {
	database, pid, row := claudeRowFixture(t)
	setSessionTexts(t, database, pid, "Answer briefly.", "")

	out, _ := runBriefHook(t, pid, "")
	require.NotContains(t, out, watchmanBriefLine)

	armBriefSession(t, database, row)
	_, err := database.DeleteWatchmanArming("session", row)
	require.NoError(t, err)
	out, _ = runBriefHook(t, pid, "")
	require.NotContains(t, out, watchmanBriefLine)
}

func TestProj12_BriefIgnoresInheritedRowOfAnotherAgent(t *testing.T) {
	database, pid, row := codexRowFixture(t, "") // an armed codex row inherited into a claude brief
	armBriefSession(t, database, row)

	out, _ := runBriefHook(t, pid, "")
	require.NotContains(t, out, watchmanBriefLine)

	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	require.Equal(t, 1, strings.Count(loadWorkbenchBrief(pid, io.Discard, "codex"), watchmanBriefLine), "the same row in a codex brief of its workbench")
	require.NotContains(t, loadWorkbenchBrief(other, io.Discard, "codex"), watchmanBriefLine, "another workbench")
}

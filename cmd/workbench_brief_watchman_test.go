package cmd

import (
	"strconv"
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

func TestProj12_BriefCarriesWatchmanLineWhileArmed(t *testing.T) {
	database, pid, row := codexRowFixture(t, "")
	setSessionTexts(t, database, pid, "Answer briefly.", "")
	armBriefSession(t, database, row)

	out, _ := runBriefHook(t, pid, "")

	slot := slotHeader + "\nAnswer briefly."
	require.Contains(t, out, slot+"\n"+watchmanBriefLine, "the line follows the owner's instructions block")
	require.Contains(t, out, strconv.FormatInt(pid, 10))
}

func TestProj12_BriefWithoutWatchmanLineWhenUnarmed(t *testing.T) {
	database, pid, row := codexRowFixture(t, "")
	setSessionTexts(t, database, pid, "Answer briefly.", "")

	out, _ := runBriefHook(t, pid, "")
	require.NotContains(t, out, watchmanBriefLine)

	armBriefSession(t, database, row)
	_, err := database.DeleteWatchmanArming("session", row)
	require.NoError(t, err)
	out, _ = runBriefHook(t, pid, "")
	require.NotContains(t, out, watchmanBriefLine)
}

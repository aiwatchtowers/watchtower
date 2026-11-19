package tools

import (
	"database/sql"
	"fmt"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// A folder suggestion is never the Watchman twin's (#2003): not as a filed
// ask, not as a finish's handover.

// folderAskOf files a folder suggestion of session on workbench wb.
func folderAskOf(t *testing.T, d *db.DB, wb, session int64) (db.OwnerAsk, int64) {
	t.Helper()
	ask := db.OwnerAsk{WorkbenchID: wb, SessionID: sql.NullInt64{Int64: session, Valid: true},
		Kind: db.AskKindFolder, Title: "Put /code/hub on the bench?", Payload: `{"path":"/code/hub"}`}
	var id int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		id, _, err = d.InsertOwnerAsk(tx, ask)
		return err
	}))
	return ask, id
}

func TestQueueWatchmanAsk_SkipsAFolderAsk(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	ask, id := folderAskOf(t, fx.d, fx.a, session)
	woke := false
	queueWatchmanAsk(fx.d, ask, id, func() { woke = true })
	assert.Equal(t, 0, watchmanItemCount(t, fx.d))
	assert.False(t, woke)
}

func TestFinishSession_FolderAskIsNoHandover(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	_, id := folderAskOf(t, fx.d, fx.a, session)
	actions := countActions(t, fx.d)
	_, err := proposeIn(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","handover_ask_id":%d,"reason":"r"}`, id))
	assert.Equal(t, fmt.Sprintf("handover_ask_id: ask #%d is a folder suggestion; file a question or check ask that says what is left and why", id),
		refusal(t, err))
	assertNotFinished(t, fx.d, session, actions)
	assert.Equal(t, 0, watchmanItemCount(t, fx.d))
}

func TestMarkWatchmanHandover_SkipsAFolderAsk(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	_, id := folderAskOf(t, fx.d, fx.a, session)
	markWatchmanHandover(fx.d, fx.a, session, 0, id)
	assert.Equal(t, 0, watchmanItemCount(t, fx.d))
	// The database's promotion refuses it on its own too.
	promoted, inserted, err := fx.d.PromoteWatchmanHandover(db.WatchmanItem{WorkbenchID: fx.a, SessionID: session,
		RefID: id, Question: "Put /code/hub on the bench?"}, false)
	require.NoError(t, err)
	assert.False(t, promoted || inserted)
	assert.Equal(t, 0, watchmanItemCount(t, fx.d))
}

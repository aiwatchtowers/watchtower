package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func makeInboxItem(channelID, ts string) InboxItem {
	return InboxItem{
		ChannelID:    channelID,
		MessageTS:    ts,
		SenderUserID: "U1",
		TriggerType:  "mention",
		Snippet:      "needs reply",
		Status:       "pending",
		Priority:     "medium",
	}
}

func TestFindPendingInboxByThread_NotFound(t *testing.T) {
	db := openTestDB(t)
	id, err := db.FindPendingInboxByThread("C1", "missing")
	require.NoError(t, err)
	assert.Equal(t, 0, id, "missing thread returns 0 id, no error")
}

func TestFindPendingInboxByThread_Found(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))

	it := makeInboxItem("C1", "1.000001")
	it.ThreadTS = "0.000001"
	id, err := db.CreateInboxItem(it)
	require.NoError(t, err)
	require.NotZero(t, id)

	got, err := db.FindPendingInboxByThread("C1", "0.000001")
	require.NoError(t, err)
	assert.Equal(t, int(id), got)
}

func TestUpdateInboxItemSnippet(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))
	id, err := db.CreateInboxItem(makeInboxItem("C1", "1.0"))
	require.NoError(t, err)

	require.NoError(t, db.UpdateInboxItemSnippet(int(id), "2.0", "U2", "new snippet", "ctx", "raw text", "https://link"))

	got, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "2.0", got.MessageTS)
	assert.Equal(t, "U2", got.SenderUserID)
	assert.Equal(t, "new snippet", got.Snippet)
	assert.Equal(t, "https://link", got.Permalink)
}

func TestGetInboxItem_Int64(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))
	id, err := db.CreateInboxItem(makeInboxItem("C1", "1.0"))
	require.NoError(t, err)

	got, err := db.GetInboxItem(id)
	require.NoError(t, err)
	assert.Equal(t, id, int64(got.ID))
	assert.Equal(t, "needs reply", got.Snippet)
}

func TestUpdateInboxItemPriority(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))
	id, err := db.CreateInboxItem(makeInboxItem("C1", "1.0"))
	require.NoError(t, err)

	require.NoError(t, db.UpdateInboxItemPriority(int(id), "high"))

	got, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "high", got.Priority)
}

func TestDismissInboxItem(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))
	id, err := db.CreateInboxItem(makeInboxItem("C1", "1.0"))
	require.NoError(t, err)

	require.NoError(t, db.DismissInboxItem(int(id)))

	got, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "dismissed", got.Status)
}

func TestListActionableOpen(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))

	// Pending actionable.
	a := makeInboxItem("C1", "1.0")
	a.ItemClass = "actionable"
	idA, err := db.CreateInboxItem(a)
	require.NoError(t, err)

	// Pending ambient — should be excluded.
	b := makeInboxItem("C1", "2.0")
	b.ItemClass = "ambient"
	_, err = db.CreateInboxItem(b)
	require.NoError(t, err)

	// Resolved actionable — should be excluded.
	c := makeInboxItem("C1", "3.0")
	c.ItemClass = "actionable"
	c.Status = "resolved"
	_, err = db.CreateInboxItem(c)
	require.NoError(t, err)

	got, err := db.ListActionableOpen()
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, int(idA), got[0].ID)
}

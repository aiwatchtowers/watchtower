package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestUpsertUser(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	u := User{
		ID:          "U001",
		Name:        "alice",
		DisplayName: "Alice Smith",
		RealName:    "Alice J. Smith",
		Email:       "alice@example.com",
		IsBot:       false,
		IsDeleted:   false,
		ProfileJSON: `{"title":"Engineer"}`,
	}
	err = db.UpsertUser(u)
	require.NoError(t, err)

	got, err := db.GetUserByID("U001")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "alice", got.Name)
	assert.Equal(t, "Alice Smith", got.DisplayName)
	assert.Equal(t, "alice@example.com", got.Email)
	assert.False(t, got.IsBot)
	assert.NotEmpty(t, got.UpdatedAt)
}

func TestUpsertUserUpdate(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	u := User{ID: "U001", Name: "alice", Email: "alice@old.com"}
	require.NoError(t, db.UpsertUser(u))

	u.Email = "alice@new.com"
	u.DisplayName = "Alice New"
	require.NoError(t, db.UpsertUser(u))

	got, err := db.GetUserByID("U001")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "alice@new.com", got.Email)
	assert.Equal(t, "Alice New", got.DisplayName)
}

func TestGetUserByName(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice"}))
	require.NoError(t, db.UpsertUser(User{ID: "U002", Name: "bob"}))

	got, err := db.GetUserByName("bob")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "U002", got.ID)
}

func TestGetUserByIDNotFound(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	got, err := db.GetUserByID("U999")
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestGetUserByEmailFoldCaseInsensitive(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice", Email: "alice@example.com"}))

	got, err := db.GetUserByEmailFold("ALICE@Example.COM")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "U001", got.ID)
}

func TestGetUserByEmailFoldNotFound(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	got, err := db.GetUserByEmailFold("nobody@example.com")
	require.NoError(t, err)
	assert.Nil(t, got)
}

// TestGetUserByEmailFoldExcludesDeletedAndIsStable pins the fix for a bug
// that stopped being a hypothetical edge case once the Slack multi-account
// migration shipped: the same human now legitimately has one users row per
// connected workspace, so a duplicate email is the expected shape, not rare.
// A deleted row for that email must never win over an active one, and among
// several active rows the pick must be stable across repeated calls, not
// whatever order SQLite happens to return.
func TestGetUserByEmailFoldExcludesDeletedAndIsStable(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "2:U002", Name: "alice-old", Email: "alice@example.com", IsDeleted: true}))
	require.NoError(t, db.UpsertUser(User{ID: "1:U001", Name: "alice", Email: "alice@example.com"}))

	got, err := db.GetUserByEmailFold("alice@example.com")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "1:U001", got.ID, "the active row must win over a deleted one for the same email")

	// A second active row for the same email — the expected multi-account
	// shape. The winner must be stable across repeated calls.
	require.NoError(t, db.UpsertUser(User{ID: "3:U003", Name: "alice-other-workspace", Email: "alice@example.com"}))

	first, err := db.GetUserByEmailFold("alice@example.com")
	require.NoError(t, err)
	require.NotNil(t, first)
	for i := 0; i < 5; i++ {
		again, err := db.GetUserByEmailFold("alice@example.com")
		require.NoError(t, err)
		require.NotNil(t, again)
		assert.Equal(t, first.ID, again.ID, "the winner among active duplicates must be stable across calls")
	}
}

// TestGetUserByEmailFoldAllDeletedIsNotFound pins the other half of the
// deleted-exclusion: if every row for an email is deleted, that is a
// not-found, not a fallback to a deactivated account.
func TestGetUserByEmailFoldAllDeletedIsNotFound(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice", Email: "alice@example.com", IsDeleted: true}))

	got, err := db.GetUserByEmailFold("alice@example.com")
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestGetUserByEmailFoldEmptyGuard(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// A user with no email must never match an empty lookup — the same guard
	// GetUserByEmail has (email != '').
	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice", Email: ""}))

	got, err := db.GetUserByEmailFold("")
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestGetUserByNameNotFound(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	got, err := db.GetUserByName("nobody")
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestGetUsersNoFilter(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice"}))
	require.NoError(t, db.UpsertUser(User{ID: "U002", Name: "bob", IsBot: true}))
	require.NoError(t, db.UpsertUser(User{ID: "U003", Name: "charlie", IsDeleted: true}))

	users, err := db.GetUsers(UserFilter{})
	require.NoError(t, err)
	assert.Len(t, users, 3)
	// Sorted by name
	assert.Equal(t, "alice", users[0].Name)
	assert.Equal(t, "bob", users[1].Name)
	assert.Equal(t, "charlie", users[2].Name)
}

func TestGetUsersExcludeBots(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice"}))
	require.NoError(t, db.UpsertUser(User{ID: "U002", Name: "slackbot", IsBot: true}))

	users, err := db.GetUsers(UserFilter{ExcludeBots: true})
	require.NoError(t, err)
	assert.Len(t, users, 1)
	assert.Equal(t, "alice", users[0].Name)
}

func TestGetUsersExcludeDeleted(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice"}))
	require.NoError(t, db.UpsertUser(User{ID: "U002", Name: "gone", IsDeleted: true}))

	users, err := db.GetUsers(UserFilter{ExcludeDeleted: true})
	require.NoError(t, err)
	assert.Len(t, users, 1)
	assert.Equal(t, "alice", users[0].Name)
}

func TestGetUsersCombinedFilter(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice"}))
	require.NoError(t, db.UpsertUser(User{ID: "U002", Name: "slackbot", IsBot: true}))
	require.NoError(t, db.UpsertUser(User{ID: "U003", Name: "gone", IsDeleted: true}))
	require.NoError(t, db.UpsertUser(User{ID: "U004", Name: "deadbot", IsBot: true, IsDeleted: true}))

	users, err := db.GetUsers(UserFilter{ExcludeBots: true, ExcludeDeleted: true})
	require.NoError(t, err)
	assert.Len(t, users, 1)
	assert.Equal(t, "alice", users[0].Name)
}

func TestSearchUsersByName(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertUser(User{ID: "U001", Name: "alice", DisplayName: "Alice Smith", RealName: "Alice J. Smith"}))
	require.NoError(t, db.UpsertUser(User{ID: "U002", Name: "bob", DisplayName: "Bob Jones", RealName: "Robert Jones"}))
	require.NoError(t, db.UpsertUser(User{ID: "U003", Name: "alicebot", DisplayName: "Alice Bot", IsBot: true}))
	require.NoError(t, db.UpsertUser(User{ID: "U004", Name: "alice.gone", IsDeleted: true}))

	// Case-insensitive match on username/display/real name; bots and deleted excluded.
	users, err := db.SearchUsersByName("ALICE", 10)
	require.NoError(t, err)
	require.Len(t, users, 1)
	assert.Equal(t, "U001", users[0].ID)

	// Match against real_name only.
	users, err = db.SearchUsersByName("robert", 10)
	require.NoError(t, err)
	require.Len(t, users, 1)
	assert.Equal(t, "U002", users[0].ID)

	users, err = db.SearchUsersByName("nobody", 10)
	require.NoError(t, err)
	assert.Empty(t, users)
}

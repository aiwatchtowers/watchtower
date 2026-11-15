package db

import (
	"database/sql"
	"encoding/json"
	"os"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
)

type leaseStep struct {
	Op      string `json:"op"`
	Owner   string `json:"owner"`
	OwnerID string `json:"owner_id"`
	TurnID  string `json:"turn_id"`
	NowMS   int64  `json:"now_ms"`
}

type leaseCase struct {
	Name   string      `json:"name"`
	Steps  []leaseStep `json:"steps"`
	Expect []struct {
		OK    bool `json:"ok"`
		Lease *struct {
			Owner               string `json:"owner"`
			OwnerID             string `json:"owner_id"`
			TurnID              string `json:"turn_id"`
			StartedAtMS         int64  `json:"started_at_ms"`
			HeartbeatAtMS       int64  `json:"heartbeat_at_ms"`
			CancelRequestedAtMS *int64 `json:"cancel_requested_at_ms"`
		} `json:"lease"`
	} `json:"expect"`
}

func seedLeaseConversation(t *testing.T, d *DB) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (created_at, updated_at) VALUES (1, 1)`)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func claimChatLease(t *testing.T, d *DB, l ChatLease, nowMS int64) bool {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	ok, err := ClaimChatLeaseTx(tx, l, nowMS)
	require.NoError(t, err)
	if ok {
		require.NoError(t, tx.Commit())
	} else {
		require.NoError(t, tx.Rollback())
	}
	return ok
}

func TestChatLeaseCases(t *testing.T) {
	raw, err := os.ReadFile("testdata/chat_lease_cases.json")
	require.NoError(t, err)
	var cases []leaseCase
	require.NoError(t, json.Unmarshal(raw, &cases))
	require.NotEmpty(t, cases)
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			d := openTestDB(t)
			conv := seedLeaseConversation(t, d)
			require.Len(t, c.Expect, len(c.Steps))
			for i, s := range c.Steps {
				var ok bool
				switch s.Op {
				case "claim":
					ok = claimChatLease(t, d, ChatLease{
						ConversationID: conv, Owner: ChatLeaseOwner(s.Owner), OwnerID: s.OwnerID,
						TurnID: s.TurnID, StartedAtMS: s.NowMS, HeartbeatAtMS: s.NowMS,
					}, s.NowMS)
				case "heartbeat":
					ok, err = d.HeartbeatChatLease(conv, s.TurnID, s.NowMS)
					require.NoError(t, err)
				case "cancel":
					ok, err = d.RequestChatCancel(conv, s.TurnID, s.NowMS)
					require.NoError(t, err)
				case "release":
					tx, err := d.Begin()
					require.NoError(t, err)
					require.NoError(t, ReleaseChatLeaseTx(tx, conv, s.TurnID))
					require.NoError(t, tx.Commit())
					ok = true
				default:
					t.Fatalf("unknown op %q", s.Op)
				}
				want := c.Expect[i]
				require.Equal(t, want.OK, ok, "step %d (%s) ok", i, s.Op)
				got, err := d.GetChatLease(conv)
				require.NoError(t, err)
				if want.Lease == nil {
					require.Nil(t, got, "step %d lease", i)
					continue
				}
				require.NotNil(t, got, "step %d lease", i)
				require.Equal(t, conv, got.ConversationID)
				require.Equal(t, want.Lease.Owner, string(got.Owner))
				require.Equal(t, want.Lease.OwnerID, got.OwnerID)
				require.Equal(t, want.Lease.TurnID, got.TurnID)
				require.Equal(t, want.Lease.StartedAtMS, got.StartedAtMS)
				require.Equal(t, want.Lease.HeartbeatAtMS, got.HeartbeatAtMS)
				require.Equal(t, want.Lease.CancelRequestedAtMS, got.CancelRequestedAtMS)
			}
		})
	}
}

func TestLease_ConcurrentClaimOneWins(t *testing.T) {
	d1, path := openTemp(t)
	d2, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d2.Close() })
	conv := seedLeaseConversation(t, d1)

	handles := []*DB{d1, d2}
	owners := []ChatLeaseOwner{ChatLeaseDesktop, ChatLeaseHub}
	start := make(chan struct{})
	won := make([]bool, 2)
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i := range handles {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			var tx *sql.Tx
			tx, errs[i] = handles[i].Begin() // BEGIN IMMEDIATE (_txlock=immediate)
			if errs[i] != nil {
				return
			}
			won[i], errs[i] = ClaimChatLeaseTx(tx, ChatLease{
				ConversationID: conv, Owner: owners[i], OwnerID: "id", TurnID: string(owners[i]),
				StartedAtMS: 5000, HeartbeatAtMS: 5000,
			}, 5000)
			if errs[i] != nil || !won[i] {
				_ = tx.Rollback()
				return
			}
			errs[i] = tx.Commit()
		}()
	}
	close(start)
	wg.Wait()
	require.NoError(t, errs[0])
	require.NoError(t, errs[1])
	require.NotEqual(t, won[0], won[1], "exactly one claim wins: %v", won)

	got, err := d1.GetChatLease(conv)
	require.NoError(t, err)
	require.NotNil(t, got)
	winner := owners[0]
	if won[1] {
		winner = owners[1]
	}
	require.Equal(t, winner, got.Owner)
}

func TestLease_CascadeOnConversationDelete(t *testing.T) {
	d := openTestDB(t)
	conv := seedLeaseConversation(t, d)
	require.True(t, claimChatLease(t, d, ChatLease{
		ConversationID: conv, Owner: ChatLeaseDesktop, OwnerID: "app", TurnID: "t", StartedAtMS: 1, HeartbeatAtMS: 1,
	}, 1))
	_, err := d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)
	got, err := d.GetChatLease(conv)
	require.NoError(t, err)
	require.Nil(t, got)
}

func TestLease_ReleaseOwned(t *testing.T) {
	d := openTestDB(t)
	a, b, c := seedLeaseConversation(t, d), seedLeaseConversation(t, d), seedLeaseConversation(t, d)
	for _, x := range []struct {
		conv  int64
		owner ChatLeaseOwner
		id    string
	}{{a, ChatLeaseHub, "hub-1"}, {b, ChatLeaseHub, "hub-1"}, {c, ChatLeaseHub, "hub-2"}} {
		require.True(t, claimChatLease(t, d, ChatLease{
			ConversationID: x.conv, Owner: x.owner, OwnerID: x.id, TurnID: "t", StartedAtMS: 1, HeartbeatAtMS: 1,
		}, 1))
	}
	n, err := d.ReleaseOwnedChatLeases(ChatLeaseHub, "hub-1")
	require.NoError(t, err)
	require.EqualValues(t, 2, n)
	got, err := d.GetChatLease(c)
	require.NoError(t, err)
	require.NotNil(t, got)
}

func TestLease_OwnedListAndSessionLostMark(t *testing.T) {
	d := openTestDB(t)
	a, b := seedLeaseConversation(t, d), seedLeaseConversation(t, d)
	require.True(t, claimChatLease(t, d, ChatLease{ConversationID: a, Owner: ChatLeaseHub, OwnerID: "hub-1", TurnID: "ta",
		StartedAtMS: 1, HeartbeatAtMS: 1}, 1))
	require.True(t, claimChatLease(t, d, ChatLease{ConversationID: b, Owner: ChatLeaseDesktop, OwnerID: "hub-1", TurnID: "tb",
		StartedAtMS: 1, HeartbeatAtMS: 1}, 1))
	owned, err := d.OwnedChatLeases(ChatLeaseHub, "hub-1")
	require.NoError(t, err)
	require.Len(t, owned, 1)
	require.Equal(t, a, owned[0].ConversationID)
	require.Equal(t, "ta", owned[0].TurnID)

	insert := func(role, status, turn string) int64 {
		res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, status, turn_id, created_at)
VALUES (?, ?, 'x', ?, ?, 1)`, a, role, status, turn)
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		return id
	}
	partial, owner, done, other := insert("assistant", "partial", "ta"), insert("user", "complete", "ta"),
		insert("assistant", "complete", "ta"), insert("assistant", "partial", "tz")
	n, err := d.MarkChatTurnSessionLost(a, "ta")
	require.NoError(t, err)
	require.EqualValues(t, 1, n)
	for id, want := range map[int64]string{partial: "session_lost", owner: "", done: "", other: ""} {
		var code sql.NullString
		require.NoError(t, d.QueryRow(`SELECT error_code FROM chat_messages WHERE id = ?`, id).Scan(&code))
		require.Equal(t, want, code.String, "message %d", id)
	}
}

func TestLease_FreshList(t *testing.T) {
	d := openTestDB(t)
	a, b := seedLeaseConversation(t, d), seedLeaseConversation(t, d)
	require.True(t, claimChatLease(t, d, ChatLease{ConversationID: a, Owner: ChatLeaseHub, OwnerID: "h", TurnID: "t1", StartedAtMS: 100_000, HeartbeatAtMS: 100_000}, 100_000))
	require.True(t, claimChatLease(t, d, ChatLease{ConversationID: b, Owner: ChatLeaseDesktop, OwnerID: "d", TurnID: "t2", StartedAtMS: 130_000, HeartbeatAtMS: 130_000}, 130_000))
	fresh, err := d.FreshChatLeases(150_000)
	require.NoError(t, err)
	require.Equal(t, []int64{a, b}, fresh)
	fresh, err = d.FreshChatLeases(160_000)
	require.NoError(t, err)
	require.Equal(t, []int64{b}, fresh, "a heartbeat 60 s old is stale")
}

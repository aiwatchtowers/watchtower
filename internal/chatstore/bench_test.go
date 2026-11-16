package chatstore

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"

	"watchtower/internal/db"
)

// BenchmarkPersistStart is the Go half of the start's timing gate (spec
// 2026-11-15 mobile inbox §8; the Swift half is ChatTurnStoreFixtureTests'
// testPersistStartTiming): Start — the lease claim and persistTurnStart's
// writes in one transaction — on the shared fixture's first case, in a
// database file, the turn's rows and lease undone between runs. Runs alone:
//
//	go test ./internal/chatstore/ -run '^$' -bench BenchmarkPersistStart -count 5
func BenchmarkPersistStart(b *testing.B) {
	tc := loadFixture(b).Turns[0]
	d, err := db.Open(filepath.Join(b.TempDir(), "w.db"))
	if err != nil {
		b.Fatal(err)
	}
	defer d.Close()
	conv, _ := seedTree(b, d, tc)
	s := New(d, db.ChatLeaseDesktop, "launch", WithPreferredProvider("claude"))
	ctx := context.Background()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		turnID := fmt.Sprintf("bench-%d", i)
		if _, err := s.Start(ctx, StartRequest{ConversationID: conv, Mode: ModeSend, Text: tc.Request.Text, TurnID: turnID}); err != nil {
			b.Fatal(err)
		}
		b.StopTimer()
		if err := d.WithTx(func(tx *sql.Tx) error {
			if err := db.ReleaseChatLeaseTx(tx, conv, turnID); err != nil {
				return err
			}
			if _, err := tx.Exec(`DELETE FROM chat_messages WHERE conversation_id = ? AND turn_id = ?`, conv, turnID); err != nil {
				return err
			}
			_, err := tx.Exec(`UPDATE chat_conversations SET active_leaf_message_id = NULL, title = '' WHERE id = ?`, conv)
			return err
		}); err != nil {
			b.Fatal(err)
		}
		b.StartTimer()
	}
}

package state

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func TestMilestonesInsertReadPrune(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	now := time.Unix(1_800_000_000, 500_000_000).UTC()
	err = st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if err := InsertMilestone(tx, 1, now.Add(-15*24*time.Hour), []byte("old")); err != nil {
			return err
		}
		for i := range 5 {
			if err := InsertMilestone(tx, 2, now.Add(time.Duration(i)*time.Second), []byte(fmt.Sprint(i))); err != nil {
				return err
			}
		}
		return PruneMilestones(tx, now.Add(-14*24*time.Hour), 3)
	})
	if err != nil {
		t.Fatal(err)
	}
	var got []Milestone
	err = st.WithTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		got, err = Milestones(tx)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || string(got[0].Text) != "4" || got[0].SessionID != 2 || !got[2].At.Equal(now.Add(2*time.Second)) {
		t.Fatalf("milestones = %+v", got)
	}
	err = st.WithTx(context.Background(), func(tx *sql.Tx) error { return DeleteMilestone(tx, got[0].RowID) })
	if err != nil {
		t.Fatal(err)
	}
	_ = st.WithTx(context.Background(), func(tx *sql.Tx) error {
		got, err = Milestones(tx)
		return err
	})
	if len(got) != 2 || string(got[0].Text) != "3" {
		t.Fatalf("after delete = %+v", got)
	}
}

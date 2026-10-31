package state

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

func TestSessionReportsSaveReplaceKeep(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	at := time.Unix(1_800_000_000, 250_000_000).UTC()
	ctx := context.Background()
	err = st.WithTx(ctx, func(tx *sql.Tx) error {
		for _, id := range []int64{1, 2, 3} {
			if err := SaveSessionReport(tx, id, []byte("v1"), at); err != nil {
				return err
			}
		}
		if err := SaveSessionReport(tx, 2, []byte("v2"), at.Add(time.Second)); err != nil {
			return err
		}
		return KeepSessionReports(tx, map[int64]bool{2: true, 3: true})
	})
	if err != nil {
		t.Fatal(err)
	}
	var got []StoredReport
	if err := st.ReadTx(ctx, func(tx *sql.Tx) error {
		var err error
		got, err = SessionReports(tx)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].SessionID != 2 || string(got[0].Payload) != "v2" || got[0].FetchedAt.Sub(at.Add(time.Second)).Abs() > time.Millisecond {
		t.Fatalf("stored reports = %+v", got)
	}
	if got[1].SessionID != 3 || string(got[1].Payload) != "v1" {
		t.Fatalf("session 3 = %+v", got[1])
	}
}

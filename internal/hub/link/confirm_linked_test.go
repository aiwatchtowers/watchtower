package link

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"
)

// ConfirmLinked reports a link only for the answer that linked the phone:
// the runtime asks for the relay-link check on it (#2191), never on a
// refusal, an expired or used code, or a repeat.
func TestConfirmLinkedReportsOnlyTheAnswerThatLinked(t *testing.T) {
	waiting := func(t *testing.T) (*rig, phone, string) {
		t.Helper()
		r := newRig(t)
		code := r.issue()
		a := newPhone(t)
		if got := r.handle(a, code.Nonce); got.Code == "" {
			t.Fatalf("hello not waiting: %+v", got)
		}
		return r, a, r.code(a)
	}
	usedBy := func(t *testing.T, r *rig, device string) {
		t.Helper()
		if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
			_, err := tx.Exec(`UPDATE link_codes SET used_by_device = ?`, device)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		name    string
		before  func(t *testing.T, r *rig, a phone)
		confirm bool
		want    bool
	}{
		{name: "linked", confirm: true, want: true},
		{name: "declined", confirm: false},
		{name: "expired code (decisionRefused)", confirm: true, before: func(_ *testing.T, r *rig, _ phone) {
			r.advance(601 * time.Second)
		}},
		{name: "code used by another phone (decisionRefused)", confirm: true, before: func(t *testing.T, r *rig, _ phone) {
			usedBy(t, r, "00000000-0000-0000-0000-000000000001")
		}},
		{name: "code used by this phone (decisionUsedByThisDevice)", confirm: true, before: func(t *testing.T, r *rig, a phone) {
			usedBy(t, r, strings.ToUpper(a.id.String()))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, a, code := waiting(t)
			if tc.before != nil {
				tc.before(t, r, a)
			}
			linked, err := r.c.ConfirmLinked(a.id.String(), code, tc.confirm)
			if err != nil || linked != tc.want {
				t.Fatalf("ConfirmLinked = %v, %v; want %v, nil", linked, err, tc.want)
			}
			if r.linked(a) != tc.want {
				t.Fatalf("linked row %v, want %v", r.linked(a), tc.want)
			}
		})
	}
	t.Run("repeat confirm", func(t *testing.T) {
		r, a, code := waiting(t)
		if linked, err := r.c.ConfirmLinked(a.id.String(), code, true); err != nil || !linked {
			t.Fatalf("first confirm = %v, %v", linked, err)
		}
		if linked, err := r.c.ConfirmLinked(a.id.String(), code, true); !errors.Is(err, ErrNoRequest) || linked {
			t.Fatalf("repeat confirm = %v, %v; want false, ErrNoRequest", linked, err)
		}
	})
}

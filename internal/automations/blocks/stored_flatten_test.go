package blocks_test

import (
	"reflect"
	"testing"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

// TestFixture_StoredFlattenMatches pins db.FlattenStoredInboxActions (the
// press path's reading of a stored row; db cannot import this package) to
// FlattenActions over every valid case of the shared fixture, and refuses
// every unsupported document.
func TestFixture_StoredFlattenMatches(t *testing.T) {
	f := readFixture(t)
	for _, c := range f.Valid {
		t.Run(c.Name, func(t *testing.T) {
			r, err := card(exported(t, c.Input), c.BuiltIn)
			if err != nil {
				t.Fatalf("refused: %v", err)
			}
			cardActions := r.flat[:countCardActions(t, c.Input)]
			got, err := db.FlattenStoredInboxActions(cardActions, c.Canonical)
			if err != nil {
				t.Fatalf("FlattenStoredInboxActions: %v", err)
			}
			if !reflect.DeepEqual(got, blocks.FlattenActions(cardActions, &r.doc)) {
				t.Errorf("stored flatten =\n%+v\nwant\n%+v", got, r.flat)
			}
		})
	}
	for _, c := range f.Unsupported {
		if _, err := db.FlattenStoredInboxActions(nil, string(c.Document)); err == nil {
			t.Errorf("%s: an unsupported document flattened", c.Name)
		}
	}
}

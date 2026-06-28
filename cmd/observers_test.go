package cmd

import "testing"

func TestParseEntity(t *testing.T) {
	t.Run("valid target", func(t *testing.T) {
		typ, id, err := parseEntity("target:15")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if typ != "target" || id != 15 {
			t.Fatalf("got (%q, %d), want (target, 15)", typ, id)
		}
	})

	t.Run("empty is rejected", func(t *testing.T) {
		if _, _, err := parseEntity(""); err == nil {
			t.Fatal("expected error for empty entity")
		}
	})

	t.Run("missing colon is rejected", func(t *testing.T) {
		if _, _, err := parseEntity("target15"); err == nil {
			t.Fatal("expected error for missing colon")
		}
	})

	t.Run("non-numeric id is rejected", func(t *testing.T) {
		if _, _, err := parseEntity("target:abc"); err == nil {
			t.Fatal("expected error for non-numeric id")
		}
	})

	t.Run("trailing garbage is rejected", func(t *testing.T) {
		if _, _, err := parseEntity("target:42:extra"); err == nil {
			t.Fatal("expected error for trailing garbage")
		}
	})

	t.Run("unsupported type is rejected", func(t *testing.T) {
		if _, _, err := parseEntity("digest:7"); err == nil {
			t.Fatal("expected error for unsupported entity type")
		}
	})
}

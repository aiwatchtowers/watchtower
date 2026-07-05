package catchup

import "testing"

func TestParsePeel_Theme(t *testing.T) {
	raw := "```json\n{\"theme\":{\"title\":\"Payments\",\"priority\":\"high\",\"refs\":[{\"area\":\"digests\",\"id\":1,\"label\":\"C1\"}]}}\n```"
	got, err := parsePeel(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got.Done {
		t.Fatal("expected Done=false")
	}
	if got.Theme == nil || got.Theme.Title != "Payments" || got.Theme.Priority != "high" {
		t.Fatalf("theme = %+v", got.Theme)
	}
	if len(got.Theme.Refs) != 1 || got.Theme.Refs[0].Area != "digests" || got.Theme.Refs[0].ID != 1 {
		t.Fatalf("refs = %+v", got.Theme.Refs)
	}
}

func TestParsePeel_Done(t *testing.T) {
	got, err := parsePeel(`{"done": true}`)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Done {
		t.Fatal("expected Done=true")
	}
	if got.Theme != nil {
		t.Fatalf("expected nil theme, got %+v", got.Theme)
	}
}

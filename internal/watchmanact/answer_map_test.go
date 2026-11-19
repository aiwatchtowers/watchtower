package watchmanact

import (
	"testing"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// A folder suggestion is never answered by the twin, not even with a park or
// a hand-back text: its answer acts on the Mac (#2003).
func TestTextAnswer_RefusesAFolderAsk(t *testing.T) {
	if _, ok := textAnswer(db.AskKindFolder, asks.Payload{}, "parked"); ok {
		t.Fatal("textAnswer answered a folder ask")
	}
	if _, ok := textAnswer("question", asks.Payload{}, "parked"); !ok {
		t.Fatal("textAnswer refused a question ask")
	}
}

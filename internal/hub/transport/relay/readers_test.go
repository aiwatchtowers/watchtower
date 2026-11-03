package relay

import (
	"slices"
	"testing"

	"watchtower/internal/hub/transport/relay/relayv1"
)

// Readers is the last reader list the relay accepted: a refused
// set_hub_readers leaves it as it was.
func TestReadersAreTheLastAcceptedSet(t *testing.T) {
	h := newHarness(t)
	if got := h.tr.Readers(); got != nil {
		t.Fatalf("readers before any set %v", got)
	}
	if err := h.tr.SetHubReaders(t.Context(), []string{"p1"}); err != nil {
		t.Fatal(err)
	}
	h.relay.FailNext("set_hub_readers", relayv1.ErrorCode_ERROR_CODE_FORBIDDEN)
	if err := h.tr.SetHubReaders(t.Context(), []string{"p1", "p2"}); err == nil {
		t.Fatal("the refused set succeeded")
	}
	if got := h.tr.Readers(); !slices.Equal(got, []string{"p1"}) {
		t.Fatalf("readers %v, want the accepted [p1]", got)
	}
}

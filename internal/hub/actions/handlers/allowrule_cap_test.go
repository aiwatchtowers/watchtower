package handlers_test

import (
	"testing"

	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/slices/sources"
)

// The hub judges an allow on the summary as the phone got it: the answer
// handler's cap is the permission_request slice's.
func TestAllowSummaryCapMatchesTheSlice(t *testing.T) {
	if handlers.AllowSummaryCap != sources.PermissionMaxSummary {
		t.Fatalf("AllowSummaryCap = %d, sources.PermissionMaxSummary = %d", handlers.AllowSummaryCap, sources.PermissionMaxSummary)
	}
	long := make([]byte, sources.PermissionMaxSummary+1)
	for i := range long {
		long[i] = 'a'
	}
	if _, clipped := sources.WireSummary(string(long), false); !clipped {
		t.Fatal("the slice no longer clips past its cap")
	}
}

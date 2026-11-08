package digest

import (
	"errors"
	"fmt"
	"testing"
)

type testProviderWait struct{}

func (testProviderWait) Error() string          { return "provider waiting" }
func (testProviderWait) ProviderDeferred() bool { return true }
func TestProviderDeferredPreservesMaterialFailures(t *testing.T) {
	wait := testProviderWait{}
	for _, err := range []error{wait, fmt.Errorf("wrapped: %w", wait), errors.Join(wait, wait)} {
		if !ProviderDeferred(err) {
			t.Fatalf("wait lost: %v", err)
		}
	}
	if ProviderDeferred(errors.Join(wait, errors.New("storage failed"))) {
		t.Fatal("material failure hidden")
	}
}

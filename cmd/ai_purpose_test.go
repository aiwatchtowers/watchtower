package cmd

import (
	"context"
	"errors"
	"strings"
	"testing"

	"watchtower/internal/llmusage"
)

func TestAIQueryPurpose_TagsContext(t *testing.T) {
	for _, purpose := range []string{"spec_review.discuss", "review.reviewer"} {
		ctx, err := queryContext(context.Background(), purpose)
		if err != nil {
			t.Fatalf("queryContext(%s): %v", purpose, err)
		}
		got, ok := llmusage.PurposeFrom(ctx)
		if !ok || got != purpose {
			t.Fatalf("PurposeFrom = %q, %v; want %s, true", got, ok, purpose)
		}
	}
}

func TestAIQueryPurpose_EmptyLeavesContextUntagged(t *testing.T) {
	ctx, err := queryContext(context.Background(), "")
	if err != nil {
		t.Fatalf("queryContext: %v", err)
	}
	if got, ok := llmusage.PurposeFrom(ctx); ok {
		t.Fatalf("PurposeFrom = %q; want no purpose without --purpose", got)
	}
}

func TestAIQueryPurpose_RefusesUnknown(t *testing.T) {
	_, err := queryContext(context.Background(), "digest.channel")
	if err == nil {
		t.Fatal("queryContext accepted an unknown purpose")
	}
	var ec *exitCodeError
	if !errors.As(err, &ec) || ec.code != 2 {
		t.Fatalf("err = %v; want an exit-2 usage error", err)
	}
	if !strings.Contains(err.Error(), "unknown --purpose") {
		t.Fatalf("err = %q; want it to say unknown --purpose", err)
	}
}

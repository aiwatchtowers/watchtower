package digest

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/llmusage"
)

func TestDigestSourceIsPurpose(t *testing.T) {
	ctx := WithSource(context.Background(), "x")
	p, ok := llmusage.PurposeFrom(ctx)
	assert.True(t, ok)
	assert.Equal(t, "x", p)

	s, ok := SourceFromContext(llmusage.WithPurpose(context.Background(), "y"))
	assert.True(t, ok)
	assert.Equal(t, "y", s)

	_, ok = SourceFromContext(WithSource(context.Background(), ""))
	assert.False(t, ok, "an empty source is no source")
}

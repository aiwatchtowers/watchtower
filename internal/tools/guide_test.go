package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/userguide"
)

func TestSearchGuideReturnsURL(t *testing.T) {
	tool := NewSearchGuide("v9.9.9")
	res, err := tool.Execute(context.Background(), nil, Call{Args: json.RawMessage(`{"query":"recap"}`)})
	require.NoError(t, err)
	secs := res.(map[string]any)["sections"].([]guideSection)
	require.NotEmpty(t, secs)
	for _, s := range secs {
		assert.True(t, strings.HasPrefix(s.URL, userguide.BaseURL("v9.9.9")), s.URL)
		assert.True(t, strings.HasSuffix(s.URL, "#"+s.Anchor))
	}
	assert.Equal(t, []string{"main"}, tool.Surfaces)
}

func TestGetGuidePage(t *testing.T) {
	all, err := userguide.Load()
	require.NoError(t, err)
	tool := NewGetGuidePage("v1")
	res, err := tool.Execute(context.Background(), nil, Call{Args: json.RawMessage(`{"page":"` + all[0].Page + `"}`)})
	require.NoError(t, err)
	m := res.(map[string]any)
	assert.Equal(t, all[0].PageTitle, m["title"])
	assert.NotEmpty(t, m["text"])

	_, err = tool.Execute(context.Background(), nil, Call{Args: json.RawMessage(`{"page":"nope"}`)})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Equal(t, "unknown guide page; use search_guide", ve.Msg)
}

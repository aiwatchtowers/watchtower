package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/learn"
)

// TestGuideLearnJSONKeys pins the `guide learn --json` contract the Desktop
// decodes (plan 2026-10-25-home-learn.md, Contracts).
func TestGuideLearnJSONKeys(t *testing.T) {
	cat := learn.Catalog{
		Cards:   []learn.Card{{ID: "a", Replaces: []string{}, Action: "hotkey:help", HotkeyLabel: "⌘/"}},
		Retired: []string{"old"},
	}
	var out bytes.Buffer
	require.NoError(t, writeLearnCatalog(&out, cat, true))
	require.Equal(t, 1, strings.Count(out.String(), "\n"), "one JSON line")

	var top map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(out.Bytes(), &top))
	assert.ElementsMatch(t, []string{"cards", "retired"}, mapKeys(top))

	var cards []map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(top["cards"], &cards))
	require.Len(t, cards, 1)
	assert.Equal(t, []string{
		"action", "anchor", "area", "changed", "done_when", "hotkey_label", "id",
		"kind", "level", "page", "replaces", "requires", "since", "text", "title",
	}, mapKeys(cards[0]))
	assert.JSONEq(t, `[]`, string(cards[0]["replaces"]))
	assert.JSONEq(t, `""`, string(cards[0]["changed"]))
	assert.JSONEq(t, `"⌘/"`, string(cards[0]["hotkey_label"]))
}

// TestGuideLearnNeedsNoConfig runs the real command against the embedded
// guide with an unreadable config: it must neither load config nor open a
// database.
func TestGuideLearnNeedsNoConfig(t *testing.T) {
	saved := flagConfig
	flagConfig = filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(flagConfig, []byte("{not yaml"), 0o600))
	t.Cleanup(func() {
		flagConfig = saved
		guideLearnFlagJSON = false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs([]string{"guide", "learn", "--json"})
	require.NoError(t, rootCmd.Execute(), errOut.String())

	var cat struct {
		Cards   []map[string]any `json:"cards"`
		Retired []string         `json:"retired"`
	}
	require.NoError(t, json.Unmarshal(out.Bytes(), &cat))
	assert.NotNil(t, cat.Cards, `"cards" is a list, never null`)
	assert.NotNil(t, cat.Retired, `"retired" is a list, never null`)
}

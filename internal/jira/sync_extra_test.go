package jira

import (
	"io"
	"log"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNewSyncer_Defaults(t *testing.T) {
	s := NewSyncer(nil, nil, nil, []int{1, 2, 3})
	assert.Equal(t, []int{1, 2, 3}, s.boardIDs)
	assert.NotNil(t, s.logger)
}

func TestSyncer_SetLogger(t *testing.T) {
	s := NewSyncer(nil, nil, nil, nil)
	custom := log.New(io.Discard, "", 0)
	s.SetLogger(custom)
	assert.Same(t, custom, s.logger)
}

func TestSyncer_SetBoardAnalyzer_AndUsage(t *testing.T) {
	s := NewSyncer(nil, nil, nil, nil)

	// Without analyzer, usage is zero.
	in, out, total := s.BoardAnalyzerUsage()
	assert.Equal(t, 0, in)
	assert.Equal(t, 0, out)
	assert.Equal(t, 0, total)

	analyzer := NewBoardAnalyzer(nil, nil, nil)
	s.SetBoardAnalyzer(analyzer)
	assert.Same(t, analyzer, s.boardAnalyzer)
}

func TestSyncer_SetAutoRefresh(t *testing.T) {
	s := NewSyncer(nil, nil, nil, nil)
	s.SetAutoRefresh(true)
	assert.True(t, s.autoRefresh)
	s.SetAutoRefresh(false)
	assert.False(t, s.autoRefresh)
}

func TestParseTerminalStatuses_NoProfile(t *testing.T) {
	assert.Nil(t, parseTerminalStatuses("", ""))
}

func TestParseTerminalStatuses_BadJSON(t *testing.T) {
	assert.Nil(t, parseTerminalStatuses("not json", ""))
}

func TestParseTerminalStatuses_HappyPath(t *testing.T) {
	profile := `{
		"workflow_stages":[
			{"name":"Done","is_terminal":true,"original_statuses":["Closed","Resolved"]},
			{"name":"In Progress","is_terminal":false,"original_statuses":["In Progress","Review"]}
		]
	}`
	got := parseTerminalStatuses(profile, "")
	assert.ElementsMatch(t, []string{"Closed", "Resolved"}, got)
}

func TestParseTerminalStatuses_OverridePromotes(t *testing.T) {
	profile := `{"workflow_stages":[{"name":"Open","is_terminal":false,"original_statuses":["Open"]}]}`
	overrides := `{"terminal_stages":{"Open":true}}`
	got := parseTerminalStatuses(profile, overrides)
	assert.Equal(t, []string{"Open"}, got)
}

func TestParseTerminalStatuses_OverrideDemotes(t *testing.T) {
	profile := `{"workflow_stages":[{"name":"Done","is_terminal":true,"original_statuses":["Done"]}]}`
	overrides := `{"terminal_stages":{"Done":false}}`
	got := parseTerminalStatuses(profile, overrides)
	assert.Empty(t, got)
}

func TestParseTerminalStatuses_GarbageOverridesIgnored(t *testing.T) {
	profile := `{"workflow_stages":[{"name":"Done","is_terminal":true,"original_statuses":["Closed"]}]}`
	got := parseTerminalStatuses(profile, "not json")
	assert.Equal(t, []string{"Closed"}, got)
}

func TestBuildStatusNotIn(t *testing.T) {
	cases := []struct {
		in   []string
		want string
	}{
		{nil, ""},
		{[]string{}, ""},
		{[]string{"Done"}, `"Done"`},
		{[]string{"Done", "Closed"}, `"Done","Closed"`},
		{[]string{`Funky "name"`}, `"Funky \"name\""`},
	}
	for _, tc := range cases {
		got := buildStatusNotIn(tc.in)
		assert.Equal(t, tc.want, got)
	}
}

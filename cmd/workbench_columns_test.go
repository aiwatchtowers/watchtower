package cmd

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func runColumns(t *testing.T, stdin string, args ...string) (string, string, error) {
	t.Helper()
	rootCmd.SetIn(strings.NewReader(stdin))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	return runWorkbench(t, append([]string{"columns"}, args...)...)
}

func decodeColumns(t *testing.T, out string) db.BoardColumns {
	t.Helper()
	var res db.BoardColumns
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	return res
}

func TestWorkbenchColumns_JSONEmpty(t *testing.T) {
	_, pid, _ := methodologyWorkbench(t)

	out, _, err := runColumns(t, "", strconv.FormatInt(pid, 10), "--json")

	require.NoError(t, err)
	assert.JSONEq(t, `{"columns":[],"hidden":[]}`, out)
}

func TestWorkbenchColumns_SetRoundTrip(t *testing.T) {
	database, pid, _ := methodologyWorkbench(t)
	id := strconv.FormatInt(pid, 10)
	in := `{"columns":[{"status":"todo","title":"Backlog","description":"","position":0},` +
		`{"status":"todo","title":"Ready","description":"next up","position":1}],"hidden":["blocked"]}`

	out, _, err := runColumns(t, in, id, "--set", "-", "--json")

	require.NoError(t, err)
	got := decodeColumns(t, out)
	require.Len(t, got.Columns, 2)
	assert.Equal(t, "Backlog", got.Columns[0].Title)
	assert.Equal(t, "Ready", got.Columns[1].Title)
	assert.Equal(t, []string{"blocked"}, got.Hidden)
	stored, err := database.GetBoardColumns(pid)
	require.NoError(t, err)
	assert.Equal(t, got, stored)

	human, _, err := runColumns(t, "", id)
	require.NoError(t, err)
	assert.Contains(t, human, "Backlog")
	assert.Contains(t, human, "Hidden: ")
}

func TestWorkbenchColumns_SetRefusesAndWritesNothing(t *testing.T) {
	_, pid, _ := methodologyWorkbench(t)
	id := strconv.FormatInt(pid, 10)
	good := `{"columns":[{"status":"todo","title":"Backlog","description":"","position":0}],"hidden":[]}`
	_, _, err := runColumns(t, good, id, "--set", "-", "--json")
	require.NoError(t, err)

	bad := `{"columns":[{"status":"nonsense","title":"X","description":"","position":0}],"hidden":[]}`
	_, _, err = runColumns(t, bad, id, "--set", "-", "--json")

	var ce *db.BoardColumnsError
	require.ErrorAs(t, err, &ce)
	assert.NotEmpty(t, ce.Msg)
	out, _, err := runColumns(t, "", id, "--json")
	require.NoError(t, err)
	got := decodeColumns(t, out)
	require.Len(t, got.Columns, 1)
	assert.Equal(t, "Backlog", got.Columns[0].Title)
}

func TestWorkbenchColumns_UnknownWorkbench(t *testing.T) {
	methodologyWorkbench(t)

	_, _, err := runColumns(t, "", "99999", "--json")

	assert.ErrorIs(t, err, db.ErrWorkbenchNotFound)
}

func TestWorkbenchColumns_SetRefusesUnknownKeyAndTrailingData(t *testing.T) {
	_, pid, _ := methodologyWorkbench(t)
	id := strconv.FormatInt(pid, 10)
	good := `{"columns":[{"status":"todo","title":"Backlog","description":"","position":0}],"hidden":[]}`
	_, _, err := runColumns(t, good, id, "--set", "-", "--json")
	require.NoError(t, err)

	for name, in := range map[string]string{
		"misspelled key":  `{"colums":[],"hidden":[]}`,
		"hidden_statuses": `{"columns":[],"hidden_statuses":["blocked"]}`,
		"extra brace":     good + `}`,
		"extra bracket":   good + `]`,
		"trailing data":   good + ` {"columns":[]}`,
	} {
		_, _, err = runColumns(t, in, id, "--set", "-", "--json")
		require.Error(t, err, name)
		out, _, err := runColumns(t, "", id, "--json")
		require.NoError(t, err)
		got := decodeColumns(t, out)
		require.Len(t, got.Columns, 1, name)
		assert.Equal(t, "Backlog", got.Columns[0].Title, name)
	}
}

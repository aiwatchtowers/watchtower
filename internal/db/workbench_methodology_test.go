package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Spec 2026-10-15 §8: the three overrides start NULL (use the folder file,
// else the default), round-trip, and "" writes NULL back.
func TestWorkbenchMethodology_RoundTripAndNull(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)

	m, err := d.GetWorkbenchMethodology(pid)
	require.NoError(t, err)
	assert.Equal(t, WorkbenchMethodology{}, m)

	want := WorkbenchMethodology{Preset: "none", AskGuard: "soft", FinishCheck: "off"}
	require.NoError(t, d.SetWorkbenchMethodology(pid, want))
	m, err = d.GetWorkbenchMethodology(pid)
	require.NoError(t, err)
	assert.Equal(t, want, m)

	require.NoError(t, d.SetWorkbenchMethodology(pid, WorkbenchMethodology{AskGuard: "off"}))
	var preset, finish any
	require.NoError(t, d.QueryRow(`SELECT methodology_preset, finish_check FROM projects WHERE id = ?`, pid).Scan(&preset, &finish))
	assert.Nil(t, preset, `"" stores NULL`)
	assert.Nil(t, finish)
}

// The column CHECKs are the value rules both the CLI and any raw write share.
func TestWorkbenchMethodology_ChecksRefuseUnknownValues(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	for _, m := range []WorkbenchMethodology{{Preset: "scrum"}, {AskGuard: "loose"}, {FinishCheck: "yes"}} {
		err := d.SetWorkbenchMethodology(pid, m)
		require.Error(t, err, "%+v", m)
		assert.Contains(t, err.Error(), "CHECK constraint failed")
	}
	assert.ErrorIs(t, d.SetWorkbenchMethodology(pid+100, WorkbenchMethodology{}), ErrWorkbenchNotFound)
	_, err := d.GetWorkbenchMethodology(pid + 100)
	assert.ErrorIs(t, err, ErrWorkbenchNotFound)
}

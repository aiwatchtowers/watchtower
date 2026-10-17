package tools

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// PROJ-22: moving a target into in_progress returns the owner's target
// procedure in the tool result.

const procWant = "Owner's target procedure — follow it for #%d:\nglobal rule\nFor this workbench:\nbench rule"

func seedProcedure(t *testing.T, d *db.DB, wb int64) {
	t.Helper()
	require.NoError(t, d.SetOwnerInstruction(db.InstructionProcedure, "global rule"))
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "bench rule"))
}

func TestProj22_UpdateTargetInProgressReturnsProcedure(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedProcedure(t, fx.d, fx.a)

	out := mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"in_progress","reason":"start"}`, fx.aTarget))
	assert.Equal(t, fmt.Sprintf(procWant, fx.aTarget), out["procedure"])
	assert.EqualValues(t, fx.aTarget, out["target_id"])
}

func TestProj22_UpdateTargetAlreadyInProgressStillReturns(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedProcedure(t, fx.d, fx.a)
	args := fmt.Sprintf(`{"target_id":%d,"status":"in_progress","reason":"start"}`, fx.aTarget)
	mustApply(t, reg, fx.a, "update_target", args)

	out := mustApply(t, reg, fx.a, "update_target", args)
	assert.Equal(t, fmt.Sprintf(procWant, fx.aTarget), out["procedure"])
}

func TestProj22_OtherStatusNoProcedure(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedProcedure(t, fx.d, fx.a)

	out := mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"done","reason":"x"}`, fx.aTarget))
	assert.NotContains(t, out, "procedure")

	other := mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"progress":0.5,"reason":"x"}`, fx.aTarget))
	assert.NotContains(t, other, "procedure")
}

func TestProj22_ColumnIntoInProgressReturnsProcedure(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedColumns(t, fx.d, fx.a)
	seedProcedure(t, fx.d, fx.a)

	out := mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"Code","reason":"building"}`, fx.aTarget))
	assert.Equal(t, fmt.Sprintf(procWant, fx.aTarget), out["procedure"])

	back := mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"Backlog","reason":"back"}`, fx.aTarget))
	assert.NotContains(t, back, "procedure")
}

func TestProj22_NoTextsNoKey(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)

	out := mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"in_progress","reason":"start"}`, fx.aTarget))
	assert.NotContains(t, out, "procedure")
}

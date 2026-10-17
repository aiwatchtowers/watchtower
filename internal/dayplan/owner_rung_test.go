package dayplan

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// countingGenerator counts Generate calls.
type countingGenerator struct{ calls int }

func (g *countingGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	return validResponse(), &digest.Usage{}, "s1", nil
}

// A plan written while the owner came from the mailbox rung is today's plan
// after the owner moves to Jira: Run adopts it instead of generating a
// second one (OWNER-01, board #576).
func TestRun_RungSwitchDoesNotRegenerate(t *testing.T) {
	d := gatherTestDB(t)
	const day = "2026-10-17"
	_, err := d.CreateDayPlan(&db.DayPlan{
		UserID: "email:x@example.com", PlanDate: day, Status: "active", GeneratedAt: time.Now(),
	})
	require.NoError(t, err)

	gen := &countingGenerator{}
	plan, err := newTestPipeline(d, gen).Run(context.Background(), RunOptions{UserID: "jira:acc-9", Date: day})
	require.NoError(t, err)

	assert.Zero(t, gen.calls, "no second generation")
	require.NotNil(t, plan)
	assert.Equal(t, "jira:acc-9", plan.UserID)
	found, err := d.GetDayPlan("jira:acc-9", day)
	require.NoError(t, err)
	require.NotNil(t, found)
	assert.Equal(t, plan.ID, found.ID)
}

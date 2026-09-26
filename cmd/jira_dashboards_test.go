package cmd

import (
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The four dashboards aggregate every connected site, so the inherited
// --account flag has no meaning there. Honouring it would either be a no-op or
// silently narrow the data; each command must refuse it up front, before it
// touches config or the database.
func TestJiraDashboards_RejectAccountFlag(t *testing.T) {
	runners := map[string]func(*cobra.Command, []string) error{
		"workload":    runJiraWorkload,
		"blockers":    runJiraBlockers,
		"project-map": runJiraProjectMap,
		"releases":    runJiraReleases,
	}

	for name, run := range runners {
		t.Run(name, func(t *testing.T) {
			jiraFlagAccount = 2
			t.Cleanup(func() { jiraFlagAccount = 0 })

			err := run(&cobra.Command{}, nil)
			require.Error(t, err)
			assert.Contains(t, err.Error(), "--account is not supported by this dashboard")
			assert.Contains(t, err.Error(), "aggregates all connected sites")
		})
	}
}

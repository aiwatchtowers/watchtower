package tools

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// find_experts on a Linear key (current or previous) cites the assignee, the
// creator, a mapped commenter and the linked thread's participants, each with
// the issue key as a usable ref (DEV-03), weighed by the shipped "linear"
// weight.
func TestFindExperts_LinearIssueEvidence(t *testing.T) {
	d := openDB(t)
	seedLinearTaskFixture(t, d)
	_, err := d.Exec(`INSERT INTO linear_user_map (linear_user_id, email, slack_user_id, display_name) VALUES ('lu-cat', 'cat@example.com', 'U0CAT', 'Cat')`)
	require.NoError(t, err)

	for _, key := range []string{"OPS-3", "ENG-7"} {
		env := expertsEnv(t, d, `{"issue_key":"`+key+`"}`)
		assert.Equal(t, 2.0, env.Weights["linear"])
		kinds := map[string]map[string]bool{}
		for _, c := range env.Candidates {
			for _, e := range c.Evidence {
				if kinds[c.UserID] == nil {
					kinds[c.UserID] = map[string]bool{}
				}
				kinds[c.UserID][e.Kind+":"+e.Detail] = true
				if e.Kind == "linear" {
					assert.Equal(t, "OPS-3", e.Ref)
				}
			}
		}
		assert.True(t, kinds["U0ANN"]["linear:assignee of OPS-3"], key)
		assert.True(t, kinds["U0BOB"]["linear:creator of OPS-3"], key)
		assert.True(t, kinds["U0CAT"]["linear:1 comments on OPS-3"], key)
		require.NotNil(t, kinds["U0DAN"], "%s: the thread linked under the old key counts", key)
		assert.Empty(t, env.Notes, key)
	}
}

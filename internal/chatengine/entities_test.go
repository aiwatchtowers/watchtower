package chatengine

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// entityFixture is testdata/entity_search_cases.json: seed rows, then each
// query's ordered hits. The Swift twin (EntitySearchFixtureTests) runs
// MentionSearch (no kinds) or ChatEntitySearch.search per kind over the same
// rows.
type entityFixture struct {
	Seed  []string `json:"seed"`
	Cases []struct {
		Name  string      `json:"name"`
		Query string      `json:"query"`
		Kinds []string    `json:"kinds"`
		Hits  []EntityHit `json:"hits"`
	} `json:"cases"`
}

// TestEntitySearch_SharedCases: EntitySearch gives the Swift pickers' hits,
// in order, on every shared case.
func TestEntitySearch_SharedCases(t *testing.T) {
	b, err := os.ReadFile("testdata/entity_search_cases.json")
	require.NoError(t, err)
	var f entityFixture
	require.NoError(t, json.Unmarshal(b, &f))
	require.GreaterOrEqual(t, len(f.Cases), 10)
	g := newRig(t, fakeOpts{})
	for _, s := range f.Seed {
		_, err := g.d.Exec(s)
		require.NoError(t, err, s)
	}
	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			hits, err := g.r.EntitySearch(context.Background(), c.Query, c.Kinds)
			require.NoError(t, err)
			if hits == nil {
				hits = []EntityHit{}
			}
			assert.Equal(t, c.Hits, hits)
		})
	}
	_, err = g.r.EntitySearch(context.Background(), "x", []string{"jira_issue"})
	assert.Equal(t, "invalid", ErrorCode(err), "an unknown kind is refused")
}

// TestChatengine_SkillsListReadsWorkspaceSkills: skills_list is the
// workspace's enabled skills by name; a disabled or invalid file is left out.
func TestChatengine_SkillsListReadsWorkspaceSkills(t *testing.T) {
	g := newRig(t, fakeOpts{})
	dir := t.TempDir()
	write := func(name, content string) {
		require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600))
	}
	write("weekly-report.md", "---\ndescription: Write the weekly report\n---\nbody")
	write("triage.md", "---\ndescription: Triage the inbox\n---\nbody")
	write("off.md", "---\ndescription: Disabled\nenabled: false\n---\nbody")
	write("Bad Name.md", "---\ndescription: x\n---\n")
	g.r.c.SkillsDir = dir

	out, err := g.r.Do(context.Background(), "skills_list", nil, Client{Kind: "mac"})
	require.NoError(t, err)
	assert.JSONEq(t, `{"skills":[{"name":"triage","description":"Triage the inbox"},
		{"name":"weekly-report","description":"Write the weekly report"}]}`, string(out))

	g.r.c.SkillsDir = filepath.Join(dir, "missing")
	list, err := g.r.SkillsList(context.Background())
	require.NoError(t, err)
	assert.Empty(t, list)
}

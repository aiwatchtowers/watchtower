package workbenchgit

import "testing"

func TestWorktreeOrigin(t *testing.T) {
	cases := []struct {
		name              string
		top, root, branch string
		want              Origin
	}{
		{"subagent", "/r", "/r/.claude/worktrees/agent-3f9c0a17d2e4b6c1", "feature/x", OriginSubagent},
		{"placed", "/r", "/r/.claude/worktrees/search-filters", "wt/search-filters", OriginPlaced},
		{"not on wt branch", "/r", "/r/.claude/worktrees/search-filters", "feature/x", OriginManual},
		{"agent not hex", "/r", "/r/.claude/worktrees/agent-xyz", "lane/a", OriginManual},
		{"outside dir", "/r", "/other/acme-legacy", "wt/x", OriginManual},
		{"not a direct child", "/r", "/r/.claude/worktrees/a/b", "wt/b", OriginManual},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := WorktreeOrigin(c.top, c.root, c.branch); got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

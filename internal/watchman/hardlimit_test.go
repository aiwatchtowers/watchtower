package watchman

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func bash(cmd string) PermissionAsk {
	return PermissionAsk{Tool: "Bash", Summary: cmd, WorkbenchFolder: "/w", Worktrees: []string{"/w/a"}}
}

func TestParkedBy(t *testing.T) {
	prBase := func(m map[int]string) func(int) (string, bool) {
		return func(n int) (string, bool) { b, ok := m[n]; return b, ok }
	}
	withPR := func(cmd string, m map[int]string) PermissionAsk {
		r := bash(cmd)
		r.PRBase = prBase(m)
		return r
	}
	edit := func(tool, p string) PermissionAsk {
		return PermissionAsk{Tool: tool, Summary: p, WorkbenchFolder: "/w", Worktrees: []string{"/w/a"}}
	}
	cases := []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}{
		{"push main", bash("git push origin main"), LimitMainRef},
		{"push HEAD:main", bash("git push origin HEAD:main"), LimitMainRef},
		{"push feature", bash("git push origin feat"), ""},
		{"pr merge into main", withPR("gh pr merge 12 --squash", map[int]string{12: "main"}), LimitMainRef},
		{"pr merge into feature", withPR("gh pr merge 12", map[int]string{12: "feature/watchman"}), ""},
		{"pr merge unknown base", withPR("gh pr merge 12", nil), LimitMainRef},
		{"pr merge no resolver", bash("gh pr merge 12"), LimitMainRef},
		{"tag and push", bash("git tag v1 && git push --tags"), LimitTag},
		{"tag list", bash("git tag -l"), ""},
		{"release create", bash("gh release create v1"), LimitRelease},
		{"release list", bash("gh release list"), ""},
		{"altool upload", bash("xcrun altool --upload-app -f a.ipa"), LimitTestFlight},
		{"xcodebuild", bash("xcodebuild test"), ""},
		{"force push", bash("git push -f origin feat"), LimitForcePush},
		{"force with lease", bash("git push --force-with-lease origin feat"), LimitForcePush},
		{"plain push", bash("git push origin feat"), ""},
		{"reset onto remote", bash("git reset --hard origin/feature/x"), LimitResetShared},
		{"reset local", bash("git reset --hard HEAD~1"), ""},
		{"rm elsewhere", bash("rm -rf /tmp/elsewhere"), LimitDeleteOutside},
		{"rm inside worktree", bash("rm -rf /w/a/build"), ""},
		{"rm climbing out", bash("rm -rf /w/a/../b"), LimitDeleteOutside},
		{"slack send", PermissionAsk{Tool: "mcp__watchtower-workbench__send_slack_message", WorkbenchFolder: "/w"}, LimitOutward},
		{"gh pr comment", bash("gh pr comment 3 -b hi"), LimitOutward},
		{"other mcp tool", PermissionAsk{Tool: "mcp__watchtower-workbench__list_targets", WorkbenchFolder: "/w"}, ""},
		{"edit settings", edit("Edit", "/w/a/.claude/settings.json"), LimitStandingGrant},
		{"edit source", edit("Edit", "/w/a/main.go"), ""},
		{"edit outside", edit("Write", "/etc/hosts"), LimitOutsideFolder},
		{"edit in workbench folder", edit("Write", "/w/docs/x.md"), ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, parked := ParkedBy(c.ask)
			require.Equal(t, c.limit != "", parked)
			require.Equal(t, c.limit, got)
		})
	}
}

func TestParkedBy_UnknownPlacementParks(t *testing.T) {
	_, parked := ParkedBy(PermissionAsk{Tool: "Bash", Summary: "rm -rf x"})
	require.True(t, parked)
	l, parked := ParkedBy(PermissionAsk{Tool: "Edit", Summary: "/some/where/a.go"})
	require.True(t, parked)
	require.Equal(t, LimitOutsideFolder, l)
}

func TestPermissionFlags(t *testing.T) {
	f := permissionFlags(bash("git push origin main"))
	require.True(t, *f.IsDecision)
	require.True(t, *f.Parked)
	f = permissionFlags(bash("go test ./..."))
	require.True(t, *f.IsDecision)
	require.False(t, *f.Parked)
}

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
		{"edit path with spaces", edit("Write", "/w/a/my notes/x.md"), ""},
		{"edit path with spaces outside", edit("Write", "/etc/my notes/x.md"), LimitOutsideFolder},
		{"read json inside", edit("Read", `{"file_path":"/w/a/x.go"}`), ""},
		{"read json outside", edit("Read", `{"file_path":"/etc/hosts"}`), LimitOutsideFolder},
		{"multiedit outside", edit("MultiEdit", `{"file_path":"/etc/hosts","edits":[]}`), LimitOutsideFolder},
		{"glob outside", edit("Glob", `{"pattern":"*.go","path":"/etc"}`), LimitOutsideFolder},
		{"grep inside", edit("Grep", `{"pattern":"x","path":"/w/a"}`), ""},
		{"grep no path unplaced", edit("Grep", `{"pattern":"x"}`), LimitOutsideFolder},
		{"read clipped json unplaced", edit("Read", `{"file_path":"/w/a/x`), LimitOutsideFolder},
		{"edit empty summary", edit("Edit", ""), LimitOutsideFolder},
		{"read settings", edit("Read", `{"file_path":"/w/a/.claude/settings.local.json"}`), LimitStandingGrant},
		{"bash abs path not outside", bash("cat /etc/hosts"), ""},
		{"push no refspec", bash("git push"), ""},
		{"push remote only", bash("git push origin"), ""},
		{"rebase onto main", bash("git rebase origin/main"), LimitMainRef},
		{"rebase -i main", bash("git rebase -i main"), LimitMainRef},
		{"rebase onto flag", bash("git rebase --onto origin/master feat~2"), LimitMainRef},
		{"rebase feature", bash("git rebase origin/feature/x"), ""},
		{"env wrapper push", bash("GIT_SSH=x git push origin main"), LimitMainRef},
		{"sudo push", bash("sudo git push origin main"), LimitMainRef},
		{"env cmd push", bash("env FOO=1 git push origin main"), LimitMainRef},
		{"time push", bash("time git push origin master"), LimitMainRef},
		{"nohup push", bash("nohup git push origin main"), LimitMainRef},
		{"command push", bash("command git push origin main"), LimitMainRef},
		{"abs git push", bash("/usr/bin/git push origin main"), LimitMainRef},
		{"abs rm", bash("/bin/rm -rf /tmp/x"), LimitDeleteOutside},
		{"sudo rm", bash("sudo rm -rf /tmp/x"), LimitDeleteOutside},
		{"env rm", bash("FOO=1 rm -rf /tmp/x"), LimitDeleteOutside},
		{"xargs rm stdin", bash("find . -name x | xargs rm -f"), LimitDeleteOutside},
		{"xargs rm explicit inside", bash("echo | xargs rm -f /w/a/x"), LimitDeleteOutside},
		{"cd elsewhere rm", bash("cd /tmp && rm -rf x"), LimitDeleteOutside},
		{"cd worktree rm", bash("cd /w/a/sub && rm -rf build"), ""},
		{"cd unknown rm", bash("cd ~/x && rm -rf build"), LimitDeleteOutside},
		{"rm relative no cd", bash("rm -rf build"), ""},
		{"rm in described command", bash("rm -rf build\n# git push origin main"), ""},
		{"description names push", bash("go test ./...\n# git push origin main"), ""},
		{"sudo -u push", bash("sudo -u build git push origin main"), LimitMainRef},
		{"env -u push", bash("env -u VAR git push origin main"), LimitMainRef},
		{"nice -n push", bash("nice -n 5 git push origin main"), LimitMainRef},
		{"xargs -n rm", bash("ls | xargs -n 1 rm"), LimitDeleteOutside},
		{"sudo -u feature push", bash("sudo -u build git push origin feat"), ""},
		{"bare wrapper unresolved", bash("sudo -u"), LimitMainRef},
		{"cd or true rm", bash("cd /w/a || true; rm -rf x"), LimitDeleteOutside},
		{"cd semicolon rm", bash("cd /w/a; rm -rf x"), LimitDeleteOutside},
		{"cd and rm", bash("cd /w/a && rm -rf x"), ""},
		{"rebase -s ort main", bash("git rebase -s ort main"), LimitMainRef},
		{"rebase -X theirs main", bash("git rebase -X theirs origin/main"), LimitMainRef},
		{"rebase -s ort feature", bash("git rebase -s ort origin/feature/x"), ""},
		{"edit json fallback", edit("Edit", `{"file_path":"/w/a/x.go"}`), LimitOutsideFolder},
		{"description mentions push", bash("go test ./...\n# Run checks; git push origin main is next"), ""},
		{"mail", bash("mail -s hi a@example.com"), LimitOutward},
		{"sendmail", bash("sendmail a@example.com"), LimitOutward},
		{"gmail send", PermissionAsk{Tool: "mcp__claude_ai_Gmail__send_email", WorkbenchFolder: "/w"}, LimitOutward},
		{"gmail draft send", PermissionAsk{Tool: "mcp__gmail__send_draft", WorkbenchFolder: "/w"}, LimitOutward},
		{"gmail search", PermissionAsk{Tool: "mcp__gmail__search_threads", WorkbenchFolder: "/w"}, ""},
		{"gh pr review", bash("gh pr review 3 --approve"), LimitOutward},
		{"gh issue comment", bash("gh issue comment 3 -b hi"), LimitOutward},
		{"gh pr create", bash("gh pr create --fill"), ""},
		{"gh issue close", bash("gh issue close 3"), ""},
		{"gh pr edit", bash("gh pr edit 3 --title x"), ""},
		{"echo testflight", bash("echo testflight"), ""},
		{"grep testflight", bash("grep testflight x"), ""},
		{"altool help", bash("xcrun altool --help"), ""},
		{"iTMSTransporter", bash("iTMSTransporter -m upload"), LimitTestFlight},
		{"fastlane pilot", bash("fastlane pilot upload"), LimitTestFlight},
		{"make testflight", bash("make mobile-testflight"), LimitTestFlight},
		{"make test", bash("make test"), ""},
		{"pr merge flag value", withPR("gh pr merge --body 5 12", map[int]string{12: "feature/x"}), ""},
		{"pr merge flag value unknown", withPR("gh pr merge --body 5 12", map[int]string{5: "feature/x"}), LimitMainRef},
		{"pr merge url", withPR("gh pr merge https://github.com/a/b/pull/12", map[int]string{12: "feature/x"}), LimitMainRef},
		{"pr merge branch", withPR("gh pr merge feat", map[int]string{12: "feature/x"}), LimitMainRef},
		{"pr merge bare", withPR("gh pr merge", map[int]string{12: "feature/x"}), LimitMainRef},
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

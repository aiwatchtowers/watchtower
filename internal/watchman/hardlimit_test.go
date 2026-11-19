package watchman

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func bash(cmd string) PermissionAsk {
	return PermissionAsk{Tool: "Bash", Summary: cmd, WorkbenchFolder: "/w", Worktrees: []string{"/w/a"}}
}

func TestParkedBy(t *testing.T) {
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
		// The pre-push hook's bypasses still name main here (Task 6 review).
		{"push main without hooks", bash("git push --no-verify origin main"), LimitMainRef},
		{"push main with another hooks path", bash("git -c core.hooksPath=/dev/null push origin main"), LimitMainRef},
		{"push main with config from env", bash("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x git push origin main"), LimitMainRef},
		// The plumbing push no hook sees parks whatever it pushes.
		{"send-pack to main", bash("git send-pack origin HEAD:refs/heads/main"), LimitSendPack},
		{"git-send-pack to master", bash("/usr/libexec/git-core/git-send-pack ../acme.git master"), LimitSendPack},
		{"send-pack all", bash("git send-pack --all origin"), LimitSendPack},
		{"send-pack mirror", bash("git send-pack --mirror origin"), LimitSendPack},
		{"send-pack refs from stdin", bash("echo x | git send-pack --stdin origin"), LimitSendPack},
		{"send-pack no ref named", bash("git send-pack origin"), LimitSendPack},
		{"send-pack HEAD", bash("git send-pack origin HEAD"), LimitSendPack},
		{"send-pack feature", bash("git send-pack origin feat:refs/heads/feat"), LimitSendPack},
		{"send-pack tag", bash("git send-pack origin refs/tags/v1:refs/tags/v1"), LimitSendPack},
		{"send-pack force update", bash("git send-pack --force origin +feat:refs/heads/feat"), LimitSendPack},
		{"send-pack behind git globals", bash("git -C ../acme send-pack origin feat"), LimitSendPack},
		{"pr merge into main", bash("gh pr merge 12 --squash"), LimitMainRef},
		{"pr merge into feature", bash("gh pr merge 12"), LimitMainRef},
		{"pr merge unknown base", bash("gh pr merge 12"), LimitMainRef},
		{"pr merge no resolver", bash("gh pr merge 12"), LimitMainRef},
		// The base is read in the session folder: a merge in another
		// repository parks whatever that read says (Task 10 review).
		{"pr merge --repo", bash("gh pr merge 12 --repo acme/other"), LimitMainRef},
		{"pr merge --repo=", bash("gh pr merge 12 --repo=acme/other"), LimitMainRef},
		{"pr merge -R", bash("gh pr merge -R acme/other 12"), LimitMainRef},
		{"pr merge -Rrepo", bash("gh pr merge 12 -Racme/other"), LimitMainRef},
		{"pr merge -sR", bash("gh pr merge 12 -sR acme/other"), LimitMainRef},
		{"pr merge after cd", bash("cd ../other && gh pr merge 12"), LimitMainRef},
		{"pr merge env -C", bash("env -C ../other gh pr merge 12"), LimitMainRef},
		{"pr merge GH_REPO", bash("GH_REPO=acme/other gh pr merge 12"), LimitMainRef},
		{"pr merge export GH_REPO", bash("export GH_REPO=acme/other; gh pr merge 12"), LimitMainRef},
		{"pr merge GH_HOST", bash("GH_HOST=ghe.example.com gh pr merge 12"), LimitMainRef},
		{"pr merge URL", bash("gh pr merge https://github.com/acme/other/pull/12"), LimitMainRef},
		{"pr merge squash into feature", bash("gh pr merge 12 --squash --delete-branch"), LimitMainRef},
		{"gh -R before pr", bash("gh -R acme/other pr merge 12"), LimitMainRef},
		{"gh --repo before pr", bash("gh --repo acme/other pr merge 12"), LimitMainRef},
		{"gh --repo= before pr", bash("gh --repo=acme/other pr merge 12"), LimitMainRef},
		{"gh -Rx before pr", bash("gh -Racme/other pr merge 12"), LimitMainRef},
		{"gh flag value named pr", bash("gh -R pr pr merge 12"), LimitMainRef}, //nolint:dupword // the flag value "pr" is the point
		{"pushd then pr merge", bash("pushd ../other && gh pr merge 12"), LimitMainRef},
		{"checkout then pr merge", bash("git checkout other && gh pr merge 12"), LimitMainRef},
		{"gh pr checkout then pr merge", bash("gh pr checkout 7 && gh pr merge 12"), LimitMainRef},
		{"env GH_REPO pr merge", bash("env GH_REPO=acme/other gh pr merge 12"), LimitMainRef},
		{"export GH_HOST then pr merge", bash("export GH_HOST=ghe.example.com && gh pr merge 12"), LimitMainRef},
		// Phase 2: every PR merge is the owner's, whatever its base or form
		// (Task 10 review round 3).
		{"gh pr -R merge", bash("gh pr -R acme/other merge 12"), LimitMainRef},
		{"gh pr --repo= merge", bash("gh pr --repo=acme/other merge 12"), LimitMainRef},
		{"gh pr --repo merge", bash("gh pr --repo acme/other merge 12"), LimitMainRef},
		{"standalone GH_REPO line then merge", bash("GH_REPO=acme/other\ngh pr merge 12"), LimitMainRef},
		{"gh api pulls merge", bash("gh api -X PUT repos/acme/x/pulls/12/merge"), LimitMainRef},
		{"gh api pulls merge with braces", bash("gh api --method PUT repos/{owner}/{repo}/pulls/12/merge -f merge_method=squash"), LimitMainRef},
		{"gh api graphql mergePullRequest", bash(`gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }'`), LimitMainRef},
		{"curl pulls merge", bash("curl -X PUT https://api.github.com/repos/acme/x/pulls/12/merge"), LimitMainRef},
		{"hub merge", bash("hub merge https://github.com/acme/x/pull/12"), LimitMainRef},
		{"gh api pulls read", bash("gh api repos/acme/x/pulls/12"), ""},
		{"gh pr view", bash("gh pr -R acme/x view 12"), ""},
		{"gh pr -R comment", bash("gh pr -R acme/x comment 3 -b hi"), LimitOutward},
		{"gh pr --repo= review", bash("gh pr --repo=acme/x review 3 --approve"), LimitOutward},
		{"gh issue -R comment", bash("gh issue -R acme/x comment 3 -b hi"), LimitOutward},
		{"gh release -R create", bash("gh release -R acme/x create v1"), LimitRelease},
		{"gh -R before pr comment", bash("gh -R acme/other pr comment 3 -b hi"), LimitOutward},
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
		{"read settings", edit("Read", `{"file_path":"/w/a/.claude/settings.local.json"}`), ""},
		{"read settings plain", edit("Read", `{"file_path":"/w/a/.claude/settings.json"}`), ""},
		{"write settings local", edit("Write", "/w/a/.claude/settings.local.json"), LimitStandingGrant},
		{"multiedit settings", edit("MultiEdit", `{"file_path":"/w/a/.claude/settings.json"}`), LimitStandingGrant},
		{"notebook settings", edit("NotebookEdit", ".claude/settings.json"), LimitStandingGrant},
		{"edit codex config", edit("Edit", "/w/a/.codex/config.toml"), LimitStandingGrant},
		{"read codex config", edit("Read", `{"file_path":"/w/a/.codex/config.toml"}`), ""},
		{"edit settings lookalike", edit("Edit", "/w/a/docs/claude-settings.json"), ""},
		{"bash cat settings", bash("cat .claude/settings.json"), ""},
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
		{"rm relative subdir up", bash("rm -rf build/.."), ""},
		{"rm relative climbs out", bash("rm -rf build/../.."), LimitDeleteOutside},
		{"rm dot climbs out", bash("rm -rf ./.."), LimitDeleteOutside},
		{"edit relative climbs out", edit("Edit", "docs/../../x.go"), LimitOutsideFolder},
		{"edit relative stays in", edit("Edit", "docs/../x.go"), ""},
		{"rm in described command", bash("rm -rf build\n# git push origin main"), ""},
		{"description names push", bash("go test ./...\n# git push origin main"), ""},
		{"sudo -u push", bash("sudo -u build git push origin main"), LimitMainRef},
		{"env -u push", bash("env -u VAR git push origin main"), LimitMainRef},
		{"nice -n push", bash("nice -n 5 git push origin main"), LimitMainRef},
		{"xargs -n rm", bash("ls | xargs -n 1 rm"), LimitDeleteOutside},
		{"sudo -u feature push", bash("sudo -u build git push origin feat"), ""},
		{"bare wrapper unresolved", bash("sudo -u"), LimitUnreadable},
		{"cd or true rm", bash("cd /w/a || true; rm -rf x"), LimitDeleteOutside},
		{"cd semicolon rm", bash("cd /w/a; rm -rf x"), LimitDeleteOutside},
		{"cd and rm", bash("cd /w/a && rm -rf x"), ""},
		{"rebase -s ort main", bash("git rebase -s ort main"), LimitMainRef},
		{"rebase -X theirs main", bash("git rebase -X theirs origin/main"), LimitMainRef},
		{"rebase -s ort feature", bash("git rebase -s ort origin/feature/x"), ""},
		{"edit json fallback", edit("Edit", `{"file_path":"/w/a/x.go"}`), LimitOutsideFolder},
		{"description mentions push", bash("go test ./...\n# Run checks; git push origin main is next"), ""},
		{"inner comment before push", bash("echo x\n# note\ngit push origin main"), LimitMainRef},
		{"inner comment and description", bash("echo x\n# note\ngit push origin main\n# desc"), LimitMainRef},
		{"rebase exec quoted main", bash(`git rebase --exec "echo main" feature`), ""},
		{"rebase exec quoted onto main", bash(`git rebase --exec "make test" main`), LimitMainRef},
		{"bracket path", edit("Write", "/w/a/[draft].md"), ""},
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
		{"pr merge flag value", bash("gh pr merge --body 5 12"), LimitMainRef},
		{"pr merge flag value unknown", bash("gh pr merge --body 5 12"), LimitMainRef},
		{"pr merge url", bash("gh pr merge https://github.com/a/b/pull/12"), LimitMainRef},
		{"pr merge branch", bash("gh pr merge feat"), LimitMainRef},
		{"pr merge bare", bash("gh pr merge"), LimitMainRef},
		{"edit in workbench folder", edit("Write", "/w/docs/x.md"), ""},
		{"escaped quote hides no path", bash(`rm O\'Brien /tmp/obsolete`), LimitDeleteOutside},
		{"escaped quote inside", bash(`rm -f O\'Brien /w/a/x`), ""},
		{"quoted path inside", bash(`rm "/w/a/a b"`), ""},
		{"double-quote escape", bash(`rm "/w/a/x\"y" /tmp/z`), LimitDeleteOutside},
		{"single quote no escape", bash(`rm '/w/a/x\' /tmp/z`), LimitDeleteOutside},
		{"unterminated quote", bash(`echo "abc`), LimitUnreadable},
		{"quoted separator", bash(`git commit -m "fix; tidy" && git push origin feat`), ""},
		{"quoted separator hides no push", bash(`echo "a" ; git push origin main`), LimitMainRef},
		{"comment line separator", bash("# Next step; git push origin main\ngo test ./..."), ""},
		{"numeric file name", edit("Write", "123"), ""},
		{"true file name", edit("Write", "true"), ""},
		{"null file name", edit("Edit", "null"), ""},
		{"json array is a file name", edit("Edit", `["x"]`), ""},
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
	clipped := bash("go test ./...")
	clipped.SummaryClipped = true
	f = permissionFlags(clipped)
	require.True(t, *f.IsDecision)
	require.True(t, *f.Parked, "a clipped summary hides its tail: it parks")
}

// expectParked runs ParkedBy over each case and checks the row it parks under
// ("" = not parked).
func expectParked(t *testing.T, cases []struct {
	name  string
	ask   PermissionAsk
	limit HardLimit
}) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, parked := ParkedBy(c.ask)
			require.Equal(t, c.limit != "", parked)
			require.Equal(t, c.limit, got)
		})
	}
}

func TestParkedBy_ResetHardOnSharedLocalBranch(t *testing.T) {
	onBranch := func(cmd string, b *BranchInfo) PermissionAsk {
		r := bash(cmd)
		r.Branch = b
		return r
	}
	shared := []string{"main", "feature/watchman"}
	expectParked(t, []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}{
		{"checkout main then reset", bash("git checkout main && git reset --hard HEAD~1"), LimitResetShared},
		{"switch master then reset", bash("git switch master; git reset --hard HEAD~1"), LimitResetShared},
		{"checkout feature then reset", bash("git checkout feat && git reset --hard HEAD~1"), LimitResetShared},
		{"reset then checkout main", bash("git reset --hard HEAD~1 && git checkout main"), ""},
		{"checkout file then reset", bash("git checkout feat -- a.go && git reset --hard HEAD~1"), LimitResetShared},
		{"checkout -B main", bash("git checkout -B main HEAD~2"), LimitResetShared},
		{"branch -f main", bash("git branch -f main HEAD~2"), LimitResetShared},
		{"branch --force master", bash("git branch --force master HEAD~2"), LimitResetShared},
		{"branch -D main", bash("git branch -D main"), LimitResetShared},
		{"branch -M main", bash("git branch -M main"), LimitResetShared},
		{"branch -f feature", bash("git branch -f feat HEAD~2"), ""},
		{"branch create", bash("git branch main2"), ""},
		{"branch -f umbrella", onBranch("git branch -f feature/watchman HEAD~2", &BranchInfo{Current: "wt/session-3", Shared: shared}), LimitResetShared},
		{"update-ref master", bash("git update-ref refs/heads/master abc"), LimitResetShared},
		{"update-ref -d main", bash("git update-ref -d refs/heads/main"), LimitResetShared},
		{"update-ref feature", bash("git update-ref refs/heads/feat abc"), ""},
		{"update-ref stdin", bash("git update-ref --stdin"), LimitResetShared},
		{"reset on shared current", onBranch("git reset --hard HEAD~1", &BranchInfo{Current: "feature/watchman", Shared: shared}), LimitResetShared},
		{"reset on main current", onBranch("git reset --hard HEAD~1", &BranchInfo{Current: "main"}), LimitResetShared},
		{"reset on session branch", onBranch("git reset --hard HEAD~1", &BranchInfo{Current: "wt/session-3", Shared: shared}), ""},
		{"reset on unknown branch", onBranch("git reset --hard HEAD~1", &BranchInfo{Current: "", Shared: shared}), LimitResetShared},
		{"reset branch not recorded", onBranch("git reset --hard HEAD~1", nil), ""},
		{"soft reset on shared", onBranch("git reset --soft HEAD~1", &BranchInfo{Current: "main"}), ""},
		{"switch away then reset", onBranch("git switch wt/session-3 && git reset --hard HEAD~1", &BranchInfo{Current: "main"}), LimitResetShared},
		{"switch -c then reset", onBranch("git switch -c wt/new && git reset --hard HEAD~1", &BranchInfo{Current: "wt/session-3"}), LimitResetShared},
		{"checkout dot then reset", onBranch("git checkout . && git reset --hard HEAD~1", &BranchInfo{Current: "feat", Shared: shared}), LimitResetShared},
		{"reset alone on feature", onBranch("git reset --hard HEAD~1", &BranchInfo{Current: "feat", Shared: shared}), ""},
		{"gh pr checkout then reset", onBranch("gh pr checkout 12 && git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"git -C reset", onBranch("git -C /other reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"git -C reset not recorded", bash("git -C /other reset --hard HEAD~1"), LimitResetShared},
		{"git --git-dir reset", onBranch("git --git-dir=/other/.git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"cd then reset", onBranch("cd /main && git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"cd semicolon then reset", bash("cd /w/a; git reset --hard HEAD~1"), LimitResetShared},
		{"pushd then reset", onBranch("pushd /main && git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"checkout without reset", onBranch("git checkout main && go test ./...", &BranchInfo{Current: "feat"}), ""},
		{"branch -C onto main", bash("git branch -C x main"), LimitResetShared},
		{"branch --copy -f onto main", bash("git branch --copy -f x main"), LimitResetShared},
		{"branch -m -f onto main", bash("git branch -m -f x main"), LimitResetShared},
		{"branch -m without force", bash("git branch -m x main"), ""},
		{"branch -fD main", bash("git branch -fD main"), LimitResetShared},
		{"branch -fq main", bash("git branch -fq main HEAD~2"), LimitResetShared},
		{"branch -fM main", bash("git branch -fM x main"), LimitResetShared},
		{"branch -M rename current main", onBranch("git branch -M newname", &BranchInfo{Current: "main"}), LimitResetShared},
		{"branch -M rename current unknown", onBranch("git branch -M newname", &BranchInfo{Current: ""}), LimitResetShared},
		{"branch -M rename current feature", onBranch("git branch -M newname", &BranchInfo{Current: "feat", Shared: shared}), ""},
		{"branch -M rename after cd", bash("cd /main && git branch -M newname"), LimitResetShared},
		{"switch --force-create main", bash("git switch --force-create main"), LimitResetShared},
		{"switch -fB main", bash("git switch -fB main"), LimitResetShared},
		{"checkout -fC main", bash("git checkout -fC main origin/x"), LimitResetShared},
		{"checkout -B feature from main", bash("git checkout -B feat main"), ""},
		{"update-ref HEAD on feature", onBranch("git update-ref HEAD abc", &BranchInfo{Current: "feat", Shared: shared}), ""},
		// Shared not known (nil): every destructive ref move parks; a
		// reset --hard with no target or HEAD stays private (Task 10 review).
		{"update-ref HEAD shared unknown", onBranch("git update-ref HEAD abc", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"update-ref feature shared unknown", onBranch("git update-ref refs/heads/feat abc", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"branch -f shared unknown", onBranch("git branch -f feat HEAD~2", &BranchInfo{Current: "wt/session-3"}), LimitResetShared},
		{"branch -D shared unknown", onBranch("git branch -D feat", &BranchInfo{Current: "wt/session-3"}), LimitResetShared},
		{"checkout -B shared unknown", onBranch("git checkout -B feat main", &BranchInfo{Current: "wt/session-3"}), LimitResetShared},
		{"reset HEAD~3 shared unknown", onBranch("git reset --hard HEAD~3", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"reset sha shared unknown", onBranch("git reset --hard abc123", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"reset no target shared unknown", onBranch("git reset --hard", &BranchInfo{Current: "feat"}), ""},
		{"reset HEAD shared unknown", onBranch("git reset --hard HEAD", &BranchInfo{Current: "feat"}), ""},
		{"reset -q no target shared unknown", onBranch("git reset -q --hard", &BranchInfo{Current: "feat"}), ""},
		{"branch -f feature shared known", onBranch("git branch -f feat HEAD~2", &BranchInfo{Current: "wt/session-3", Shared: shared}), ""},
		{"git -c then -C reset", onBranch("git -c core.x=1 -C /other reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"git -c then -C reset not recorded", bash("git -c core.x=1 -C /other reset --hard HEAD~1"), LimitResetShared},
		{"git --git-dir separate reset", bash("git --git-dir /x reset --hard"), LimitResetShared},
		{"git --work-tree= reset", bash("git --work-tree=/x reset --hard HEAD~1"), LimitResetShared},
		{"git -c only reset on feature", onBranch("git -c core.x=1 reset --hard HEAD~1", &BranchInfo{Current: "feat", Shared: shared}), ""},
		{"git -c only reset shared unknown", onBranch("git -c core.x=1 reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"git --namespace separate reset on main", onBranch("git --namespace ns reset --hard HEAD~1", &BranchInfo{Current: "main"}), LimitResetShared},
		{"git --exec-path= reset on main", onBranch("git --exec-path=/x reset --hard HEAD~1", &BranchInfo{Current: "main"}), LimitResetShared},
		{"git -c branch -f main", bash("git -c core.x=1 branch -f main HEAD~2"), LimitResetShared},
		{"checkout -Bmain", bash("git checkout -Bmain"), LimitResetShared},
		{"switch -Cmain", bash("git switch -Cmain"), LimitResetShared},
		{"switch --force-create=main", bash("git switch --force-create=main"), LimitResetShared},
		{"switch -fCmain", bash("git switch -fCmain origin/x"), LimitResetShared},
		{"switch -Cfeature", bash("git switch -Cfeat"), ""},
		{"checkout -- -B main is a path checkout", bash("git checkout -- -B main"), ""},
		{"checkout -- -B main then reset", onBranch("git checkout -- -B main && git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"branch -- after force", bash("git branch -f -- main"), LimitResetShared},
		{"rebase onto main then reset", bash("git rebase main feat && git reset --hard"), LimitMainRef}, // parked by the earlier main_ref row
		{"rebase then reset", onBranch("git rebase origin/feature/x wt/x && git reset --hard HEAD~1", &BranchInfo{Current: "wt/session-3"}), LimitResetShared},
		{"rebase then reset not recorded", bash("git rebase origin/feature/x wt/x && git reset --hard"), LimitResetShared},
		{"worktree then reset", onBranch("git worktree add ../x main; git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"GIT_DIR reset", onBranch("GIT_DIR=/other/.git git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"GIT_WORK_TREE reset not recorded", bash("GIT_WORK_TREE=/other git reset --hard HEAD~1"), LimitResetShared},
		{"env GIT_DIR reset", bash("env GIT_DIR=/other/.git git reset --hard HEAD~1"), LimitResetShared},
		{"export GIT_DIR then reset", bash("export GIT_DIR=/other/.git && git reset --hard HEAD~1"), LimitResetShared},
		{"env -C reset", onBranch("env -C /other git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"other env reset on feature", onBranch("GIT_TRACE=1 git reset --hard HEAD~1", &BranchInfo{Current: "feat", Shared: shared}), ""},
		{"update-ref HEAD after checkout", onBranch("git checkout main; git update-ref HEAD abc", &BranchInfo{Current: "feat"}), LimitResetShared},
	})
}

func TestParkedBy_InlineCommentApostrophe(t *testing.T) {
	expectParked(t, []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}{
		{"comment with apostrophe", bash("go test ./... # don't cache"), ""},
		{"push with comment", bash("git push origin main # it's fine"), LimitMainRef},
		{"hash inside quotes", bash(`echo "it's # not a comment" && git push origin main`), LimitMainRef},
		{"hash inside a word", bash("echo a#b"), ""},
		{"hash inside a word then push", bash("echo a#b; git push origin main"), LimitMainRef},
		{"escaped hash", bash(`echo \# 'open`), LimitUnreadable},
		{"comment hides separator", bash("go test ./... # then; git push origin main"), ""},
		{"comment ends at newline", bash("go test ./... # don't\ngit push origin main"), LimitMainRef},
		{"comment on a continued line", bash("go test \\\n# don't cache"), ""},
		{"continuation then comment then push", bash("go test \\\n# don't\ngit push origin main"), LimitMainRef},
		{"continuation inside a word is no comment", bash("echo a\\\n#b; git push origin main"), LimitMainRef},
	})
}

func TestParkedBy_DescriptionLinesAreComments(t *testing.T) {
	expectParked(t, []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}{
		{"two description lines", bash("go test ./...\n# Run tests\n# then don't push to main"), ""},
		{"description names a push", bash("go test ./...\n# Run tests\n# git push origin main"), ""},
	})
}

func TestParkedBy_JSONPathFieldsDecodedApart(t *testing.T) {
	ask := func(tool, summary string) PermissionAsk {
		return PermissionAsk{Tool: tool, Summary: summary, WorkbenchFolder: "/wb"}
	}
	expectParked(t, []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}{
		{"read with numeric path", ask("Read", `{"file_path":"/wb/a.go","path":7}`), ""},
		{"read numeric path only", ask("Read", `{"path":7}`), LimitOutsideFolder},
		{"read outside with numeric path", ask("Read", `{"file_path":"/etc/hosts","path":7}`), LimitOutsideFolder},
		{"grep relative path", ask("Grep", `{"pattern":"x","path":"src"}`), ""},
		{"edit bracket file name", ask("Edit", "[1]"), ""},
		{"edit object fallback", ask("Edit", `{"file_path":"/elsewhere/x","old_string":"a"}`), LimitOutsideFolder},
	})
}

func TestParkedBy_UnreadableIsItsOwnRow(t *testing.T) {
	expectParked(t, []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}{
		{"bare sudo", bash("sudo"), LimitUnreadable},
		{"env with only an assignment", bash("env FOO=1"), LimitUnreadable},
		{"unterminated single quote", bash("echo 'open"), LimitUnreadable},
		{"unreadable before push", bash("sudo; git push origin main"), LimitUnreadable},
	})
}

// The call's start directory places a relative path but is no directory
// change: a local reset on a private branch from outside the worktrees is
// not reset_shared, while a relative delete there is outside.
func TestParkedBy_StartDirPlacesOnly(t *testing.T) {
	ask := func(cmd string) PermissionAsk {
		return PermissionAsk{Tool: "Bash", Summary: cmd, Worktrees: []string{"/wt"}, Cwd: "/elsewhere",
			Branch: &BranchInfo{Current: "feature/x", Shared: []string{"main"}}}
	}
	_, parked := ParkedBy(ask("git reset --hard HEAD~1"))
	require.False(t, parked)
	l, parked := ParkedBy(ask("rm -rf build"))
	require.True(t, parked)
	require.Equal(t, LimitDeleteOutside, l)
	inside := ask("rm -rf build")
	inside.Cwd = "/wt/sub"
	_, parked = ParkedBy(inside)
	require.False(t, parked)
	// A cd in the command itself still counts as a move.
	l, parked = ParkedBy(ask("cd /tmp && git reset --hard HEAD~1"))
	require.True(t, parked)
	require.Equal(t, LimitResetShared, l)
}

func TestBranchDependent(t *testing.T) {
	for cmd, want := range map[string]bool{
		"go test ./...":                  false,
		"git status && git diff":         false,
		"rm -rf build":                   false,
		"gh pr view 12":                  false,
		"git reset --hard HEAD~1":        true,
		"git -C ../x branch -f feat":     true,
		"go vet && git push origin feat": true,
		"git update-ref HEAD abc":        true,
		"git checkout -B feat":           true,
		"gh -R acme/x pr merge 12":       false,
	} {
		require.Equal(t, want, BranchDependent(bash(cmd)), cmd)
	}
	require.False(t, BranchDependent(PermissionAsk{Tool: "Edit", Summary: "git reset --hard"}))
}

// A shell running a string is a wrapper (Task 10 review round 3): its one
// literal string is parsed in place; anything else cannot be read.
func TestParkedBy_ShellStringsAreWrappers(t *testing.T) {
	expectParked(t, []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}{
		{"bash -c push main", bash(`bash -c 'git push origin main'`), LimitMainRef},
		{"sh -c pr merge", bash(`sh -c "gh pr merge 12"`), LimitMainRef},
		{"zsh -lc force push", bash(`zsh -lc 'go vet && git push -f origin feat'`), LimitForcePush},
		{"eval release", bash(`eval 'gh release create v1'`), LimitRelease},
		{"nested shells", bash(`bash -c "sh -c 'git push --tags'"`), LimitTag},
		{"env -C bash -c reset", bash(`env -C /other bash -c 'git reset --hard HEAD~1'`), LimitResetShared},
		{"eval cd carries on", bash(`eval 'cd /tmp' && rm -rf build`), LimitDeleteOutside},
		{"bash -c harmless", bash(`bash -c 'go test ./...'`), ""},
		{"eval harmless", bash(`eval 'go vet ./...'`), ""},
		{"bash script file", bash(`bash scripts/check.sh`), ""},
		{"bash -c with a variable", bash(`bash -c "$CMD"`), LimitUnreadable},
		{"bash -c with a backtick", bash("bash -c 'git push origin `cat ref`'"), LimitUnreadable},
		{"bash -c with extra args", bash(`bash -c 'git push "$0" main' origin`), LimitUnreadable},
		{"eval of many words", bash(`eval git push origin main`), LimitUnreadable},
		{"bash -c without a string", bash(`bash -c`), LimitUnreadable},
		{"source a file", bash(`source scripts/env.sh && go test ./...`), LimitUnreadable},
		{"dot a file", bash(`. ./env.sh`), LimitUnreadable},
		{"xargs sh -c", bash(`echo x | xargs sh -c 'git push origin feat'`), LimitUnreadable},
		{"too deep", bash(`bash -c "bash -c 'bash -c \"bash -c go\"'"`), LimitUnreadable},
		// Shell options with operands before -c (round 4).
		{"bash -o pipefail -c", bash(`bash -o pipefail -c 'git push origin main'`), LimitMainRef},
		{"bash --rcfile -c", bash(`bash --rcfile x.rc -c 'gh release create v1'`), LimitRelease},
		{"bash +O extglob -c harmless", bash(`bash +O extglob -c 'go test ./...'`), ""},
		{"bash -c after a script", bash(`bash script.sh -c 'git push origin main'`), LimitUnreadable},
		// A string run elsewhere has no known directory (round 4).
		{"env -C bash -c relative delete", bash(`env -C /x bash -c 'rm -rf y'`), LimitDeleteOutside},
		{"cd then bash -c relative delete", bash(`cd /tmp && bash -c 'rm -rf y'`), LimitDeleteOutside},
		{"bash -c relative delete here", bash(`bash -c 'rm -rf y'`), ""},
	})
}

// Round 4: shapes the parser does not follow park as unreadable, and a
// coarse text backstop parks any merge-looking request with a tool that
// can merge a pull request (main_ref), however the command is shaped.
func TestParkedBy_HiddenShapesAndMergeBackstop(t *testing.T) {
	expectParked(t, []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}{
		{"subshell", bash("(gh pr merge 1)"), LimitUnreadable},
		{"group", bash("{ gh pr merge 1; }"), LimitUnreadable},
		{"command substitution", bash("echo $(gh pr merge 1)"), LimitUnreadable},
		{"backtick substitution", bash("echo `git push origin main`"), LimitUnreadable},
		{"background job", bash("true & gh pr merge 1"), LimitUnreadable},
		{"if body", bash("if true; then gh pr merge 1; fi"), LimitUnreadable},
		{"for body", bash("for b in a; do git push origin main; done"), LimitUnreadable},
		{"negation", bash("! gh pr merge 1"), LimitUnreadable},
		{"pipe into bash", bash("echo 'gh pr merge 1' | bash"), LimitUnreadable},
		{"pipe into sh", bash("cat cmds.txt | sh"), LimitUnreadable},
		{"here-string", bash("bash <<< 'gh pr merge 1'"), LimitUnreadable},
		{"gh alias set", bash("gh alias set m 'pr merge'"), LimitUnreadable},
		{"gh api body from a file", bash("gh api graphql -F query=@m.graphql"), LimitUnreadable},
		{"gh api --input", bash("gh api repos/o/r/pulls --input body.json"), LimitUnreadable},
		{"gh api merges endpoint", bash("gh api -X POST repos/o/r/merges -f base=main"), LimitMainRef},
		{"curl merges endpoint", bash("curl -X POST https://api.github.com/repos/o/r/merges"), LimitMainRef},
		{"auto-merge mutation", bash(`gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }'`), LimitMainRef},
		{"auto-merge setting", bash("gh api -X PATCH repos/o/r -F allow_auto_merge=true"), LimitMainRef},
		{"automerge word", bash("gh label create automerge"), LimitMainRef},
		{"pr merge --auto", bash("gh pr merge 1 --auto --squash"), LimitMainRef},
		{"merge word in the description", bash("gh pr view 1\n# check it before the merge"), LimitMainRef},
		{"merge word and gh apart", bash("git log --grep merge && gh pr view 1"), LimitMainRef},
		// What the backstop and the shapes leave alone.
		{"go test -run Merge", bash("go test ./... -run Merge"), ""},
		{"go test TestMergeRows", bash("go test ./internal/x -run TestMergeRows"), ""},
		{"git merge without a PR tool", bash("git merge --no-ff feature/x"), ""},
		{"gh without a merge word", bash("gh pr view 1 --json title"), ""},
		{"stderr redirect", bash("go test ./... 2>&1 | tail -5"), ""},
		{"both streams redirect", bash("make build &> build.log"), ""},
		{"bash -c list", bash("bash -c 'go vet ./... && go test ./...'"), ""},
		// Wrappers added in round 4.
		{"timeout", bash("timeout 30 git push origin main"), LimitMainRef},
		{"timeout with options", bash("timeout -k 5 -s KILL 1m git push --tags"), LimitTag},
		{"caffeinate", bash("caffeinate -i git push -f origin feat"), LimitForcePush},
		{"doas", bash("doas gh release create v1"), LimitRelease},
		{"stdbuf attached", bash("stdbuf -oL git push origin main"), LimitMainRef},
		{"stdbuf separate", bash("stdbuf -o L git push origin main"), LimitMainRef},
		{"timeout harmless", bash("timeout 10m go test ./..."), ""},
	})
}

// Round 5: hidden shapes are read on the raw text with quote context and
// before the wrappers; the guard's lenient mode parks one only with a
// hard-limit word in the command text, and its backstop skips comments.
func TestParkedBy_HiddenShapesStrictAndLenient(t *testing.T) {
	lenient := func(cmd string) PermissionAsk {
		r := bash(cmd)
		r.Lenient = true
		return r
	}
	heredocCommit := "git commit -m \"$(cat <<'EOF'\nFix the export\n\nCo-Authored-By: someone\nEOF\n)\""
	ordinary := []string{
		heredocCommit,
		`gh pr create --title "Fix" --body "$(cat body.md)"`,
		"for f in *.go; do gofmt -l $f; done",
		"while read -r l; do echo $l; done < list.txt",
		"make build &",
		"echo $(date)",
		"(cd sub && make)",
		"FOO=$(date) true",
		"source venv/bin/activate && go test ./...",
	}
	var cases []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}
	add := func(name string, ask PermissionAsk, limit HardLimit) {
		cases = append(cases, struct {
			name  string
			ask   PermissionAsk
			limit HardLimit
		}{name, ask, limit})
	}
	for _, cmd := range ordinary {
		add("strict "+cmd, bash(cmd), LimitUnreadable)
		add("lenient "+cmd, lenient(cmd), "")
	}
	for _, cmd := range []string{"x $(git push origin HEAD:main)", "x=$(git push origin HEAD:main)", "true & gh pr merge 1", "(git push --force origin feat)"} {
		add("strict "+cmd, bash(cmd), LimitUnreadable)
		add("lenient "+cmd, lenient(cmd), LimitUnreadable)
	}
	// Quote context: single quotes are literal, & inside quotes is no job.
	for _, cmd := range []string{
		`echo '$(not run) and a backtick: ` + "`x`" + `'`,
		`curl 'https://example.com/?a=1&b=2'`,
		`git commit -m "fish & chips"`,
		`echo 'a <<< b'`,
	} {
		add("strict quoted "+cmd, bash(cmd), "")
	}
	// The backstop reads comments only in strict mode.
	add("strict comment merge", bash("gh pr view 1 # merge"), LimitMainRef)
	add("lenient comment merge", lenient("gh pr view 1 # merge"), "")
	add("lenient description merge", lenient("gh pr view 1\n# before the merge"), "")
	add("lenient command merge", lenient("gh pr merge 1"), LimitMainRef)
	// A script operand is no command on stdin.
	add("pipe into bash script", bash("make gen | bash scripts/apply.sh"), "")
	add("pipe into bash", bash("make gen | bash"), LimitUnreadable)
	add("pipe into sh -s", bash("make gen | sh -s"), LimitUnreadable)
	// GIT_DIR points git elsewhere but moves no directory.
	add("GIT_DIR bash -c relative delete", bash("GIT_DIR=/x/.git bash -c 'rm -rf build'"), "")
	add("GIT_DIR bash -c reset", bash("GIT_DIR=/x/.git bash -c 'git reset --hard HEAD~1'"), LimitResetShared)
	expectParked(t, cases)
}

// Round 6: the commit/PR-body heredoc idiom is blanked for the guard's word
// scan only when it is plain; rebase and rm of an outside path are limit
// words; a shell on a pipe is parsed for -s and its options; a variable as
// the program and a function definition are hidden shapes.
func TestParkedBy_HeredocIdiomAndMoreHiddenShapes(t *testing.T) {
	lenient := func(cmd string) PermissionAsk {
		r := bash(cmd)
		r.Lenient = true
		return r
	}
	var cases []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}
	add := func(name string, ask PermissionAsk, limit HardLimit) {
		cases = append(cases, struct {
			name  string
			ask   PermissionAsk
			limit HardLimit
		}{name, ask, limit})
	}
	both := func(name, cmd string, lenientLimit HardLimit) {
		add("strict "+name, bash(cmd), LimitUnreadable)
		add("lenient "+name, lenient(cmd), lenientLimit)
	}
	// Blanked: a plain argument with a quoted delimiter.
	both("commit heredoc", "git commit -m \"$(cat <<'EOF'\nrelease notes before merge\nEOF\n)\"", "")
	both("pr create heredoc", "gh pr create --title \"Fix\" --body \"$(cat <<'EOF'\nreview the push and the tag\nEOF\n)\"", "")
	both("backslash delimiter", "git commit -m \"$(cat <<\\EOF\nrelease it\nEOF\n)\"", "")
	// Round 8: a wrapper in front is off the allowlist, so the body is scanned.
	both("wrapped commit heredoc", "env GIT_AUTHOR_NAME=x git commit -m \"$(cat <<'EOF'\nrelease\nEOF\n)\"", LimitUnreadable)
	// Not blanked.
	// "EOF" inside the double-quoted word closes the reader's quote: it
	// cannot be told from an unquoted delimiter, so it stays scanned.
	both("double-quoted delimiter", "git commit -m \"$(cat <<\"EOF\"\nrelease it\nEOF\n)\"", LimitUnreadable)
	both("sh -c heredoc", "sh -c \"$(cat <<'EOF'\ngit push origin main\nEOF\n)\"", LimitUnreadable)
	both("bare heredoc", "$(cat <<'EOF'\ngit push origin feat\nEOF\n)", LimitUnreadable)
	both("unquoted delimiter", "git commit -m \"$(cat <<EOF\n$(git push)\nEOF\n)\"", LimitUnreadable)
	both("heredoc first word", "\"$(cat <<'EOF'\ngit push\nEOF\n)\" x", LimitUnreadable)
	both("assignment heredoc", "MSG=\"$(cat <<'EOF'\nrelease\nEOF\n)\" git commit", LimitUnreadable)
	both("eval heredoc", "eval \"$(cat <<'EOF'\ngit push origin feat\nEOF\n)\"", LimitUnreadable)
	both("xargs heredoc", "xargs git commit -m \"$(cat <<'EOF'\nrelease\nEOF\n)\"", LimitUnreadable)
	both("another hidden shape", "git commit -m \"$(cat <<'EOF'\nrelease\nEOF\n)\" $(git push origin feat)", LimitUnreadable)
	both("heredoc then text", "git commit -m \"$(cat <<'EOF'\nx\nEOF\n) and release\"", LimitUnreadable)
	add("single-quoted string is not dropped", lenient("echo 'git push' | sh"), LimitUnreadable)
	add("strict single-quoted pipe", bash("echo 'git push' | sh"), LimitUnreadable)
	// rebase and an outside rm are limit words.
	both("rebase in a loop", "for b in a; do git rebase main; done", LimitUnreadable)
	both("rm of an absolute path", "make x & rm /etc/hosts", LimitUnreadable)
	both("rm of a parent path", "make x & rm ../other/file", LimitUnreadable)
	both("rm of a home path", "make x & rm ~/notes", LimitUnreadable)
	both("rm of a relative path", "make x & rm build.log", "")
	// A shell on a pipe.
	add("pipe into bash -s arg", bash("make gen | bash -s arg"), LimitUnreadable)
	add("pipe into bash -o x script", bash("make gen | bash -o pipefail scripts/apply.sh"), "")
	add("pipe into bash --rcfile only", bash("make gen | bash --rcfile x.rc"), LimitUnreadable)
	add("pipe into bash -- script", bash("make gen | bash -- scripts/apply.sh"), "")
	// A variable as the program, a function definition.
	both("variable program", "$G push origin main", LimitUnreadable)
	both("variable program, no limit word", "$CMD origin main", "")
	both("braced variable program", "${GIT} status", "")
	both("function definition", "f() { git push origin main; }; f", LimitUnreadable)
	both("function keyword", "function f { make; }", "")
	// The guard's merge backstop reads the blanked text too; the twin's
	// reads it whole.
	prBody := "gh pr create --title \"Fix\" --body \"$(cat <<'EOF'\nmerge it into feature/x after the review\nEOF\n)\""
	add("strict PR body says merge", bash(prBody), LimitUnreadable)
	add("lenient PR body says merge", lenient(prBody), "")
	add("lenient gh pr merge", lenient("gh pr merge 1"), LimitMainRef)
	add("lenient sh -c heredoc merge", lenient("sh -c \"$(cat <<'EOF'\ngh pr merge 1\nEOF\n)\""), LimitUnreadable)
	// Round 7: a sibling part could run the blanked body, or the owner is
	// no message taker — the body is scanned.
	push := "\"$(cat <<'EOF'\ngit push origin main\nEOF\n)\""
	both("echo heredoc into sh", "echo "+push+" | sh", LimitUnreadable)
	both("printf heredoc into bash", "printf '%s\\n' "+push+" | bash", LimitUnreadable)
	both("commit heredoc piped into sh", "git commit -m "+push+" | sh", LimitUnreadable)
	both("cat redefined", "cat() { sh; }; git commit -m "+push, LimitUnreadable)
	both("commit heredoc then eval", "git commit -m "+push+"; eval 'make'", LimitUnreadable)
	both("commit heredoc then source", "git commit -m "+push+" && source env.sh", LimitUnreadable)
	both("commit heredoc then sh -c", "git commit -m "+push+" && sh -c 'make'", LimitUnreadable)
	both("commit heredoc then variable program", "git commit -m "+push+" && $RUN", LimitUnreadable)
	both("echo is no message taker", "echo \"$(cat <<'EOF'\nrelease notes\nEOF\n)\"", LimitUnreadable)
	both("git tag -a heredoc still a tag", "git tag -a v1 -m \"$(cat <<'EOF'\nfirst cut\nEOF\n)\"", LimitUnreadable)
	both("gh issue create heredoc", "gh issue create --title x --body \"$(cat <<'EOF'\npush it before the release\nEOF\n)\"", "")
	both("gh pr edit heredoc", "gh pr edit 3 --body \"$(cat <<'EOF'\nreview after the push\nEOF\n)\"", "")
	both("commit heredoc then a plain command", "git commit -m \"$(cat <<'EOF'\nrelease notes\nEOF\n)\" && go test ./...", "")
	// rm: .. is a parent only as a path segment.
	both("rm of ..cache", "make x & rm ..cache", "")
	both("rm of ..", "make x & rm ..", LimitUnreadable)
	// Round 8: the blanking needs every other part on the plain allowlist.
	body := "\"$(cat <<'EOF'\ngit push origin main\nEOF\n)\""
	msg := "\"$(cat <<'EOF'\nrelease notes, push after the review\nEOF\n)\""
	for name, cmd := range map[string]string{
		"hash -p":               "hash -p /bin/sh cat; git commit -m " + body,
		"alias cat=sh":          "alias cat=sh\ngit commit -m " + body,
		"ln, export PATH":       "ln -s /bin/sh cat; export PATH=.:$PATH; git commit -m " + body,
		"message run as script": "git commit -m " + body + " && git log -1 --format=%B > x.sh && chmod +x x.sh && ./x.sh",
		"PATH assignment":       "PATH=. git commit -m " + body,
		"git -c before commit":  "git -c core.hooksPath=x commit -m " + body,
		"commit -c":             "git commit -c HEAD -m " + body,
		"commit redirected":     "git commit -m " + body + " > out.txt",
		"go test -exec":         "go test -exec sh ./... && git commit -m " + body,
		"make with a variable":  "make SHELL=sh x && git commit -m " + body,
		"absolute program":      "/usr/bin/git commit -m " + body,
		"command builtin":       "command -p true && git commit -m " + body,
		"tee":                   "git commit -m " + body + " | tee x.sh",
		"git diff --ext-diff":   "git diff --ext-diff && git commit -m " + body,
	} {
		both("probe "+name, cmd, LimitUnreadable)
	}
	for name, cmd := range map[string]string{
		"add then commit":      "git add -A && git commit -m " + msg,
		"commit then go test":  "git commit -m " + msg + " && go test ./...",
		"cd then commit":       "cd /w/a && git commit -m " + msg,
		"pr create":            "gh pr create --title \"Fix\" --body " + msg,
		"status, diff, commit": "git status && git diff --stat && git commit -m " + msg,
		"gofmt, vet, commit":   "gofmt -l . && go vet ./... && git commit -m " + msg,
		"make target, commit":  "make lint && git commit -m " + msg,
		"swift test, commit":   "swift test && git commit -m " + msg,
		"echo, commit":         "echo done && git commit -m " + msg,
	} {
		both("idiom "+name, cmd, "")
	}
	// rm's operand is read with its quotes and escapes removed.
	both("rm of ..\\/x", "make x & rm ..\\/x", LimitUnreadable)
	both("rm of quoted .. then /x", "make x & rm \"..\"\\/x", LimitUnreadable)
	both("rm of \\/etc", "make x & rm \\/etc/hosts", LimitUnreadable)
	// Round 9: a zsh glob qualifier runs code, so ( outside quotes is no
	// plain part; go's --flags are its -flags; rm counts only at command
	// position.
	both("ls glob qualifier", "git commit -m "+body+" && ls *(e:'git log -1 --format=%B|sh':)", LimitUnreadable)
	both("git add glob qualifier", "git add *(+fn) && git commit -m "+body, LimitUnreadable)
	both("ls glob, plain", "ls *.go && git commit -m "+msg, "")
	both("go test --exec", "go test --exec sh ./... && git commit -m "+body, LimitUnreadable)
	both("go test --toolexec=", "go test --toolexec=x ./... && git commit -m "+body, LimitUnreadable)
	both("go vet --vettool=", "go vet --vettool=x ./... && git commit -m "+body, LimitUnreadable)
	both("go build --o", "go build --o x . && git commit -m "+body, LimitUnreadable)
	both("go test --count", "go test --count=1 ./... && git commit -m "+msg, "")
	// rm counts in any position (round 9 item 3 reverted): an echo argument
	// named rm parks too, which fails closed.
	both("rm as an echo argument", `echo "$(pwd)" rm example /tmp`, LimitUnreadable)
	both("rm in a then-body", `if true; then rm "/x"; fi`, LimitUnreadable)
	both("rm in a group", `{ rm "/x"; }`, LimitUnreadable)
	both("rm glued behind &", `sleep 1&rm "/x"`, LimitUnreadable)
	both("rm after a glued &&", `a&& rm "/x" && echo $(date)`, LimitUnreadable)
	both("sudo rm behind &", "make x & sudo rm /tmp/x", LimitUnreadable)
	both("rm after a hidden part", "echo $(date) && rm \\/tmp/x", LimitUnreadable)
	both("xargs rm behind &", "make x & xargs rm ~/y", LimitUnreadable)
	expectParked(t, cases)
	// The strict backstop alone (the unreadable row comes first above).
	r := bash(prBody)
	require.True(t, mergeBackstop(r), "the twin's backstop reads the body")
	r.Lenient = true
	require.False(t, mergeBackstop(r), "the guard's backstop skips the plain body")
}

// Final review A-C1: a wrapper that changes directory leaves a relative
// delete with no known directory, in the twin's strict mode and the
// guard's lenient mode alike; env -S runs a string this reader cannot see.
func TestParkedBy_WrapperChdirRelativeDelete(t *testing.T) {
	var cases []struct {
		name  string
		ask   PermissionAsk
		limit HardLimit
	}
	both := func(cmd string, limit HardLimit) {
		strict, lenient := bash(cmd), bash(cmd)
		lenient.Lenient = true
		for _, r := range []PermissionAsk{strict, lenient} {
			name := "strict " + cmd
			if r.Lenient {
				name = "lenient " + cmd
			}
			cases = append(cases, struct {
				name  string
				ask   PermissionAsk
				limit HardLimit
			}{name, r, limit})
		}
	}
	both("env -C /tmp rm -rf foo", LimitDeleteOutside)
	both("env -C/tmp rm -rf foo", LimitDeleteOutside)
	both("env --chdir=/tmp rm -rf foo", LimitDeleteOutside)
	both("env --chdir /tmp rm -rf foo", LimitDeleteOutside)
	both("sudo -D /tmp rm -rf foo", LimitDeleteOutside)
	both("sudo -D/tmp rm -rf foo", LimitDeleteOutside)
	both("env -iC/tmp rm -rf foo", LimitDeleteOutside)
	both("env -iC /tmp rm -rf foo", LimitDeleteOutside)
	both("env -S 'rm -rf foo'", LimitUnreadable)
	both("env --split-string='rm -rf foo'", LimitUnreadable)
	both("env -i rm -rf foo", "")
	both("rm -rf foo", "")
	expectParked(t, cases)
}

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
		{"pr merge flag value", withPR("gh pr merge --body 5 12", map[int]string{12: "feature/x"}), ""},
		{"pr merge flag value unknown", withPR("gh pr merge --body 5 12", map[int]string{5: "feature/x"}), LimitMainRef},
		{"pr merge url", withPR("gh pr merge https://github.com/a/b/pull/12", map[int]string{12: "feature/x"}), LimitMainRef},
		{"pr merge branch", withPR("gh pr merge feat", map[int]string{12: "feature/x"}), LimitMainRef},
		{"pr merge bare", withPR("gh pr merge", map[int]string{12: "feature/x"}), LimitMainRef},
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
		{"update-ref HEAD on feature", onBranch("git update-ref HEAD abc", &BranchInfo{Current: "feat"}), ""},
		{"git -c then -C reset", onBranch("git -c core.x=1 -C /other reset --hard HEAD~1", &BranchInfo{Current: "feat"}), LimitResetShared},
		{"git -c then -C reset not recorded", bash("git -c core.x=1 -C /other reset --hard HEAD~1"), LimitResetShared},
		{"git --git-dir separate reset", bash("git --git-dir /x reset --hard"), LimitResetShared},
		{"git --work-tree= reset", bash("git --work-tree=/x reset --hard HEAD~1"), LimitResetShared},
		{"git -c only reset on feature", onBranch("git -c core.x=1 reset --hard HEAD~1", &BranchInfo{Current: "feat"}), ""},
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
		{"other env reset on feature", onBranch("GIT_TRACE=1 git reset --hard HEAD~1", &BranchInfo{Current: "feat"}), ""},
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
			Branch: &BranchInfo{Current: "feature/x"}}
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

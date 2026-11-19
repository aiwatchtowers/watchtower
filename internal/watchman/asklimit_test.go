package watchman

import "testing"

// TestAskParkedBy pins every row of the ask-text table: one text it parks,
// and a near miss it leaves to the twin.
func TestAskParkedBy(t *testing.T) {
	cases := []struct {
		name, text string
		want       HardLimit // "" = not parked
	}{
		{"merge into main", "Shall I merge feature/x into main now?", LimitMainRef},
		{"merge main into a branch", "Shall I merge main into feature/x first?", ""},
		{"push to master", "Ready to push the fix to origin/master?", LimitMainRef},
		{"push to a branch", "Ready to push the fix to feature/x?", ""},
		{"rebase onto main", "Should I rebase this branch onto main?", LimitMainRef},
		{"rebase onto umbrella", "Should I rebase this branch onto feature/watchman?", ""},
		{"git push main", "Run git push origin main?", LimitMainRef},
		{"git push branch", "Run git push origin feature/main-fix?", ""},
		{"russian merge into main", "Смержить ветку в main?", LimitMainRef},
		{"russian merge into branch", "Смержить main в feature/x?", ""},
		{"cut a release", "Can I cut a release for this?", LimitRelease},
		{"release notes", "Should I update the release notes?", ""},
		{"russian release", "Выпустить новый релиз?", LimitRelease},
		{"russian release notes", "Обновить заметки к релизу?", ""},
		{"git tag", "Shall I run git tag v1.4.0?", LimitTag},
		{"html tag", "Should the title use an h2 tag?", ""},
		{"testflight", "Upload the build to TestFlight?", LimitTestFlight},
		{"flight data", "Should the test fly through the flight table?", ""},
		{"slack message", "Send a summary to the team on Slack?", LimitOutward},
		{"slack thread read", "Should I read the Slack thread for context?", ""},
		{"slack tool", "May I call send_slack_message with the summary?", LimitOutward},
		{"gh pr comment", "Run gh pr comment 12 with the results?", LimitOutward},
		{"pr comment", "Should I comment on the PR with the benchmark?", LimitOutward},
		{"pr comments addressed", "Should I address the PR comments first?", ""},
		{"inventory path", "Approve the change to docs/inventory/watchman.md?", LimitInventory},
		{"inventory of files", "Keep an inventory of files in the README?", ""},
		{"guard test name", "Can I relax TestWATCHMAN04_NothingActsOnUnarmedSession?", LimitInventory},
		{"ordinary test name", "Can I rename TestHelper_parses?", ""},
		{"markdown code main", "Shall I merge feature/x into `main`?", LimitMainRef},
		{"markdown bold master", "Ready to push the fix to **master**?", LimitMainRef},
		{"quoted main", "Should I rebase onto \"main\"?", LimitMainRef},
		{"markdown feature branch", "Shall I merge `main` into `feature/x`?", ""},
		{"quoted feature branch", "Ready to push the fix to 'feature/main-fix'?", ""},
		// Final review A-M1: any PR merge, whatever its base, and a forced push.
		{"merge the PR into a feature branch", "Shall I merge the PR into feature/watchman?", LimitMainRef},
		{"merge pull request", "Can I merge pull request #12 now?", LimitMainRef},
		{"merge by number", "Squash and merge #12?", LimitMainRef},
		{"PR be merged", "Should the PR be merged once CI is green?", LimitMainRef},
		{"land the PR", "Can I land this PR?", LimitMainRef},
		{"gh pr merge", "Run gh pr merge 12 --squash?", LimitMainRef},
		{"merge through the api", "Call the GitHub api to merge it?", LimitMainRef},
		{"russian PR merge", "Смержить PR в feature/x?", LimitMainRef},
		{"russian pull request merge", "Влить пулл-реквест?", LimitMainRef},
		{"merge main into a branch, no PR", "Merge main into feature/x to pick up the fix?", ""},
		{"PR review comments", "Should I address the PR review comments first?", ""},
		{"force push", "Force-push the rebased branch?", LimitForcePush},
		{"push --force", "Run git push --force origin feature/x?", LimitForcePush},
		{"push --force-with-lease", "OK to push --force-with-lease after the rebase?", LimitForcePush},
		{"push -f", "Can I git push -f origin feature/x?", LimitForcePush},
		{"push a plus refspec", "Run git push origin +feature/x?", LimitForcePush},
		{"russian force push", "Можно сделать форс-пуш ветки?", LimitForcePush},
		{"plain push", "Push the branch to origin/feature/x?", ""},
		{"push with a flag", "Run git push -u origin feature/x?", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := AskParkedBy(c.text)
			if ok != (c.want != "") || got != c.want {
				t.Fatalf("AskParkedBy(%q) = %q, %v; want %q", c.text, got, ok, c.want)
			}
		})
	}
}

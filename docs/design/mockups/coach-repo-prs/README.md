# Coach repository edits as pull requests: mockups

Mockups for the Desktop side of spec
`docs/superpowers/specs/2026-11-19-coach-repo-edits-as-prs-design.md` §4.4–§4.6.
They were drawn with test-target mock views
(`WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+CoachRepoPRs.swift`, first version) before the real
views changed. Every text in them comes from the model (`CoachPRTexts`, `CoachProposal.verdictLine`). Each
state has a light and a dark PNG. All data is synthetic (`acme/repo`, PR #12 and #13).

| State | File |
|---|---|
| Accepted edits with every PR state: PR open (waiting for the merge), merged and measuring, verdict given, rolled back with a revert PR waiting ("Revert: PR #13 — merge it…"), PR closed without merge ("Rolled back · PR #12 closed"), not merged in 30 days (`too_little_data`); the sync line over the list when `coach sync-prs` could not read a PR | `coach-repo-prs-accepted-{light,dark}.png` |
| Roll Back refused with `pr_unreadable`: the row's line with gh's words, Retry | `coach-repo-prs-rollback-retry-{light,dark}.png` |
| Accept refused with `no_gh`: the `gh auth login` line, no Retry | `coach-repo-prs-accept-no-gh-{light,dark}.png` |
| Accept refused with `base_differs`: no Retry (pull, then ask the chat again) | `coach-repo-prs-accept-base-differs-{light,dark}.png` |
| Accept refused with `push_failed`: git's words, Retry | `coach-repo-prs-accept-push-failed-{light,dark}.png` |
| Accept refused with `pr_failed`: gh's words, Retry | `coach-repo-prs-accept-pr-failed-{light,dark}.png` |
| Accept refused with `timeout`: Retry | `coach-repo-prs-accept-timeout-{light,dark}.png` |
| The tuning panel's folded card: "Accepted · waiting for PR #12 to merge" and the PR link | `coach-repo-prs-folded-waiting-{light,dark}.png` |
| Roll Back of a merged PR whose file moved on the default branch (`changed_since`, final review fix wave): the diff, "<file> on the default branch changed since the merge — revert it by hand in a pull request.", only **Close** (no Roll Back Anyway); added after the first drawing, so its mockup is the real view's render | `coach-repo-prs-rollback-pr-changed-{light,dark}.png` |

The renders of the real views after the change are in `after/`, under the same names.

After the review round (Task 5 fix round 1), the real views differ from these mockups as follows. The mockups are
kept as the record of the first drawing.
- A row with its "PR #N" link no longer names the PR again in its text: "Waiting for the merge", "Not merged in 30
  days — not measured", "Rolled back · PR closed". The folded tuning card reads "Accepted · waiting for the PR to
  merge" beside its link.
- The revert line ends "— merge it to remove the edit." (no "from main": the default branch may differ).
- The sync line is one sentence chosen by `sync_code`, never the CLI's joined `sync_error`.
- An open repository card's caption is the file alone (no branch): before Accept the Desktop cannot tell a pull
  request from a working-copy write.

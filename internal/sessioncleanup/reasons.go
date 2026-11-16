package sessioncleanup

// allReasonCodes is every reason code an item can carry, in declaration
// order (catches, ownership, apply). The Desktop sorts each into a group
// of the background cleanup's outcome (WatchtowerCore
// `SessionAutoCleanupOutcome`) and reads this list from
// testdata/reason_codes.json, so a code added here without a group fails
// its tests. TestReasonCodesFixture keeps the list equal to the package's
// Reason* constants and the fixture equal to the list.
func allReasonCodes() []string {
	return []string{
		// Catches (catches.go).
		ReasonMainFolder,
		ReasonWorkbenchFolder,
		ReasonLocked,
		ReasonUncommittedChanges,
		ReasonProcessRunning,
		ReasonProcessUnknown,
		ReasonSessionInIt,
		ReasonYouAreInIt,
		ReasonUnpushedCommits,
		ReasonOperationInProgress,
		ReasonDefaultBranch,
		ReasonDefaultBranchUnknown,
		ReasonCheckedOut,
		ReasonClaudeHome,
		ReasonNotAWorktree,
		ReasonNotABranch,
		ReasonSessionRecent,
		ReasonCheckFailed,
		ReasonContainsWorktree,
		// Ownership (ownership.go).
		ReasonNotThisSession,
		ReasonExistedBeforeSession,
		ReasonCreatedUnknown,
		// Apply (apply.go).
		ReasonGitRefused,
		ReasonMoved,
		ReasonNotSelected,
		ReasonNotInPlan,
		ReasonNotAttempted,
		ReasonWorktreeKept,
		ReasonBundleExists,
		ReasonBundleUnreadable,
	}
}

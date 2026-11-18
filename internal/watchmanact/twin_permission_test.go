package watchmanact

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/askanswer"
	"watchtower/internal/db"
	"watchtower/internal/watchman"
)

// permRun is the fake git and gh of a permission's live reads: the
// session's branch by call (branches[n] for the nth read, the last
// repeated); the base of the current branch's PR (headBase, "" = no PR:
// gh fails); each numbered PR's base by call (bases[n] for the nth
// `gh pr view <n>`, the last repeated); the open PRs on the current branch
// (onTop); ghErr fails every gh call.
type permRun struct {
	mu       sync.Mutex
	branches []string
	headBase string
	bases    []string
	onTop    int
	ghErr    error
	calls    []string
	nBranch  int
	nBase    int
}

func (r *permRun) run(_ context.Context, dir, name string, args ...string) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	line := strings.Join(args, " ")
	r.calls = append(r.calls, dir+": "+name+" "+line)
	switch {
	case name == "git":
		r.nBranch++
		return []byte(r.branches[min(r.nBranch, len(r.branches))-1] + "\n"), nil
	case name != "gh":
		return nil, errors.New("unexpected command " + name)
	case r.ghErr != nil:
		return nil, r.ghErr
	case strings.HasPrefix(line, "pr list"):
		return []byte(`[` + strings.Repeat(`{"number":7}`, min(r.onTop, 1)) + `]`), nil
	case strings.HasPrefix(line, "pr view --json"):
		if r.headBase == "" {
			return nil, errors.New("no pull requests found for branch")
		}
		return []byte(r.headBase + "\n"), nil
	case strings.HasPrefix(line, "pr view"):
		r.nBase++
		return []byte(r.bases[min(r.nBase, len(r.bases))-1] + "\n"), nil
	}
	return nil, errors.New("unexpected gh " + line)
}

// withPermRun puts a fake git/gh under the twin.
func (e *twinEnv) withPermRun(r *permRun) {
	e.twin.d.Run = r.run
}

// permission opens a pending permission request of the armed session and
// queues its item, as the permission-wait hook does.
func (e *twinEnv) permission(tool, summary string, clipped bool) (reqID, itemID int64) {
	e.t.Helper()
	reqID, err := e.db.OpenPermissionRequest(e.session, e.wb, "uuid", tool, summary, clipped, time.Now(), db.AgentOrder{})
	e.must(err)
	itemID, inserted, err := e.db.QueueWatchmanItem(db.WatchmanItem{WorkbenchID: e.wb, SessionID: e.session,
		Kind: "permission", RefKind: "permission", RefID: reqID, Question: db.WatchmanPermissionText(tool, summary)})
	e.must(err)
	if !inserted {
		e.t.Fatal("item not queued")
	}
	return reqID, itemID
}

func (e *twinEnv) permStatus(id int64) (status, decidedBy string) {
	e.t.Helper()
	var by sql.NullString
	e.must(e.db.QueryRow(`SELECT status, decided_by FROM permission_requests WHERE id = ?`, id).Scan(&status, &by))
	return status, by.String
}

// wantPermission checks the request's status and decider.
func (e *twinEnv) wantPermission(id int64, status, decidedBy string) {
	e.t.Helper()
	if s, by := e.permStatus(id); s != status || by != decidedBy {
		e.t.Fatalf("request = %s by %q, want %s by %q", s, by, status, decidedBy)
	}
}

func permDecision(choice string) watchman.Decision {
	return watchman.Decision{Choice: choice, Rationale: "the owner runs tests freely", Category: watchman.CategoryPermission,
		Confidence: "high", Importance: "low", Handoff: watchman.HandoffNone}
}

// WATCHMAN-01: every §5 row, the owner's added limit included, is denied
// for the owner (parked, decided by watchman) and never reaches the model.
func TestWATCHMAN01_TwinNeverDecidesHardLimit(t *testing.T) {
	cases := []struct {
		name, tool, summary string
		limit               watchman.HardLimit
	}{
		{"unreadable", "Bash", `echo "unterminated`, watchman.LimitUnreadable},
		{"send-pack", "Bash", "git send-pack origin feat:refs/heads/feat", watchman.LimitSendPack},
		{"push main", "Bash", "git push origin HEAD:main", watchman.LimitMainRef},
		{"pr merge into main", "Bash", "gh pr merge 12 --squash", watchman.LimitMainRef},
		{"tag", "Bash", "git tag v1 && git push --tags", watchman.LimitTag},
		{"release", "Bash", "gh release create v1", watchman.LimitRelease},
		{"testflight", "Bash", "xcrun altool --upload-app -f a.ipa", watchman.LimitTestFlight},
		{"force push", "Bash", "git push -f origin feat", watchman.LimitForcePush},
		{"reset shared", "Bash", "git reset --hard origin/feature/x", watchman.LimitResetShared},
		{"delete outside", "Bash", "rm -rf /etc/elsewhere", watchman.LimitDeleteOutside},
		{"outward", "mcp__watchtower-workbench__send_slack_message", `{"channel":"general","text":"hi"}`, watchman.LimitOutward},
		{"standing grant", "Edit", "/tmp/acme/.claude/settings.json", watchman.LimitStandingGrant},
		{"outside folder", "Write", "/etc/hosts", watchman.LimitOutsideFolder},
		{"owner", "Bash", "make deploy-prod", watchman.LimitOwner},
	}
	covered := map[watchman.HardLimit]bool{}
	for _, c := range cases {
		covered[c.limit] = true
		t.Run(c.name, func(t *testing.T) {
			e := newTwinEnv(t)
			e.withPermRun(&permRun{branches: []string{"feature/x"}, bases: []string{"main"}})
			_, err := e.db.AddWatchmanExtraLimit(watchman.ExtraLimitCommand, "make deploy-prod")
			e.must(err)
			reqID, itemID := e.permission(c.tool, c.summary, false)
			e.run()
			it := e.item(itemID)
			wantOutcome(t, it, OutcomeParked)
			if it.ParkReason != limitReason(c.limit) {
				t.Fatalf("park reason = %q, want %q", it.ParkReason, limitReason(c.limit))
			}
			e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
			if e.decideCalls() != 0 {
				t.Fatal("Decide ran on a hard-limit request")
			}
		})
	}
	for _, l := range append(watchman.BuiltinLimits(), watchman.LimitOwner) {
		if !covered[l] {
			t.Errorf("no case for the %s row", l)
		}
	}
}

func TestTwin_PermissionClippedParks(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x"}})
	reqID, itemID := e.permission("Bash", "go test ./...", true)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeParked)
	if it.ParkReason != reasonClipped {
		t.Fatalf("park reason = %q", it.ParkReason)
	}
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
	if e.decideCalls() != 0 {
		t.Fatal("Decide ran on a clipped request")
	}
}

func TestTwin_PermissionAllowWritesDecidedByWatchman(t *testing.T) {
	e := newTwinEnv(t)
	run := &permRun{branches: []string{"feature/x"}, headBase: "feature/watchman"}
	e.withPermRun(run)
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return permDecision(PermissionAllow), nil
	}
	reqID, itemID := e.permission("Bash", "go test ./internal/x\n# Run the tests", false)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeAnswered)
	if !it.Unsure || it.Choice != PermissionAllow || it.Category != watchman.CategoryPermission {
		t.Fatalf("item = %+v, want an unsure allow of category permission", it)
	}
	e.wantPermission(reqID, db.PermissionAllowed, askanswer.ByWatchman)
	got := e.decided[0]
	if got.Category != watchman.CategoryPermission || strings.Join(got.Options, ",") != "allow,deny" ||
		got.Situation != "Tool: Bash\ngo test ./internal/x\n# Run the tests" || got.WorkbenchID != e.wb {
		t.Fatalf("Decide item = %+v", got)
	}
	if len(e.labelled) != 0 {
		t.Fatal("a permission went through the ask-text label call")
	}
	// Read before the model and again before the allow is written.
	want := []string{
		"/tmp/acme: git rev-parse --abbrev-ref HEAD",
		"/tmp/acme: gh pr view --json baseRefName --jq .baseRefName",
		"/tmp/acme: gh pr list --base feature/x --state open --limit 1 --json number",
	}
	if strings.Join(run.calls, "|") != strings.Join(append(want, want...), "|") {
		t.Fatalf("live reads = %q, want %q twice", run.calls, want)
	}
}

func TestTwin_PermissionDenyWritesDecidedByWatchman(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x"}})
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return permDecision(PermissionDeny), nil
	}
	reqID, itemID := e.permission("WebFetch", "https://example.com/doc", false)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeAnswered)
	if it.Choice != PermissionDeny {
		t.Fatalf("choice = %q", it.Choice)
	}
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
}

func TestTwin_PermissionHandoffDeniesHanded(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x"}})
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		d := permDecision(PermissionAllow)
		d.Handoff = watchman.HandoffOwnerOnly
		return d, nil
	}
	reqID, itemID := e.permission("Bash", "go test ./...", false)
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeHanded)
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
}

// The Mac answers while the model runs: its CAS wins, the twin writes
// nothing and journals the owner first.
func TestTwin_PermissionOwnerFirst(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x"}})
	var reqID int64
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		ok, err := e.db.ClosePermissionRequest(reqID, db.PermissionDenied, "Mac", time.Now())
		e.must(err)
		if !ok {
			t.Error("the Mac's close did not land")
		}
		return permDecision(PermissionAllow), nil
	}
	reqID, itemID := e.permission("Bash", "go test ./...", false)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeOwnerFirst)
	if it.Choice != PermissionAllow {
		t.Fatalf("choice = %q, want the twin's choice kept in the journal", it.Choice)
	}
	e.wantPermission(reqID, db.PermissionDenied, "Mac")
}

// The phone answered before the twin took the item: owner first, no model.
func TestTwin_PermissionAnsweredBeforeLeaseIsOwnerFirst(t *testing.T) {
	e := newTwinEnv(t)
	reqID, itemID := e.permission("Bash", "go test ./...", false)
	_, err := e.db.ClosePermissionRequest(reqID, db.PermissionAllowed, "iPhone", time.Now())
	e.must(err)
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeOwnerFirst)
	e.wantPermission(reqID, db.PermissionAllowed, "iPhone")
	if e.decideCalls() != 0 {
		t.Fatal("Decide ran on an answered request")
	}
}

// The hook already timed out (expired): nobody waits for an answer, the
// item goes before a decision and is superseded after one.
func TestTwin_PermissionHookTimedOut(t *testing.T) {
	t.Run("before the lease", func(t *testing.T) {
		e := newTwinEnv(t)
		reqID, itemID := e.permission("Bash", "go test ./...", false)
		_, err := e.db.ClosePermissionRequest(reqID, db.PermissionExpired, "", time.Now())
		e.must(err)
		e.run()
		var n int
		e.must(e.db.QueryRow(`SELECT COUNT(*) FROM watchman_items WHERE id = ?`, itemID).Scan(&n))
		if n != 0 || e.decideCalls() != 0 {
			t.Fatalf("an expired request's item stayed (%d) or was decided (%d)", n, e.decideCalls())
		}
	})
	t.Run("while deciding", func(t *testing.T) {
		e := newTwinEnv(t)
		e.withPermRun(&permRun{branches: []string{"feature/x"}})
		var reqID int64
		e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			_, err := e.db.ClosePermissionRequest(reqID, db.PermissionExpired, "", time.Now())
			e.must(err)
			return permDecision(PermissionAllow), nil
		}
		reqID, itemID := e.permission("Bash", "go test ./...", false)
		e.run()
		it := e.item(itemID)
		wantOutcome(t, it, OutcomeSuperseded)
		if it.Choice != PermissionAllow {
			t.Fatalf("choice = %q, want kept", it.Choice)
		}
		e.wantPermission(reqID, db.PermissionExpired, "")
	})
}

// The daemon died mid-item: the lease runs out, the next pass retakes the
// item and decides it.
func TestTwin_PermissionRetakenAfterRestart(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x"}})
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return permDecision(PermissionAllow), nil
	}
	reqID, itemID := e.permission("Bash", "go test ./...", false)
	old, err := e.db.LeaseWatchmanItem(time.Now().Add(-LeaseFor-time.Minute), LeaseFor, func(db.WatchmanItem) bool { return true })
	e.must(err)
	if old == nil || old.ID != itemID {
		t.Fatal("the crashed worker's lease was not taken")
	}
	if n := e.run(); n != 1 {
		t.Fatalf("RunOnce = %d, want the expired lease retaken", n)
	}
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeAnswered)
	if it.Attempts != 2 {
		t.Fatalf("attempts = %d, want 2", it.Attempts)
	}
	e.wantPermission(reqID, db.PermissionAllowed, askanswer.ByWatchman)
}

func TestTwin_PermissionUnknownPRBaseParks(t *testing.T) {
	e := newTwinEnv(t)
	run := &permRun{branches: []string{"feature/x"}, ghErr: errors.New("gh: not logged in")}
	e.withPermRun(run)
	reqID, itemID := e.permission("Bash", "gh pr merge 12 --squash", false)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeParked)
	if it.ParkReason != limitReason(watchman.LimitMainRef) {
		t.Fatalf("park reason = %q", it.ParkReason)
	}
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
	if e.decideCalls() != 0 {
		t.Fatal("Decide ran on a merge whose base is unknown")
	}
	if !slices.Contains(run.calls, "/tmp/acme: gh pr view 12 --json baseRefName --jq .baseRefName") {
		t.Fatalf("live reads = %q, want gh pr view in the session folder", run.calls)
	}
}

// A merge into a feature branch is the model's; the allow is checked again
// on a fresh read of the base, which parks it when the PR was retargeted
// onto main meanwhile.
func TestTwin_PermissionAllowCheckedAgainAfterTheModel(t *testing.T) {
	t.Run("base unchanged", func(t *testing.T) {
		e := newTwinEnv(t)
		e.withPermRun(&permRun{branches: []string{"feature/x"}, bases: []string{"feature/watchman"}})
		e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			return permDecision(PermissionAllow), nil
		}
		reqID, itemID := e.permission("Bash", "gh pr merge 12 --squash", false)
		e.run()
		wantOutcome(t, e.item(itemID), OutcomeAnswered)
		e.wantPermission(reqID, db.PermissionAllowed, askanswer.ByWatchman)
	})
	t.Run("retargeted onto main", func(t *testing.T) {
		e := newTwinEnv(t)
		e.withPermRun(&permRun{branches: []string{"feature/x"}, bases: []string{"feature/watchman", "main"}})
		e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			return permDecision(PermissionAllow), nil
		}
		reqID, itemID := e.permission("Bash", "gh pr merge 12 --squash", false)
		e.run()
		it := e.item(itemID)
		wantOutcome(t, it, OutcomeParked)
		if it.ParkReason != limitReason(watchman.LimitMainRef) || it.Choice != PermissionAllow {
			t.Fatalf("item = %+v, want parked main_ref with the choice kept", it)
		}
		e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
	})
}

// The owner's limits cannot be read: fail closed.
func TestTwin_PermissionExtraLimitsUnreadableParks(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x"}})
	reqID, itemID := e.permission("Bash", "go test ./...", false)
	_, err := e.db.Exec(`DROP TABLE watchman_extra_limits`)
	e.must(err)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeParked)
	if it.ParkReason != reasonUnreadablePrefix+"the owner's limits" {
		t.Fatalf("park reason = %q", it.ParkReason)
	}
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
	if e.decideCalls() != 0 {
		t.Fatal("Decide ran without the owner's limits")
	}
}

func TestTwin_PermissionUnlearnedWorkbenchParks(t *testing.T) {
	e := newTwinEnv(t)
	_, err := e.db.Exec(`UPDATE watchman_workbenches SET learned_through = NULL WHERE workbench_id = ?`, e.wb)
	e.must(err)
	reqID, itemID := e.permission("Bash", "go test ./...", false)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeParked)
	if it.ParkReason != LearningReason {
		t.Fatalf("park reason = %q", it.ParkReason)
	}
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
}

// The session was deleted with its requests: the item goes.
func TestTwin_PermissionRequestGoneDropsItem(t *testing.T) {
	e := newTwinEnv(t)
	reqID, itemID := e.permission("Bash", "go test ./...", false)
	_, err := e.db.Exec(`DELETE FROM permission_requests WHERE id = ?`, reqID)
	e.must(err)
	e.run()
	var n int
	e.must(e.db.QueryRow(`SELECT COUNT(*) FROM watchman_items WHERE id = ?`, itemID).Scan(&n))
	if n != 0 || e.decideCalls() != 0 {
		t.Fatalf("the item stayed (%d) or was decided (%d)", n, e.decideCalls())
	}
}

// The branches the session shares are read live (Task 10 review): the
// current branch's PR base, and the current branch when an open PR builds
// on it; unknown fails closed.
func TestTwin_PermissionSharedBranchesReadLive(t *testing.T) {
	cases := []struct {
		name, command string
		run           *permRun
		parked        bool
	}{
		{"branch -f onto the umbrella", "git branch -f feature/watchman HEAD~2",
			&permRun{branches: []string{"feature/x"}, headBase: "feature/watchman"}, true},
		{"reset on the private branch", "git reset --hard HEAD~1",
			&permRun{branches: []string{"feature/x"}, headBase: "feature/watchman"}, false},
		{"reset on a branch others build on", "git reset --hard HEAD~1",
			&permRun{branches: []string{"feature/x"}, headBase: "feature/watchman", onTop: 1}, true},
		{"reset with no PR to read", "git reset --hard HEAD~1",
			&permRun{branches: []string{"feature/x"}}, true},
		{"reset of the working tree only, no PR", "git reset --hard",
			&permRun{branches: []string{"feature/x"}}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newTwinEnv(t)
			e.withPermRun(c.run)
			e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
				return permDecision(PermissionAllow), nil
			}
			reqID, itemID := e.permission("Bash", c.command, false)
			e.run()
			it := e.item(itemID)
			if !c.parked {
				wantOutcome(t, it, OutcomeAnswered)
				e.wantPermission(reqID, db.PermissionAllowed, askanswer.ByWatchman)
				return
			}
			wantOutcome(t, it, OutcomeParked)
			if it.ParkReason != limitReason(watchman.LimitResetShared) {
				t.Fatalf("park reason = %q", it.ParkReason)
			}
			e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
			if e.decideCalls() != 0 {
				t.Fatal("Decide ran on a shared-branch move")
			}
		})
	}
}

// The allow is checked on fresh reads: the session's branch moved to main
// while the model ran, so the reset it allowed parks.
func TestTwin_PermissionAllowRereadsBeforeWriting(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x", "main"}, headBase: "feature/watchman"})
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return permDecision(PermissionAllow), nil
	}
	reqID, itemID := e.permission("Bash", "git reset --hard HEAD~1", false)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeParked)
	if it.ParkReason != limitReason(watchman.LimitResetShared) || it.Choice != PermissionAllow {
		t.Fatalf("item = %+v, want parked reset_shared with the choice kept", it)
	}
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
}

// The owner adds a limit while the model runs: the allow re-reads the
// owner's limits and parks.
func TestTwin_PermissionAllowRereadsOwnerLimits(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x"}, headBase: "feature/watchman"})
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		_, err := e.db.AddWatchmanExtraLimit(watchman.ExtraLimitCommand, "go test")
		e.must(err)
		return permDecision(PermissionAllow), nil
	}
	reqID, itemID := e.permission("Bash", "go test ./...", false)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeParked)
	if it.ParkReason != limitReason(watchman.LimitOwner) {
		t.Fatalf("park reason = %q", it.ParkReason)
	}
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
}

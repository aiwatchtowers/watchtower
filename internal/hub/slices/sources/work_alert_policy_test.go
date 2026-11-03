package sources

import (
	"slices"
	"testing"
	"time"
)

// Go twins of the Swift WorkAlertPolicyTests rows the work_alert source tests
// did not pin one to one (go hub plan 3 Task 24 deletes WorkAlertPolicy with
// the Swift hub). The rest map to work_alert_test.go (see the Task 24 PR).

var policyNow = time.Unix(1_800_000_000, 0).UTC()

// twin of WorkAlertPolicyTests.testAStopWithAnOpenAskOrPendingRequestIsCovered:
// the stop an ask or a request stands for is covered, so it never pushes a
// second time once that one resolves; a plain stop and an undated session are not.
func TestWorkAlertAStopWithAnOpenAskOrPendingRequestIsCovered(t *testing.T) {
	held := policyNow.Add(-time.Minute)
	key := stopKey(7, held)
	if got := coveredStopKeys([]alertSession{{id: 7, kind: kindReadyToCheck, stateAt: held, openAsks: 1}}); !slices.Equal(got, []string{key}) {
		t.Errorf("open ask: %v", got)
	}
	if got := coveredStopKeys([]alertSession{{id: 7, kind: kindNeedsApproval, stateAt: held, pendingRequest: true}}); !slices.Equal(got, []string{key}) {
		t.Errorf("pending request: %v", got)
	}
	if got := coveredStopKeys([]alertSession{{id: 7, kind: kindStopped, stateAt: held}, {id: 8, kind: kindFinished, openAsks: 1}}); len(got) != 0 {
		t.Errorf("a plain stop or an undated one: %v", got)
	}
}

// twin of WorkAlertPolicyTests.testAnUndatedStopNeverPushes
func TestWorkAlertAnUndatedStopNeverPushes(t *testing.T) {
	if got := alertCandidates(nil, nil, []alertSession{{id: 7, kind: kindFinished}}, policyNow); len(got) != 0 {
		t.Errorf("candidates %v", got)
	}
}

// twin of WorkAlertPolicyTests.testNoOtherKindYieldsASessionCandidate
func TestWorkAlertNoOtherKindYieldsASessionCandidate(t *testing.T) {
	var quiet []alertSession
	for i, k := range []sessionKind{kindNotStarted, kindRunning, kindWorking, kindNeedsApproval, kindWaitingOnAsk, kindBackground, kindReadyToCheck} {
		quiet = append(quiet, alertSession{id: int64(i), kind: k, stateAt: policyNow.Add(-time.Hour)})
	}
	if got := alertCandidates(nil, nil, quiet, policyNow); len(got) != 0 {
		t.Errorf("candidates %v", got)
	}
}

// twin of WorkAlertPolicyTests.testTheStopKeyIsExactMilliseconds: the Kit's
// WorkAlertKey.stop, whole milliseconds rounded to the nearest.
func TestWorkAlertTheStopKeyIsExactMilliseconds(t *testing.T) {
	at := time.Unix(1_089_010_964, 738_000_000)
	if got := stopKey(7, at); got != "stop-7-1089010964738" {
		t.Errorf("stopKey = %q", got)
	}
	if got := stopKey(7, at.Add(-time.Nanosecond)); got != "stop-7-1089010964738" {
		t.Errorf("a hair under the millisecond keys %q", got)
	}
}

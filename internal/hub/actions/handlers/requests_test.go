package handlers

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
)

// fakeWindows is a scripted SessionWindows.
type fakeWindows struct {
	published, report map[int64]bool
	err               error
}

func (w *fakeWindows) Published(_ context.Context, id int64) (bool, error) {
	return w.published[id], w.err
}

func (w *fakeWindows) InReportWindow(_ context.Context, id int64) (bool, error) {
	return w.report[id], w.err
}

// fakeReports records every report request.
type fakeReports struct {
	mu  sync.Mutex
	ids []int64
}

func (r *fakeReports) RequestReport(id int64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ids = append(r.ids, id)
	return true
}

type reqEnv struct {
	*env
	windows *fakeWindows
	watches *ChatWatchRegistry
	reports *fakeReports
	now     time.Time
}

func newReqEnv(t *testing.T) *reqEnv {
	t.Helper()
	e := newEnv(t)
	r := &reqEnv{
		env:     e,
		windows: &fakeWindows{published: map[int64]bool{}, report: map[int64]bool{}},
		watches: NewChatWatchRegistry(),
		reports: &fakeReports{},
		now:     time.Now().UTC(),
	}
	// The handlers under test read these Deps directly.
	e.h.d.Windows, e.h.d.ChatWatches, e.h.d.Reports = r.windows, r.watches, r.reports
	e.h.d.Clock = func() time.Time { return r.now }
	return r
}

func (r *reqEnv) chat(sid int64, params map[string]any, age time.Duration) actions.Outcome {
	a := r.request("session_chat_request", id(sid), params)
	a.Action.CreatedAt = wire.Time{Time: r.now.Add(-age)}
	return r.h.sessionChatRequest(context.Background(), a)
}

func (r *reqEnv) report(sid int64) actions.Outcome {
	a := r.request("session_report_request", id(sid), nil)
	a.Action.CreatedAt = wire.Time{Time: r.now}
	return r.h.sessionReportRequest(context.Background(), a)
}

// --- session_chat_request ---

func TestChatRequestForAnUnknownSessionFails(t *testing.T) {
	r := newReqEnv(t)

	got := r.chat(7, nil, time.Second)
	wantOutcome(t, got, wire.StatusFailed, reasonNotFound)
	wantMessage(t, got, "unknown_session")
	if n := len(r.watches.Active(r.now)); n != 0 {
		t.Fatalf("watches = %d", n)
	}
}

func TestChatRequestWithoutWindowsIsUnknown(t *testing.T) {
	r := newReqEnv(t)
	r.h.d.Windows = nil
	r.windows.published[7] = true

	wantOutcome(t, r.chat(7, nil, time.Second), wire.StatusFailed, reasonNotFound)
}

func TestChatRequestOpensAFiveMinuteWatch(t *testing.T) {
	r := newReqEnv(t)
	r.windows.published[7] = true

	got := r.chat(7, map[string]any{"session_id": 7}, 0)
	wantOutcome(t, got, wire.StatusApplied, "")
	if len(got.Result) != 0 {
		t.Fatalf("result = %v, want {}", got.Result)
	}
	w := r.watches.Active(r.now)
	if len(w) != 1 || w[0].SessionID != 7 || w[0].AgentID != "" || !w[0].Expires.Equal(r.now.Add(ChatWatchLength)) {
		t.Fatalf("watches = %+v", w)
	}
	// A subagent's chat is its own watch.
	wantOutcome(t, r.chat(7, map[string]any{"subagent_id": "a1", "tool_use_id": "tu1"}, 0), wire.StatusApplied, "")
	if n := len(r.watches.Active(r.now)); n != 2 {
		t.Fatalf("watches = %d, want 2", n)
	}
}

func TestChatRequestSubagentIdsComeTogetherAndSessionIdMustMatch(t *testing.T) {
	r := newReqEnv(t)
	r.windows.published[7] = true

	for name, params := range map[string]map[string]any{
		"agent alone":        {"subagent_id": "a1"},
		"tool use alone":     {"tool_use_id": "tu1"},
		"empty agent":        {"subagent_id": "", "tool_use_id": "tu1"},
		"number agent":       {"subagent_id": 3, "tool_use_id": "tu1"},
		"other session":      {"session_id": 8},
		"session id as text": {"session_id": "7"},
	} {
		if got := r.chat(7, params, 0); got.Reason != reasonInvalidParams {
			t.Errorf("%s: outcome = %+v, want invalid_params", name, got)
		}
	}
	wantOutcome(t, r.chat(7, map[string]any{"session_id": nil, "subagent_id": nil, "tool_use_id": nil}, 0), wire.StatusApplied, "")
	if n := len(r.watches.Active(r.now)); n != 1 {
		t.Fatalf("watches = %d, want only the valid request's", n)
	}
}

func TestChatRequestStaleOpensNoWatchAndAgedOneExpiresSooner(t *testing.T) {
	r := newReqEnv(t)
	r.windows.published[7] = true

	wantOutcome(t, r.chat(7, nil, 10*time.Minute), wire.StatusApplied, "")
	if n := len(r.watches.Active(r.now)); n != 0 {
		t.Fatalf("a 10-minute-old request opened %d watches", n)
	}
	wantOutcome(t, r.chat(7, nil, 2*time.Minute), wire.StatusApplied, "")
	w := r.watches.Active(r.now)
	if len(w) != 1 || !w[0].Expires.Equal(r.now.Add(3*time.Minute)) {
		t.Fatalf("watches = %+v, want one ending 3 minutes from now", w)
	}
	// A phone clock ahead of the Mac still gets a full watch, no more.
	wantOutcome(t, r.chat(7, nil, -time.Minute), wire.StatusApplied, "")
	if w := r.watches.Active(r.now); !w[0].Expires.Equal(r.now.Add(ChatWatchLength)) {
		t.Fatalf("expires = %v, want a full watch", w[0].Expires)
	}
	// A repeat never shortens the watch a newer request holds.
	wantOutcome(t, r.chat(7, nil, 4*time.Minute), wire.StatusApplied, "")
	if w := r.watches.Active(r.now); !w[0].Expires.Equal(r.now.Add(ChatWatchLength)) {
		t.Fatalf("expires = %v, shortened", w[0].Expires)
	}
}

func TestChatWatchRegistryDropsExpiredAndAll(t *testing.T) {
	reg := NewChatWatchRegistry()
	now := time.Now()
	reg.Watch(ChatWatch{SessionID: 1, Expires: now.Add(time.Minute)})
	reg.Watch(ChatWatch{SessionID: 2, Expires: now.Add(time.Second)})

	if w := reg.Active(now.Add(2 * time.Second)); len(w) != 1 || w[0].SessionID != 1 {
		t.Fatalf("active = %+v", w)
	}
	if w := reg.Active(now); len(w) != 1 {
		t.Fatalf("an expired watch came back: %+v", w)
	}
	reg.DropAll()
	if w := reg.Active(now); len(w) != 0 {
		t.Fatalf("after DropAll = %+v", w)
	}
}

func TestChatRequestReadFailureIsWriteFailed(t *testing.T) {
	r := newReqEnv(t)
	r.windows.err = errors.New("db locked")

	wantOutcome(t, r.chat(7, nil, 0), wire.StatusFailed, reasonWriteFailed)
}

// --- session_report_request ---

func TestReportRequestInTheWindowAsksTheRunner(t *testing.T) {
	r := newReqEnv(t)
	r.windows.report[7] = true

	got := r.report(7)
	wantOutcome(t, got, wire.StatusApplied, "")
	if len(got.Result) != 0 {
		t.Fatalf("result = %v", got.Result)
	}
	// Idempotent: a re-run only asks again (the runner keeps its spacing).
	wantOutcome(t, r.report(7), wire.StatusApplied, "")
	if len(r.reports.ids) != 2 || r.reports.ids[0] != 7 {
		t.Fatalf("requests = %v", r.reports.ids)
	}
}

func TestReportRequestOutsideTheWindowIsNotFound(t *testing.T) {
	r := newReqEnv(t)
	r.windows.published[7] = true // published, but not live nor active in 7 days

	got := r.report(7)
	wantOutcome(t, got, wire.StatusFailed, reasonNotFound)
	wantMessage(t, got, "This session has no report on the Mac")
	if len(r.reports.ids) != 0 {
		t.Fatalf("requests = %v", r.reports.ids)
	}
	bad := r.request("session_report_request", nil, nil)
	wantOutcome(t, r.h.sessionReportRequest(context.Background(), bad), wire.StatusFailed, reasonInvalidParams)
}

func TestRequestKindsAreRegisteredWithNudges(t *testing.T) {
	for _, k := range []string{"session_report_request", "session_chat_request"} {
		if len(NudgeTable[k]) == 0 {
			t.Fatalf("%s has no NudgeTable entry", k)
		}
	}
}

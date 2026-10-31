package sources

import (
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/policy"
)

func registryKinds(t *testing.T, mode string) []string {
	t.Helper()
	set, err := All(Config{
		DB: openDB(t), Store: openSidecar(t), Watches: handlers.NewChatWatchRegistry(), Sealer: newSealer(t),
		Mode: mode, AssetDir: filepath.Join(t.TempDir(), "assets"),
	})
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, s := range set.Sources {
		kinds = append(kinds, string(s.Kind()))
	}
	sort.Strings(kinds)
	return kinds
}

var workbenchOnlyKinds = []string{"ask_alert", "owner_ask", "permission_request", "session_chat", "session_report", "session_timeline",
	"terminal_session", "workbench", "workbench_comment", "workbench_target"}

func TestWorkbenchOnlyPublishesNoCalendarOrTranscripts(t *testing.T) {
	got := registryKinds(t, policy.MobileWorkbenchOnly)
	if strings.Join(got, ",") != strings.Join(workbenchOnlyKinds, ",") {
		t.Errorf("workbench_only kinds = %v", got)
	}
	for _, k := range got {
		if k == "calendar_event" || k == "meeting_transcript" || k == "recording_job" {
			t.Errorf("%s published in workbench_only", k)
		}
	}
}

func TestAllowedAddsCalendarTranscriptsAndRecordingJobs(t *testing.T) {
	got := registryKinds(t, policy.MobileAllowed)
	want := append(append([]string(nil), workbenchOnlyKinds...), "calendar_event", "meeting_transcript", "recording_job")
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("allowed kinds = %v", got)
	}
}

// The twin of testOffToWorkbenchOnlyStartsTheHubRestricted: a hub that was
// off and is switched to workbench_only starts with the restricted set, and
// off and unknown modes build nothing.
func TestPolicyOffToWorkbenchOnlyStartsRestricted(t *testing.T) {
	if got := registryKinds(t, policy.MobileOff); len(got) != 0 {
		t.Errorf("off kinds = %v", got)
	}
	if got := registryKinds(t, "bogus"); len(got) != 0 {
		t.Errorf("an unknown mode must fail closed: %v", got)
	}
	if got := registryKinds(t, policy.MobileWorkbenchOnly); strings.Join(got, ",") != strings.Join(workbenchOnlyKinds, ",") {
		t.Errorf("restricted start = %v", got)
	}
}

func TestAllRunnersAreTheThreeLoops(t *testing.T) {
	set, err := All(Config{
		DB: openDB(t), Store: openSidecar(t), Watches: handlers.NewChatWatchRegistry(), Sealer: newSealer(t), Mode: policy.MobileWorkbenchOnly,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Runners) != 3 || set.Report == nil || set.Git == nil || set.Chat == nil || set.Timeline == nil {
		t.Errorf("runners %d", len(set.Runners))
	}
}

func TestAllNeedsItsInputs(t *testing.T) {
	if _, err := All(Config{Mode: policy.MobileAllowed}); err == nil {
		t.Error("no database must be refused")
	}
	if _, err := All(Config{DB: openDB(t), Store: openSidecar(t), Sealer: newSealer(t), Watches: handlers.NewChatWatchRegistry(), Mode: policy.MobileAllowed}); err == nil {
		t.Error("allowed without an asset directory must be refused")
	}
}

package handlers

import (
	"context"
	"os"
	"testing"

	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
)

// A recordings dir the Mac cannot write is the Mac's failure: write_failed
// (the phone keeps its file and offers Retry), never the phone's missing
// audio, and no half-written file or job is left.
// twin of RelayProcessorRecordingUploadTests.testUnwritableRecordingsDirFailsWriteFailedAndLeavesNoPartialFile
func TestUnwritableRecordingsDirFailsWriteFailedAndLeavesNoPartialFile(t *testing.T) {
	e := newRecEnv(t)
	e.beat(e.now)
	if err := os.MkdirAll(e.dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(e.dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(e.dir, 0o700) })
	downloaded := false
	in := e.upload("u-1", []byte("audio"))
	dl := in.Download
	in.Download = func(ctx context.Context, dst string) error {
		downloaded = true
		return dl(ctx, dst)
	}

	out := e.h.IntakeRecording(context.Background(), in)
	if out.Status != wire.StatusFailed || out.Reason != reasonWriteFailed || out.Message == "" {
		t.Fatalf("outcome %+v, want failed write_failed", out)
	}
	if downloaded {
		t.Fatal("the asset was downloaded into a dir the Mac cannot write")
	}
	if names := e.files(); len(names) != 0 {
		t.Fatalf("files left: %v", names)
	}
	if done, err := e.store.HasRecording("u-1"); err != nil || done {
		t.Fatalf("a job was queued: %v, %v", done, err)
	}
}

// Under the organization's MobileSync = workbench_only a phone recording is
// refused (it is no workbench data) with the policy text, and nothing is
// written; allowed takes it as before.
// twin of SlicePublisherPolicyTests.testRecordingCommandRefusedUnderWorkbenchOnly
func TestRecordingRefusedUnderWorkbenchOnly(t *testing.T) {
	e := newRecEnv(t)
	e.beat(e.now)
	mode := policy.MobileWorkbenchOnly
	e.h.d.Policy = func() string { return mode }

	out := e.h.IntakeRecording(context.Background(), e.upload("u-1", []byte("audio")))
	if out.Status != wire.StatusFailed || out.Reason != reasonWriteFailed || out.Message != PolicyBlockedMessage {
		t.Fatalf("outcome %+v, want the policy refusal", out)
	}
	if names := e.files(); len(names) != 0 {
		t.Fatalf("files left: %v", names)
	}

	mode = policy.MobileAllowed
	if out := e.h.IntakeRecording(context.Background(), e.upload("u-2", []byte("audio"))); out.Status != wire.StatusReceived {
		t.Fatalf("allowed: %+v", out)
	}
}

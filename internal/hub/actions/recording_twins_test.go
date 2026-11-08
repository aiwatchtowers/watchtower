package actions

import (
	"encoding/json"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Go twins of the Swift RelayProcessorRecordingUploadTests that had none (Go
// hub phase 3, Task 24, spec §13 "Ported guards"). The intake is scripted
// (uploadWorld); the intake's own file handling is in handlers.

// missingAudio is the intake's answer to an upload whose asset did not arrive.
var missingAudio = RecordingOutcome{Status: wire.StatusFailed, Reason: "not_found", Message: "no audio"}

// stored is the record the mailbox holds at name.
func (w *uploadWorld) stored(name string) transport.Stored {
	w.t.Helper()
	b, err := w.fake.Changes(w.ctx, w.phone.Zone(), 0)
	if err != nil {
		w.t.Fatal(err)
	}
	for _, r := range b.Changed {
		if r.Name == name {
			return r
		}
	}
	w.t.Fatalf("no record %s in the mailbox", name)
	return transport.Stored{}
}

// pendingUpload writes upload id from the phone, pending, and returns its
// wire name.
func (w *uploadWorld) pendingUpload(id string) string {
	w.t.Helper()
	body, _ := json.Marshal(map[string]any{"id": id, "status": "pending", "duration_sec": 5, "device_id": w.phone.ID().String()})
	name, err := w.phone.WriteUpload(id, body, nil, nil)
	if err != nil {
		w.t.Fatal(err)
	}
	return name
}

// resend is the phone's Retry: a fresh save of upload id over the hub's echo
// at its name.
func (w *uploadWorld) resend(id, name string) {
	w.t.Helper()
	if _, err := w.fake.Delete(w.ctx, w.phone.Zone(), []transport.DeleteItem{{Name: name}}); err != nil {
		w.t.Fatal(err)
	}
	w.pendingUpload(id)
}

// wantLedger checks upload id's ledger outcome.
func (w *uploadWorld) wantLedger(id, want string) {
	w.t.Helper()
	if _, outcome, _, err := w.st.Phase("recupload-" + id); err != nil || outcome != want {
		w.t.Fatalf("ledger of %s = %q, %v; want %q", id, outcome, err, want)
	}
}

// A Retry after a failed answer re-sends the identical envelope (its asset
// missing the first time): a failed attempt wrote nothing, so this one is
// ingested and answered received.
// twin of RelayProcessorRecordingUploadTests.testARetryOfTheSameEnvelopeAfterAFailedIngestIsIngested
func TestARetryOfTheSameEnvelopeAfterAFailedIngestIsIngested(t *testing.T) {
	w := newUploadWorld(t)
	name := w.pendingUpload("u1")
	original := w.stored(name)
	w.next = missingAudio
	w.pass()
	if e := w.echo("u1"); e["status"] != "failed" {
		t.Fatalf("first echo %v", e)
	}
	w.wantLedger("u1", "failed:not_found")

	if _, err := w.fake.Write(w.phone.Zone(), name, original.Envelope, transport.Expect{Mode: transport.ExpectNone}); err != nil {
		t.Fatal(err)
	}
	w.next = RecordingOutcome{Status: wire.StatusReceived}
	w.pass()
	if e := w.echo("u1"); e["status"] != "received" {
		t.Fatalf("echo after the retry %v", e)
	}
	if len(w.calls) != 2 {
		t.Fatalf("%d intake calls, want 2", len(w.calls))
	}
	w.wantLedger("u1", "received")
}

// A failed upload is ingested when the phone sends it again (a new save of
// the same upload id).
// twin of RelayProcessorRecordingUploadTests.testAFailedUploadIsIngestedWhenThePhoneSendsItAgain
func TestAFailedUploadIsIngestedWhenThePhoneSendsItAgain(t *testing.T) {
	w := newUploadWorld(t)
	name := w.pendingUpload("u1")
	w.next = missingAudio
	w.pass()
	if e := w.echo("u1"); e["status"] != "failed" {
		t.Fatalf("first echo %v", e)
	}

	w.resend("u1", name)
	w.next = RecordingOutcome{Status: wire.StatusReceived}
	w.pass()
	if e := w.echo("u1"); e["status"] != "received" {
		t.Fatalf("echo after the retry %v", e)
	}
	if len(w.calls) != 2 {
		t.Fatalf("%d intake calls, want 2", len(w.calls))
	}
	w.wantLedger("u1", "received")
}

// An upload whose payload names another record than its envelope is
// dropped: no intake, no echo, no ledger row under either id.
// twin of RelayProcessorRecordingUploadTests.testAnUploadWhosePayloadNamesAnotherRecordIsIgnored
func TestAnUploadWhosePayloadNamesAnotherRecordIsIgnored(t *testing.T) {
	w := newUploadWorld(t)
	w.next = RecordingOutcome{Status: wire.StatusReceived}
	body, _ := json.Marshal(map[string]any{"id": "R2", "status": "pending", "duration_sec": 5, "device_id": w.phone.ID().String()})
	if _, err := w.phone.WriteFrame(kindRecordingUpload, "recupload-R1", body); err != nil {
		t.Fatal(err)
	}
	if r := w.pass(); r.Applied+r.Echoed != 0 {
		t.Fatalf("pass %+v", r)
	}
	w.sync(w.phone)
	if len(w.calls) != 0 || len(w.phone.UploadEchoes) != 0 {
		t.Fatalf("intake %d, echoes %v", len(w.calls), w.phone.UploadEchoes)
	}
	w.wantLedger("R1", "")
	w.wantLedger("R2", "")
}

// An upload whose payload does not decode, or carries no id, is skipped:
// nothing ingested, nothing answered.
// twin of RelayProcessorRecordingUploadTests.testAnUndecodableUploadIsSkipped
func TestAnUndecodableUploadIsSkipped(t *testing.T) {
	w := newUploadWorld(t)
	w.next = RecordingOutcome{Status: wire.StatusReceived}
	for id, body := range map[string]string{"recupload-bad": "{}", "recupload-junk": "not json"} {
		if _, err := w.phone.WriteFrame(kindRecordingUpload, id, []byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if r := w.pass(); r.Applied+r.Echoed != 0 {
		t.Fatalf("pass %+v", r)
	}
	w.sync(w.phone)
	if len(w.calls) != 0 || len(w.phone.UploadEchoes) != 0 {
		t.Fatalf("intake %d, echoes %v", len(w.calls), w.phone.UploadEchoes)
	}
}

// A re-read of the mailbox from the start (a reset token) meets the hub's
// own echoes of a failed and a received upload: no echo again, nothing
// ingested. Only the phone's later save of the failed one is ingested.
// twin of RelayProcessorRecordingUploadTests.testAReReadOfTheHubsOwnStaleCopiesEchoesAndIngestsNothing
func TestAReReadOfTheHubsOwnStaleCopiesEchoesAndIngestsNothing(t *testing.T) {
	w := newUploadWorld(t)
	failedName := w.pendingUpload("u1")
	w.next = missingAudio
	w.pass()
	w.pendingUpload("u2")
	w.next = RecordingOutcome{Status: wire.StatusReceived}
	w.pass()
	w.sync(w.phone)
	if len(w.calls) != 2 {
		t.Fatalf("%d intake calls before the reset", len(w.calls))
	}

	if err := w.st.SetZoneToken(w.phone.Zone(), 0); err != nil {
		t.Fatal(err)
	}
	if r := w.pass(); r.Applied+r.Echoed+r.ControlsWritten != 0 {
		t.Fatalf("the re-read answered the hub's own copies: %+v", r)
	}
	if len(w.calls) != 2 {
		t.Fatalf("the re-read ingested: %d intake calls", len(w.calls))
	}

	w.resend("u1", failedName)
	w.pass()
	if len(w.calls) != 3 {
		t.Fatalf("the phone's Retry was not ingested: %d intake calls", len(w.calls))
	}
	w.wantLedger("u1", "received")
}

// A recording sealed before a rotation and resealed after it (same wire name,
// new envelope in the new epoch) is received once: whether the resealed copy
// replaces the original the hub has not read, or comes again after the echo,
// the ledger keeps one intake call.
// twin of RecordingUploaderTests.testARowSealedInAnOlderEpochIsResealedBeforeSending
func TestResealedUploadReceivedOnce(t *testing.T) {
	w := newUploadWorld(t)
	w.next = RecordingOutcome{Status: wire.StatusReceived}
	name := w.pendingUpload("u1") // sealed in epoch 1
	old := w.stored(name)
	w.retire()
	// The phone reseals before the hub reads: the record at its name is replaced by one of the new epoch.
	w.resend("u1", name)
	if resealed := w.stored(name); string(resealed.Envelope) == string(old.Envelope) {
		t.Fatal("the resealed copy is the old envelope")
	}
	w.pass()
	if e := w.echo("u1"); e["status"] != "received" {
		t.Fatalf("echo %v", e)
	}
	w.wantLedger("u1", "received")

	// A second resealed copy after the echo (a Retry, a late reseal) adds no intake call.
	w.resend("u1", name)
	w.pass()
	if len(w.calls) != 1 {
		t.Fatalf("%d intake calls, want 1", len(w.calls))
	}
	w.wantLedger("u1", "received")
}

package actions

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"reflect"
	"testing"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// uploadWorld installs a scripted intake and returns a sender for uploads.
type uploadWorld struct {
	*world
	next  RecordingOutcome
	calls []RecordingIntake
}

func newUploadWorld(t *testing.T) *uploadWorld {
	w := &uploadWorld{world: newWorld(t, "relay")}
	w.disp.SetRecordings(func(_ context.Context, in RecordingIntake) RecordingOutcome {
		w.calls = append(w.calls, in)
		return w.next
	}, []string{"recording_job"})
	return w
}

func (w *uploadWorld) upload(id string, device *secure.ID) {
	w.t.Helper()
	m := map[string]any{"id": id, "status": "pending", "duration_sec": 5}
	if device != nil {
		m["device_id"] = device.String()
	}
	body, _ := json.Marshal(m)
	if _, err := w.phone.WriteUpload(id, body, nil, nil); err != nil {
		w.t.Fatal(err)
	}
}

func (w *uploadWorld) echo(id string) map[string]any {
	w.t.Helper()
	w.sync(w.phone)
	e, ok := w.phone.UploadEchoes[id]
	if !ok {
		w.t.Fatalf("no echo of upload %s", id)
	}
	return e
}

func TestRecordingUploadFromALinkedPhoneIsEchoed(t *testing.T) {
	w := newUploadWorld(t)
	var nudged []string
	w.proc.cfg.Nudge = func(k []string) { nudged = append(nudged, k...) }
	w.next = RecordingOutcome{Status: wire.StatusReceived}
	id := w.phone.ID()
	w.upload("u1", &id)
	w.pass()
	e := w.echo("u1")
	if e["status"] != "received" || e["error_message"] != nil {
		t.Fatalf("echo %v", e)
	}
	if len(w.calls) != 1 || w.calls[0].UploadID != "u1" || w.calls[0].Device != id {
		t.Fatalf("intake calls %+v", w.calls)
	}
	if len(nudged) != 1 || nudged[0] != "recording_job" {
		t.Fatalf("nudges %v", nudged)
	}
	// a later pass never ingests it again
	w.pass()
	if len(w.calls) != 1 {
		t.Fatalf("a received upload was ingested again: %d calls", len(w.calls))
	}
}

func TestRecordingUploadWithoutAMatchingDeviceFailsDeviceNotLinked(t *testing.T) {
	for name, device := range map[string]*secure.ID{"none": nil, "another": {0x77}} {
		t.Run(name, func(t *testing.T) {
			w := newUploadWorld(t)
			w.upload("u1", device)
			w.pass()
			e := w.echo("u1")
			if e["status"] != "failed" || e["error_message"] != notLinkedMessage {
				t.Fatalf("echo %v", e)
			}
			if len(w.calls) != 0 {
				t.Fatal("the intake ran for an unlinked device")
			}
		})
	}
}

func TestRecordingUploadHeldIsRetriedEachPass(t *testing.T) {
	w := newUploadWorld(t)
	w.next = RecordingOutcome{Status: wire.StatusHeld, Message: "waiting"}
	id := w.phone.ID()
	w.upload("u1", &id)
	w.pass()
	if e := w.echo("u1"); e["status"] != "held" {
		t.Fatalf("echo %v", e)
	}
	w.pass() // still held: tried again, no new echo
	if len(w.calls) != 2 {
		t.Fatalf("retries: %d calls", len(w.calls))
	}
	w.next = RecordingOutcome{Status: wire.StatusReceived}
	w.pass()
	w.sync(w.phone)
	if e := w.phone.UploadEchoes["u1"]; e["status"] != "received" {
		t.Fatalf("final echo %v", e)
	}
	w.pass()
	if len(w.calls) != 3 {
		t.Fatalf("a received upload is retried: %d calls", len(w.calls))
	}
}

func TestRecordingUploadNotSupportedIsFinal(t *testing.T) {
	w := newUploadWorld(t)
	w.next = RecordingOutcome{Status: wire.StatusFailed, Reason: "not_supported", Message: "no transcriber"}
	id := w.phone.ID()
	w.upload("u1", &id)
	w.pass()
	if e := w.echo("u1"); e["status"] != "failed" || e["error_message"] != "no transcriber" {
		t.Fatalf("echo %v", e)
	}
}

// TestUploadEchoMatchesTheContractFixture: the hub's failed echoes are the
// shared fixture's upload_echo cases (the phone's own keys kept, status,
// error_message and reason rewritten), the device id aside.
func TestUploadEchoMatchesTheContractFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		UploadEcho []struct {
			Name   string         `json:"name"`
			Expect map[string]any `json:"expect"`
		} `json:"upload_echo"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	cases := map[string]RecordingOutcome{
		"failed_not_supported": {Status: wire.StatusFailed, Reason: ReasonNotSupported},
		"received":             {Status: wire.StatusReceived},
	}
	for _, c := range f.UploadEcho {
		out, ok := cases[c.Name]
		if !ok {
			continue
		}
		t.Run(c.Name, func(t *testing.T) {
			w := newUploadWorld(t)
			id := w.phone.ID()
			want := maps.Clone(c.Expect)
			want["device_id"] = id.String()
			sent := maps.Clone(want)
			sent["status"] = wire.StatusPending
			delete(sent, "error_message")
			sent["reason"] = "stale" // a stray key: the hub's answer replaces or drops it
			if msg, ok := want["error_message"].(string); ok {
				out.Message = msg
			}
			w.next = out
			body, _ := json.Marshal(sent)
			upload, _ := sent["id"].(string)
			if _, err := w.phone.WriteUpload(upload, body, nil, nil); err != nil {
				t.Fatal(err)
			}
			w.pass()
			if got := w.echo(upload); !reflect.DeepEqual(got, want) {
				t.Fatalf("echo\n got  %v\n want %v", got, want)
			}
		})
	}
}

// TestRecoveredHeldUploadsKeepToTheBatchLimit: after a restart the due held
// uploads are settled within the pass's budget; the rest stay held rows and
// the next passes settle them.
func TestRecoveredHeldUploadsKeepToTheBatchLimit(t *testing.T) {
	w := newUploadWorld(t)
	w.next = RecordingOutcome{Status: wire.StatusHeld, Message: "waiting"}
	id := w.phone.ID()
	ids := []string{"u1", "u2", "u3"}
	for _, u := range ids {
		w.upload(u, &id)
	}
	w.pass()
	w.proc = NewProcessor(w.proc.cfg) // a restart: nothing held in memory
	w.proc.batch = 1
	w.mu.Lock()
	w.now = w.now.Add(state.HeldUploadMaxAge)
	w.mu.Unlock()
	expired := func() int {
		w.sync(w.phone)
		n := 0
		for _, u := range ids {
			if w.phone.UploadEchoes[u]["status"] == wire.StatusFailed {
				n++
			}
		}
		return n
	}
	for want := 1; want <= len(ids); want++ {
		r := w.pass()
		if got := expired(); got != want {
			t.Fatalf("pass %d: %d uploads expired, want %d", want, got, want)
		}
		if left := len(ids) - want; left > 0 && r.Remaining < left {
			t.Fatalf("pass %d: Remaining %d, want at least %d", want, r.Remaining, left)
		}
		if held, err := w.st.HeldUploads(); err != nil || len(held) != len(ids)-want {
			t.Fatalf("pass %d: held rows %d %v", want, len(held), err)
		}
	}
}

func TestRecordingUploadWithoutAnIntakeStaysPending(t *testing.T) {
	w := newWorld(t, "relay")
	id := w.phone.ID()
	body, _ := json.Marshal(map[string]any{"id": "u1", "status": "pending", "device_id": id.String()})
	if _, err := w.phone.WriteUpload("u1", body, nil, nil); err != nil {
		t.Fatal(err)
	}
	w.pass()
	w.sync(w.phone)
	if _, ok := w.phone.UploadEchoes["u1"]; ok {
		t.Fatal("an echo without an intake")
	}
}

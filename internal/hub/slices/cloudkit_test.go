package slices

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/cloudkit/bridgefake"
	pb "watchtower/internal/hub/transport/cloudkit/bridgepb"
	"watchtower/internal/logcanary"
)

// TestAKindIsSavedAtMostOncePerSpacingOnCloudKit is the battery rule (#724)
// on CloudKit through Run: however fast a kind changes and is nudged, two
// of its saves are never closer than CloudKitSpacing, and it is still
// saved on that spacing (the dirty kind is never dropped).
func TestAKindIsSavedAtMostOncePerSpacingOnCloudKit(t *testing.T) {
	r := newRig(t, transport.KindCloudKit)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":0}`))
	ru := r.runFake(src)
	frames := len(r.tr.Frames())
	saves := []time.Time{ru.ft.Now()}
	for i := 1; i <= 100; i++ { // a change and a nudge every 100 ms for 10 s
		src.set(Item{ID: "1", Payload: fmt.Appendf(nil, `{"v":%d}`, i)})
		ru.publishSoon("target")
		ru.step(100 * time.Millisecond)
		if n := len(r.tr.Frames()); n > frames {
			frames = n
			saves = append(saves, ru.ft.Now())
		}
	}
	for range 30 { // the last change goes out
		ru.step(100 * time.Millisecond)
		if n := len(r.tr.Frames()); n > frames {
			frames = n
			saves = append(saves, ru.ft.Now())
		}
	}
	t.Logf("%d saves over %v", len(saves), saves[len(saves)-1].Sub(saves[0]))
	if len(saves) < 5 {
		t.Fatalf("%d saves in 10 s of changes, want one every %v", len(saves), CloudKitSpacing)
	}
	for i := 1; i < len(saves); i++ {
		if gap := saves[i].Sub(saves[i-1]); gap < CloudKitSpacing {
			t.Fatalf("saves %d and %d are %v apart, less than %v", i-1, i, gap, CloudKitSpacing)
		}
	}
}

// TestSignalRecordCarriesOnlyTheWireName: over the real CloudKit client, the
// frame that saves an ask alert's signal record names the signal by the
// alert's wire name and carries nothing else — no envelope bytes, no asset,
// and none of the ask's text in any frame the bridge receives.
func TestSignalRecordCarriesOnlyTheWireName(t *testing.T) {
	const relayID = "acmehub"
	r := newRig(t, transport.KindCloudKit)
	dir := bridgefake.Dir(t)
	if err := os.MkdirAll(filepath.Join(dir, cloudkit.AssetsDirName), 0o700); err != nil {
		t.Fatal(err)
	}
	bridge := bridgefake.Serve(t, dir)
	gen, _ := json.Marshal(map[string]string{"generation": bridge.Generation()})
	if err := os.WriteFile(filepath.Join(dir, cloudkit.GenerationFile), gen, 0o600); err != nil {
		t.Fatal(err)
	}
	client := cloudkit.New(cloudkit.Config{Dir: dir, HubID: r.kr.HubID().String(), RelayID: relayID})
	t.Cleanup(func() { _ = client.Close() })

	marker := logcanary.Text("ask_alert.title")
	payload, _ := json.Marshal(map[string]string{"title": marker})
	src := &fakeSource{kind: KindAskAlert}
	src.set(Item{ID: "ask-7", Payload: payload})
	p := NewPublisher(Config{
		Store: r.st, Transport: client, Sealer: secure.NewSealer(r.kr), DataZone: transport.DataZone(relayID),
		Sources: []Source{src}, Clock: r.clock, Linked: func() (bool, error) { return true, nil },
	})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if rep, err := p.Cycle(ctx, []Kind{KindAskAlert}); err != nil || rep.Saved != 1 {
		t.Fatalf("Cycle = %+v, %v", rep, err)
	}

	var alert, signal *pb.SaveItem
	frames := bridge.Frames()
	for i, f := range frames {
		if bytes.Contains(f, []byte(marker)) {
			t.Fatalf("frame %d carries the ask's text", i)
		}
		var req pb.Request
		if err := proto.Unmarshal(f, &req); err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		for _, it := range req.GetSave().GetItems() {
			if strings.HasPrefix(it.GetName(), secure.SignalPrefix) {
				signal = it
			} else {
				alert = it
			}
		}
	}
	if alert == nil || signal == nil {
		t.Fatalf("alert saved %v, signal saved %v", alert != nil, signal != nil)
	}
	if signal.GetName() != secure.SignalName(alert.GetName()) || signal.GetZone() != alert.GetZone() {
		t.Fatalf("the signal is not named by its alert's wire name")
	}
	if len(signal.GetEnvelope()) != 0 || signal.GetAssetPath() != "" {
		t.Fatalf("the signal carries %d envelope bytes, asset %q", len(signal.GetEnvelope()), signal.GetAssetPath())
	}
	if len(alert.GetEnvelope()) == 0 {
		t.Fatal("the alert went out empty")
	}
	b, err := proto.Marshal(signal)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(b, alert.GetEnvelope()[:16]) || bytes.Contains(b, []byte(marker)) {
		t.Fatal("the signal record carries the alert's bytes")
	}
}

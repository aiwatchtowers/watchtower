package relay

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/relaytest"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// items seals n small records named target-<from>…
func (h *harness) items(t *testing.T, from, n int) []transport.SaveItem {
	t.Helper()
	items := make([]transport.SaveItem, n)
	for i := range items {
		items[i] = transport.SaveItem{Record: h.seal(t, "target-"+strconv.Itoa(from+i), `{}`)}
	}
	return items
}

// threePerRequest lowers tr's request budget so that three of h's small
// records fit one save request and a fourth does not.
func (h *harness) threePerRequest(t *testing.T, tr *Transport) {
	t.Helper()
	r := h.seal(t, "target-1", `{}`)
	w := &relayv1.SaveItem{Record: &relayv1.Record{Zone: r.Zone(), Name: r.WireName(), Envelope: r.Envelope(), ClientModifiedAtMs: tr.o.Clock().UnixMilli()}}
	tr.requestBudget = 3*saveCost(w) + 8
}

// saveSizes is the item count of every save request the fake relay got.
func saveSizes(h *harness) []int {
	var n []int
	for _, r := range h.relay.Requests("save") {
		n = append(n, len(r.GetSave().GetItems()))
	}
	return n
}

func TestRelayTransport_SaveLimitsMatchTheRelay(t *testing.T) {
	if maxRecordBytes != relaytest.MaxRecordBytes {
		t.Fatalf("maxRecordBytes %d, relay %d", maxRecordBytes, relaytest.MaxRecordBytes)
	}
	// The budget keeps 128 KiB under the relay's body cap for the
	// estimate's slack.
	if saveRequestBudget > relaytest.MaxBodyBytes-128<<10 {
		t.Fatalf("budget %d too close to the relay's body cap %d", saveRequestBudget, relaytest.MaxBodyBytes)
	}
}

// #1760: a batch over the relay's body cap goes as several requests under
// the budget, all saved, in the items' order (the fake relay refuses a body
// over its cap, as the relay does).
func TestRelayTransport_SaveSplitsABigBatch(t *testing.T) {
	h := newHarness(t)
	items := make([]transport.SaveItem, 8)
	for i := range items {
		items[i] = transport.SaveItem{Record: h.seal(t, "target-"+strconv.Itoa(i+1), strings.Repeat("x", 300<<10))}
	}
	out, err := h.tr.Save(t.Context(), items)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	for i, o := range out {
		if !o.Saved || o.RecordSeq != uint64(i+1) {
			t.Fatalf("outcome %d: %+v", i, o)
		}
	}
	reqs := h.relay.Requests("save")
	k, total := 0, 0
	for _, r := range reqs {
		n := proto.Size(r)
		if n > saveRequestBudget {
			t.Fatalf("request of %d bytes over the budget %d", n, saveRequestBudget)
		}
		total += n
		for _, it := range r.GetSave().GetItems() {
			if it.GetRecord().GetName() != items[k].Record.WireName() {
				t.Fatalf("request item %d out of order", k)
			}
			k++
		}
	}
	if len(reqs) < 2 || total <= relaytest.MaxBodyBytes {
		t.Fatalf("%d requests of %d bytes in all: the batch must not fit one", len(reqs), total)
	}
}

func TestRelayTransport_SaveRefusesAnOversizedRecordAlone(t *testing.T) {
	h := newHarness(t)
	h.tr.recordCap = 4 << 10
	var seen []error
	h.tr.ObserveSaves(func(_ string, err error) { seen = append(seen, err) })
	huge := h.seal(t, "target-2", strings.Repeat("x", 8<<10))
	items := []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}, {Record: huge}, {Record: h.seal(t, "target-3", `{}`)}}
	out, err := h.tr.Save(t.Context(), items)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if !out[0].Saved || !out[2].Saved || out[1].Saved || !errors.Is(out[1].Refused, transport.ErrRecordTooLarge) {
		t.Fatalf("outcomes: %+v", out)
	}
	if got := saveSizes(h); len(got) != 1 || got[0] != 2 {
		t.Fatalf("save requests: %v (the oversized record must not be sent)", got)
	}
	if len(seen) != 3 || seen[0] != nil || !errors.Is(seen[1], transport.ErrRecordTooLarge) || seen[2] != nil {
		t.Fatalf("observed: %v", seen)
	}
}

// A conflict index is per request: one in the second request names the
// right item.
func TestRelayTransport_SaveConflictInALaterRequest(t *testing.T) {
	h := newHarness(t)
	ctx := t.Context()
	if _, err := h.tr.Save(ctx, []transport.SaveItem{{Record: h.seal(t, "target-9", `{}`)}}); err != nil {
		t.Fatal(err)
	}
	h.threePerRequest(t, h.tr)
	items := h.items(t, 1, 4)
	items = append(items,
		transport.SaveItem{Record: h.seal(t, "target-9", `{}`), Expect: transport.Expect{Mode: transport.ExpectAbsent}},
		transport.SaveItem{Record: h.seal(t, "target-5", `{}`)})
	out, err := h.tr.Save(ctx, items)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if got := saveSizes(h); len(got) != 3 || got[1] != 3 || got[2] != 3 {
		t.Fatalf("save requests: %v", got)
	}
	for i, o := range out {
		if i == 4 {
			if o.Saved || o.Refused != nil || o.Conflict == nil || o.Conflict.RecordSeq != 1 {
				t.Fatalf("conflict outcome: %+v", o)
			}
			continue
		}
		if !o.Saved {
			t.Fatalf("outcome %d: %+v", i, o)
		}
	}
}

// A failure after a request went through fails the whole call, as the
// CloudKit client does: the first request's items are in the zone (the caller
// saves the whole batch again); the refused request's zones are re-read.
func TestRelayTransport_SaveFailureMidWayFailsTheCall(t *testing.T) {
	h := newHarness(t)
	h.threePerRequest(t, h.tr)
	seen := map[string][]error{}
	h.tr.ObserveSaves(func(z string, err error) { seen[z] = append(seen[z], err) })
	box := transport.MailboxZone(h.tr.c.DeviceID(), "phone1")
	boxed, err := h.sealer.Data(box, "target-4", "", []byte(`{}`), nil, "")
	if err != nil {
		t.Fatal(err)
	}
	items := append(h.items(t, 1, 3), transport.SaveItem{Record: boxed}, transport.SaveItem{Record: h.seal(t, "target-5", `{}`)})
	h.relay.FailNextSaveIn(box, relayv1.ErrorCode_ERROR_CODE_HUB_QUOTA_EXCEEDED)
	if out, err := h.tr.Save(t.Context(), items); !errors.Is(err, transport.ErrHubQuota) || out != nil {
		t.Fatalf("save: %v, %+v", err, out)
	}
	if got := saveSizes(h); len(got) != 2 || got[0] != 3 || got[1] != 2 {
		t.Fatalf("save requests: %v", got)
	}
	assertSavedNames(t, h, items[:3])
	waitZoneEvent(t, h.tr, box)
	if b := seen[box]; len(b) != 1 || !errors.Is(b[0], transport.ErrHubQuota) {
		t.Fatalf("observed %s: %v", box, b)
	}
	if d := seen[h.data]; len(d) != 1 || !errors.Is(d[0], transport.ErrHubQuota) {
		t.Fatalf("observed data: %v", d)
	}
}

// assertSavedNames checks that h's data zone holds exactly want's records.
func assertSavedNames(t *testing.T, h *harness, want []transport.SaveItem) {
	t.Helper()
	b, err := h.tr.Changes(t.Context(), h.data, 0)
	if err != nil {
		t.Fatalf("changes: %v", err)
	}
	if len(b.Changed) != len(want) {
		t.Fatalf("zone holds %d records, want %d", len(b.Changed), len(want))
	}
	for i, st := range b.Changed {
		if st.Name != want[i].Record.WireName() {
			t.Fatalf("record %d: %s, want %s", i, st.Name, want[i].Record.WireName())
		}
	}
}

// A failure of the first request fails the whole call; nothing after it is
// sent.
func TestRelayTransport_SaveFailureFirstFailsTheCall(t *testing.T) {
	h := newHarness(t)
	h.threePerRequest(t, h.tr)
	h.relay.FailNext("save", relayv1.ErrorCode_ERROR_CODE_HUB_QUOTA_EXCEEDED)
	if _, err := h.tr.Save(t.Context(), h.items(t, 1, 5)); !errors.Is(err, transport.ErrHubQuota) {
		t.Fatalf("save: %v", err)
	}
	if got := saveSizes(h); len(got) != 1 || got[0] != 3 {
		t.Fatalf("save requests: %v", got)
	}
}

// A request the relay refuses RECORD_TOO_LARGE as a whole is halved; a lone
// item refused so is refused alone.
func TestRelayTransport_SaveHalvesARequestTheRelayFindsTooLarge(t *testing.T) {
	h := newHarness(t)
	ctx := t.Context()
	h.relay.FailNext("save", relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE)
	out, err := h.tr.Save(ctx, h.items(t, 1, 4))
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	for i, o := range out {
		if !o.Saved {
			t.Fatalf("outcome %d: %+v", i, o)
		}
	}
	if got := saveSizes(h); len(got) != 3 || got[0] != 4 || got[1] != 2 || got[2] != 2 {
		t.Fatalf("save requests: %v", got)
	}

	h.relay.FailNext("save", relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE)
	h.relay.FailNext("save", relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE)
	out, err = h.tr.Save(ctx, h.items(t, 5, 2))
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if out[0].Saved || !errors.Is(out[0].Refused, transport.ErrRecordTooLarge) || !out[1].Saved {
		t.Fatalf("outcomes: %+v", out)
	}
	if got := saveSizes(h)[3:]; len(got) != 3 || got[0] != 2 || got[1] != 1 || got[2] != 1 {
		t.Fatalf("save requests: %v", got)
	}
}

// secondSave is an HTTP transport that, at the second save request, calls
// then (ending the caller's ctx) or, with fail set, fails it as a dropped
// connection would.
type secondSave struct {
	mu    sync.Mutex
	saves int
	then  func()
	fail  bool
}

func (a *secondSave) RoundTrip(r *http.Request) (*http.Response, error) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, err
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	var req relayv1.Request
	isSave := proto.Unmarshal(body, &req) == nil && req.GetSave() != nil
	a.mu.Lock()
	if isSave {
		a.saves++
	}
	n := a.saves
	a.mu.Unlock()
	if isSave && n == 2 {
		if a.fail {
			return nil, errors.New("connection reset")
		}
		a.then()
	}
	return http.DefaultTransport.RoundTrip(r)
}

// The host closing (ctx ends) or the connection dropping during the second
// request fails the whole call; the first request's items are in the zone
// and the next call saves the whole batch again (a restart leaves the same
// state).
func TestRelayTransport_SaveInterruptedMidWay(t *testing.T) {
	for name, tc := range map[string]struct {
		drop bool
		want error
	}{
		"host closes":        {want: context.Canceled},
		"connection dropped": {drop: true, want: transport.ErrUnavailable},
	} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			rt := &secondSave{fail: tc.drop, then: cancel}
			c := NewClient(h.relay.URL, h.key, client.WithHTTPClient(&http.Client{Transport: rt}))
			tr := New(c, Options{
				Origin: h.relay.URL, HubRelayID: c.DeviceID(), Store: h.store, AssetDir: h.assetDir,
				Clock: func() time.Time { return time.UnixMilli(1_700_000_000_000) },
			})
			t.Cleanup(func() { _ = tr.Close() })
			h.threePerRequest(t, tr)
			items := h.items(t, 1, 5)
			if out, err := tr.Save(ctx, items); !errors.Is(err, tc.want) || out != nil {
				t.Fatalf("save: %v, %+v", err, out)
			}
			assertSavedNames(t, h, items[:3])
		})
	}
}

//go:build interop

package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/relaytest"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
)

// measureActions is how many actions TestMeasure_HubLatencyOverTheStand
// sends (Go hub plan 4 Task 11 Step 3).
const measureActions = 200

// TestMeasure_HubLatencyOverTheStand is the hub-side latency measurement of
// Go hub plan 4 Task 11 Step 3, not part of the default interop run (its
// name is outside ^TestInterop_, and it links one more phone than the
// stand's registration limit leaves the suite): run it alone with
//
//	make relay-interop RELAY=<relay checkout> RELAY_INTEROP_RUN='^TestMeasure_'
//
// A Go phone sends measureActions actions one at a time, each waited for
// until its applied echo is back, then waits HUB_MEASURE_GAP (a Go duration;
// default none, back to back: the nudge after each applied action
// (PublishNow) is held only by the relay spacing, never by the trailing
// debounce); every action nudges a slice whose value it moves. The test logs the hub's relay p50/p90 and sample counts per step —
// the rows `watchtower hub diagnostics --json` shows — and fails only when
// an action is not applied or no read_saved sample was taken.
func TestMeasure_HubLatencyOverTheStand(t *testing.T) {
	const kind = "interop_measure"
	var n atomic.Int64
	ops := &opCounter{n: map[string]int{}, refused: map[string]int{}}
	h := startHub(t, interopOpts{
		passEvery: time.Second, linkEvery: time.Second, httpWrap: ops.wrap,
		register: func(d *actions.Dispatcher) {
			d.Register(kind, func(context.Context, actions.Request) actions.Outcome {
				n.Add(1)
				return actions.Outcome{Status: wire.StatusApplied}
			}, actions.KindOptions{Nudges: []string{"target"}})
		},
		sources: func(*state.Store) []hubslices.Source { return []hubslices.Source{bumpSource{&n}} },
	})
	var gap time.Duration
	if v := os.Getenv("HUB_MEASURE_GAP"); v != "" {
		var err error
		if gap, err = time.ParseDuration(v); err != nil {
			t.Fatalf("HUB_MEASURE_GAP: %v", err)
		}
	}
	p := linkPhone(t, h).phone
	ops.reset()
	start := time.Now()
	for i := 0; i < measureActions; i++ {
		seq, err := p.Act(kind)
		if err != nil {
			t.Fatalf("action %d: %v", i+1, err)
		}
		deadline := time.Now().Add(stepWait)
		for p.Echoes[seq].Status != wire.StatusApplied {
			if time.Now().After(deadline) {
				t.Fatalf("action %d not applied within %s", i+1, stepWait)
			}
			time.Sleep(50 * time.Millisecond)
			if _, err := p.Sync(); err != nil {
				t.Logf("phone sync: %v", err)
			}
		}
		time.Sleep(gap)
	}
	t.Logf("measure: %d actions applied in %s (gap %s)", measureActions, time.Since(start).Round(time.Millisecond), gap)
	ops.log(t, measureActions)
	// The recorder flushes once a second; the last nudged save follows the
	// last apply within the publisher's debounce.
	time.Sleep(5 * time.Second)
	st, err := state.OpenReadOnly(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	rows, err := st.LatencyStats(start.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	saved := 0
	for _, r := range rows {
		t.Logf("measure: step=%s transport=%s p50=%dms p90=%dms samples=%d",
			r.Step, r.Transport, r.P50.Milliseconds(), r.P90.Milliseconds(), r.Samples)
		if r.Transport == "relay" && r.Step == state.StepReadSaved {
			saved = r.Samples
		}
	}
	if saved == 0 {
		t.Fatal("no relay read_saved sample after the burst")
	}
	logCLI(t, h.dir, "hub", "diagnostics", "--json")
}

// TestMeasure_RelayIndicatorAcrossAnOutage is Go hub plan 4 Task 11 Step 2's
// CLI half: the status's relay.state is connected, turns unavailable once
// the stand has been down 60 s, and is connected again after the stand is
// back. It needs the stand stopped for longer than that:
//
//	RELAY_INTEROP_RESTART_PAUSE=75 make relay-interop RELAY=<relay checkout> \
//	    RELAY_INTEROP_RUN='^TestMeasure_RelayIndicator'
func TestMeasure_RelayIndicatorAcrossAnOutage(t *testing.T) {
	if *relayCtlPID == 0 {
		t.Skip("no -relay-control-pid: the stand cannot be stopped (make relay-interop sets it)")
	}
	h := startHub(t, interopOpts{passEvery: time.Second, linkEvery: time.Second})
	linkPhone(t, h)
	relayState := func() string {
		s, err := ReadStatus(h.dir)
		if err != nil || s.Relay == nil {
			return ""
		}
		return s.Relay.State
	}
	eventuallyOnStand(t, stepWait, "relay.state connected", func() bool { return relayState() == RelayConnected })
	logCLI(t, h.dir, "hub", "status", "--json")
	if err := syscall.Kill(*relayCtlPID, syscall.SIGUSR1); err != nil {
		t.Fatalf("signalling the interop script: %v", err)
	}
	down := time.Now()
	eventuallyOnStand(t, 3*time.Minute, "relay.state unavailable", func() bool { return relayState() == RelayUnavailable })
	t.Logf("measure: relay.state unavailable %s after the stop was asked", time.Since(down).Round(time.Second))
	if since := time.Since(down); since < 60*time.Second {
		t.Fatalf("unavailable after %s, before the 60 s threshold", since)
	}
	logCLI(t, h.dir, "hub", "status", "--json")
	eventuallyOnStand(t, restartWait, "relay.state connected again", func() bool { return relayState() == RelayConnected })
	t.Logf("measure: relay.state connected again %s after the stop was asked", time.Since(down).Round(time.Second))
	logCLI(t, h.dir, "hub", "status", "--json")
}

// logCLI runs `$HUB_MEASURE_CLI args…` (a built watchtower binary) on the
// hub's sidecar in a temp HOME and logs its relay or rows part; without
// HUB_MEASURE_CLI it does nothing.
func logCLI(t *testing.T, dir string, args ...string) {
	t.Helper()
	bin := os.Getenv("HUB_MEASURE_CLI")
	if bin == "" {
		return
	}
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), "HOME="+t.TempDir(), EnvHubDir+"="+dir, EnvTestWorkspace+"="+interopWorkspace)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("%v: %v", args, err)
	}
	var v struct {
		Relay *RelayHealth    `json:"relay"`
		Rows  json.RawMessage `json:"rows"`
	}
	if err := json.Unmarshal(out, &v); err != nil {
		t.Fatalf("%v: %v", args, err)
	}
	if v.Relay != nil {
		t.Logf("measure: %v → relay.state=%s quota_hub=%v push_off=%v", args, v.Relay.State, v.Relay.QuotaHub, v.Relay.PushOff)
	}
	if v.Rows != nil {
		t.Logf("measure: %v → rows=%s", args, v.Rows)
	}
}

// opCounter counts the hub's relay ops (POST /v1/op) by op name, and the
// answers that carried a relay error by op and code: what an action costs
// the hub on the relay (ask #976).
type opCounter struct {
	base    http.RoundTripper
	mu      sync.Mutex
	n       map[string]int
	refused map[string]int
}

func (c *opCounter) wrap(rt http.RoundTripper) http.RoundTripper {
	c.base = rt
	return c
}

func (c *opCounter) reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.n, c.refused = map[string]int{}, map[string]int{}
}

func (c *opCounter) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/v1/op") || r.Body == nil {
		return c.base.RoundTrip(r)
	}
	body, err := io.ReadAll(r.Body)
	_ = r.Body.Close()
	if err != nil {
		return nil, err
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	op := "undecodable"
	var req relayv1.Request
	if proto.Unmarshal(body, &req) == nil {
		op = relaytest.OpName(&req)
	}
	c.mu.Lock()
	c.n[op]++
	c.mu.Unlock()
	res, err := c.base.RoundTrip(r)
	if err != nil {
		return res, err
	}
	out, rerr := io.ReadAll(res.Body)
	_ = res.Body.Close()
	res.Body = io.NopCloser(bytes.NewReader(out))
	var resp relayv1.Response
	if rerr == nil && proto.Unmarshal(out, &resp) == nil && resp.GetError() != nil {
		c.mu.Lock()
		c.refused[op+" "+resp.GetError().GetCode().String()]++
		c.mu.Unlock()
	}
	return res, nil
}

// log reports the counts and the ops per action.
func (c *opCounter) log(t *testing.T, actions int) {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	total := 0
	names := make([]string, 0, len(c.n))
	for k, v := range c.n {
		total += v
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		t.Logf("measure: op=%s count=%d per_action=%.2f", k, c.n[k], float64(c.n[k])/float64(actions))
	}
	t.Logf("measure: ops total=%d per_action=%.2f", total, float64(total)/float64(actions))
	refused := make([]string, 0, len(c.refused))
	for k := range c.refused {
		refused = append(refused, k)
	}
	sort.Strings(refused)
	for _, k := range refused {
		t.Logf("measure: refused op=%s count=%d", k, c.refused[k])
	}
}

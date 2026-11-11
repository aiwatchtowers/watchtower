package slices

import (
	"regexp"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/transport"
	"watchtower/internal/logcanary"
)

// D is the whole seconds on the publisher's monotonic clock from the cycle
// that saw the wipe to the one that finished the republish.
func TestRotationRepublishDurationIsTheMonotonicSpan(t *testing.T) {
	logs := logcanary.Capture(t)
	r := newRig(t, transport.KindRelay)
	a := &fakeSource{kind: "target"}
	a.set(item("1", `{"id":1}`))
	b := &fakeSource{kind: "workbench"}
	b.set(item("2", `{"id":2}`))
	p := r.publisher(a, b)
	mono := time.Unix(0, 0)
	p.mono = func() time.Time { return mono }
	r.cycle(p)
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	r.advance(time.Second)
	r.cycle(p, "target")
	mono = mono.Add(90*time.Second + 400*time.Millisecond)
	r.advance(time.Second)
	r.cycle(p, "workbench")
	got := regexp.MustCompile(`hub: rotation republish: .*`).FindAllString(logs.String(), -1)
	if len(got) != 1 || !regexp.MustCompile(`^hub: rotation republish: complete, 2 records, 0 asset bytes, \d+ envelope bytes, 90 s$`).MatchString(got[0]) {
		t.Fatalf("republish lines %q, want one complete line with 90 s", got)
	}
}

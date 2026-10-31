package slices

import (
	"context"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
)

// A paused publisher reads no source and saves or deletes nothing, however
// long the pause and whatever is marked; Resume runs one full diff that
// carries what changed meanwhile.
func TestPausedPublisherWritesNothingAndResumeRunsOneFullDiff(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	target := &fakeSource{kind: "target"}
	target.set(item("1", `{"v":1}`))
	idle := &fakeSource{kind: "workbench"}
	ru := r.runFake(target, idle)
	frames := len(r.tr.Frames())
	if frames == 0 {
		t.Fatal("the start cycle published nothing")
	}

	ru.p.Pause()
	target.set(item("1", `{"v":2}`), item("2", `{"v":1}`))
	ru.publishSoon("target")
	ru.step(Debounce)
	ru.step(FullDiffEvery)
	ru.step(FullDiffEvery)
	if n := len(target.readTimes()); n != 1 {
		t.Fatalf("the source was read %d times, want only the start cycle's", n)
	}
	if n := len(r.tr.Frames()); n != frames {
		t.Fatalf("%d records written during the pause", n-frames)
	}

	n := ru.ft.armedCount()
	ru.p.Resume()
	ru.settle(n)
	if got := len(target.readTimes()); got != 2 {
		t.Fatalf("target read %d times after Resume, want 1 + 1", got)
	}
	if got := len(idle.readTimes()); got != 2 {
		t.Fatalf("an unmarked kind read %d times after Resume, want 1 + 1 (a full diff)", got)
	}
	if live := r.live(); len(live) != 2 {
		t.Fatalf("%d live records after Resume, want 2", len(live))
	}
}

// A Cycle that starts after Pause (Run had already chosen to cycle) reads
// and writes nothing and reports its kinds unfinished.
func TestCycleWhilePausedWritesNothing(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":1}`))
	p := r.publisher(src)
	p.Pause()
	rep, err := p.Cycle(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !rep.Aborted || len(rep.Unfinished) != 1 || rep.Saved != 0 {
		t.Fatalf("paused cycle = %+v", rep)
	}
	if len(src.readTimes()) != 0 || len(r.tr.Frames()) != 0 {
		t.Fatal("a paused cycle read a source or wrote a record")
	}
	p.Resume()
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 1 {
		t.Fatalf("cycle after Resume = %+v", rep)
	}
}

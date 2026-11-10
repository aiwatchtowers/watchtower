package slices

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/logcanary"
)

// Go twins of the Swift SlicePublisherTests rows that had none (Task 24).

// spyTransport records the wire names of each Save call in order and refuses
// the wire names in refuse (once each), as a transport refusing one record.
type spyTransport struct {
	*memfake.Fake

	mu     sync.Mutex
	saves  [][]string
	refuse map[string]bool
}

func (s *spyTransport) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	s.mu.Lock()
	names := make([]string, len(items))
	refused := make([]bool, len(items))
	var pass []transport.SaveItem
	for i, it := range items {
		names[i] = it.Record.WireName()
		if s.refuse[names[i]] {
			delete(s.refuse, names[i])
			refused[i] = true
			continue
		}
		pass = append(pass, it)
	}
	s.saves = append(s.saves, names)
	s.mu.Unlock()
	outs, err := s.Fake.Save(ctx, pass)
	if err != nil {
		return nil, err
	}
	all := make([]transport.Outcome, len(items))
	j := 0
	for i := range items {
		if refused[i] {
			all[i] = transport.Outcome{Refused: transport.ErrForbidden}
			continue
		}
		all[i] = outs[j]
		j++
	}
	return all, nil
}

// calls is every Save call's wire names so far; flat is them in one list.
func (s *spyTransport) calls() [][]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.saves)
}

func (s *spyTransport) flat() []string {
	var out []string
	for _, c := range s.calls() {
		out = append(out, c...)
	}
	return out
}

func (s *spyTransport) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.saves = nil
}

func (r *rig) spy() *spyTransport { return &spyTransport{Fake: r.tr, refuse: map[string]bool{}} }

func (r *rig) hashed(k Kind) []string {
	r.t.Helper()
	hashes, err := r.st.SliceHashes(string(k))
	if err != nil {
		r.t.Fatal(err)
	}
	var out []string
	for name, h := range hashes {
		if h.Hash != "" {
			out = append(out, name)
		}
	}
	slices.Sort(out)
	return out
}

// twin of SlicePublisherTests.testARejectedRecordClearsThePlainNamesHash: the
// Go transport refuses a record in its Save outcome (no later rejection), so
// a refused record is never hashed and the next cycle offers it again.
func TestARefusedRecordIsLeftUnhashedAndOfferedAgain(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	sp := r.spy()
	sp.refuse[r.wireName("workbench-1")] = true
	src := &fakeSource{kind: "workbench"}
	src.set(item("1", `{}`), item("2", `[]`))
	p := r.publisherWith(Config{Transport: sp}, src)

	rep := r.cycle(p)
	if rep.Saved != 1 || !slices.Equal(rep.Skipped, []string{"workbench-1"}) {
		t.Fatalf("cycle = %+v", rep)
	}
	if got := r.hashed("workbench"); !slices.Equal(got, []string{"workbench-2"}) {
		t.Fatalf("hashed = %v, want only workbench-2", got)
	}
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 1 || len(rep.Skipped) != 0 {
		t.Fatalf("the refused record is not offered again: %+v", rep)
	}
	if got := r.hashed("workbench"); !slices.Equal(got, []string{"workbench-1", "workbench-2"}) {
		t.Fatalf("hashed = %v", got)
	}
}

// twin of SlicePublisherTests.testARecordThatCannotBeSealedIsSkippedAloneAndUnhashed:
// a grant for a device with no keybox recipient is skipped alone, never
// hashed (so it is retried) and warned once while unchanged.
func TestARecordThatCannotBeSealedIsSkippedAloneAndUnhashed(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t, transport.KindRelay)
	ph := r.linkPhone()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	unknown := secure.DeviceID(pub).String()
	sp := r.spy()
	src := &fakeSource{kind: KindDeviceGrant}
	src.set(item(unknown, `{"linked":true}`), item(ph.id.String(), `{"linked":true}`))
	p := r.publisherWith(Config{Transport: sp}, src)

	rep := r.cycle(p)
	r.advance(time.Second)
	r.cycle(p)

	if rep.Saved != 1 || !slices.Equal(rep.Skipped, []string{"device_grant-" + unknown}) {
		t.Fatalf("cycle = %+v: one bad record must never block the others", rep)
	}
	if got := sp.flat(); !slices.Equal(got, []string{"keybox-" + ph.id.String()}) {
		t.Fatalf("saved = %v", got)
	}
	if got := r.hashed(KindDeviceGrant); !slices.Equal(got, []string{"device_grant-" + ph.id.String()}) {
		t.Fatalf("hashed = %v: the unsealable record must stay unhashed", got)
	}
	if n := strings.Count(sink.String(), "device_grant-"+unknown); n != 1 {
		t.Fatalf("an unchanged unsealable record warned %d times", n)
	}
}

// twin of SlicePublisherTests.testARecordThatLeftTheWindowAcrossARotationIsDeletedAtTheNextCycle:
// the rotation blanks the hashes but keeps the wire names, so a record gone
// from its source meanwhile is still deleted.
func TestARecordThatLeftTheWindowAcrossARotationIsDeletedAtTheNextCycle(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "workbench"}
	src.set(item("1", `{"name":"acme"}`), item("2", `{"name":"beta"}`))
	p := r.publisher(src)
	r.cycle(p)
	if n := len(r.live()); n != 2 {
		t.Fatalf("live before = %d", n)
	}

	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	src.set(item("1", `{"name":"acme"}`))
	r.advance(time.Second)
	rep := r.cycle(p)

	if rep.Saved != 1 || rep.Deleted != 1 {
		t.Fatalf("cycle = %+v: the record in the window resealed, the gone one deleted", rep)
	}
	live := r.live()
	w := r.wireName("workbench-1")
	if _, ok := live[w]; !ok || len(live) != 1 {
		t.Fatalf("live after = %d records, workbench-1 there: %v (no orphan is left)", len(live), ok)
	}
	if f := r.opened(live[w], w); f.ID != "workbench-1" {
		t.Fatalf("frame = %+v", f)
	}
	if got := r.hashed("workbench"); !slices.Equal(got, []string{"workbench-1"}) {
		t.Fatalf("hashed = %v", got)
	}
}

// twin of SlicePublisherTests.testANewPhonesGrantIsSavedAndSentBeforeTheBacklog:
// the first linked cycle saves the grant in its own Save before the backlog
// of every other kind. (The Swift hub's separate "send the grant alone" pass
// is gone: each kind is its own Save request on the Go transport.)
func TestANewPhonesGrantIsSavedBeforeTheBacklog(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	ph := r.linkPhone()
	sp := r.spy()
	grant := &fakeSource{kind: KindDeviceGrant}
	grant.set(item(ph.id.String(), `{"linked":false}`))
	var others []Source
	for _, k := range []Kind{"workbench", "workbench_target", "meeting_transcript"} {
		s := &fakeSource{kind: k}
		s.set(item("1", `{}`), item("2", `{}`), item("3", `{}`))
		others = append(others, s)
	}
	r.setLinked(false)
	p := r.publisherWith(Config{Transport: sp}, append(others, grant)...)
	r.cycle(p)
	sp.reset()

	r.setLinked(true)
	grant.set(item(ph.id.String(), `{"linked":true}`))
	r.advance(time.Second)
	rep := r.cycle(p, KindDeviceGrant)

	calls := sp.calls()
	if len(calls) == 0 || !slices.Equal(calls[0], []string{"keybox-" + ph.id.String()}) {
		t.Fatalf("Save calls = %v: the grant must be saved first, alone", calls)
	}
	if n := len(sp.flat()); n != 10 || rep.Saved != 10 {
		t.Fatalf("saved %d records (report %+v), want the grant then the backlog of 9", n, rep)
	}
}

// twin of SlicePublisherTests.testACycleSavesTheUrgentKindsFirst.
func TestACycleSavesTheUrgentKindsFirst(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	sp := r.spy()
	bench, ask := &fakeSource{kind: "workbench"}, &fakeSource{kind: "owner_ask"}
	bench.set(item("1", `{"v":1}`))
	ask.set(item("1", `{"v":1}`))
	r.cycle(r.publisherWith(Config{Transport: sp}, bench, ask))
	if got, want := sp.flat(), []string{r.wireName("owner_ask-1"), r.wireName("workbench-1")}; !slices.Equal(got, want) {
		t.Fatalf("saved %v, want %v", got, want)
	}
}

// twin of SlicePublisherTests.testAsksPublishBeforeChat: the near-live chat is
// urgent but never ahead of an ask.
func TestAsksPublishBeforeChat(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	sp := r.spy()
	chat, ask, bench := &fakeSource{kind: KindSessionChat}, &fakeSource{kind: "owner_ask"}, &fakeSource{kind: "workbench"}
	for _, s := range []*fakeSource{chat, ask, bench} {
		s.set(item("1", `{"v":1}`))
	}
	r.cycle(r.publisherWith(Config{Transport: sp}, chat, bench, ask))
	want := []string{r.wireName("owner_ask-1"), r.wireName("session_chat-1"), r.wireName("workbench-1")}
	if got := sp.flat(); !slices.Equal(got, want) {
		t.Fatalf("saved %v, want %v", got, want)
	}
}

// twin of SlicePublisherTests.testAFailedFirstLinkedCycleIsRetriedInFull: the
// next cycle still diffs every kind, whatever it is asked; once one ran to
// its end, cycles keep their own scope.
func TestAFailedFirstLinkedCycleIsRetriedInFull(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	ph := r.linkPhone()
	sp := r.spy()
	grant, bench := &fakeSource{kind: KindDeviceGrant}, &fakeSource{kind: "workbench"}
	grant.set(item(ph.id.String(), `{"linked":false}`))
	bench.set(item("1", `{"v":1}`))
	r.setLinked(false)
	p := r.publisherWith(Config{Transport: sp}, grant, bench)
	r.cycle(p)

	r.setLinked(true)
	grant.set(item(ph.id.String(), `{"linked":true}`))
	r.tr.FailNext("save", transport.ErrUnavailable)
	r.advance(time.Second)
	if _, err := p.Cycle(context.Background(), []Kind{KindDeviceGrant}); !errors.Is(err, transport.ErrUnavailable) {
		t.Fatalf("Cycle = %v", err)
	}
	if n := len(bench.readTimes()); n != 0 {
		t.Fatalf("bench read %d times: the full pass stopped at the grant", n)
	}

	sp.reset()
	r.advance(time.Second)
	r.cycle(p, KindDeviceGrant)
	if got, want := sp.flat(), []string{"keybox-" + ph.id.String(), r.wireName("workbench-1")}; !slices.Equal(got, want) {
		t.Fatalf("retry saved %v, want %v: it still publishes every kind", got, want)
	}

	bench.set(item("1", `{"v":2}`))
	r.advance(time.Second)
	if rep := r.cycle(p, KindDeviceGrant); rep.Saved != 0 {
		t.Fatalf("cycle = %+v: once one ran to its end, cycles keep their own scope", rep)
	}
}

// sealedAsset writes plain as a sealed asset file under dir.
func sealedAsset(t *testing.T, dir, name, plain string) (string, *secure.AssetDescriptor) {
	t.Helper()
	key := make([]byte, 32)
	var id secure.ID
	if _, err := rand.Read(key); err != nil {
		t.Fatal(err)
	}
	if _, err := rand.Read(id[:]); err != nil {
		t.Fatal(err)
	}
	sealed, d, err := secure.EncryptAsset([]byte(plain), id, key, secure.ChunkSize)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, sealed, 0o600); err != nil {
		t.Fatal(err)
	}
	return path, &d
}

// twin of SlicePublisherTests.testAChangedAssetAloneRepublishesAndReplacesTheFile
// (publisher half; the staged file's replacement is the source's, see
// sources.TestTranscriptUnchangedCycleBuildsAndReadsNothing).
func TestAChangedAssetAloneRepublishes(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	dir := t.TempDir()
	src := &fakeSource{kind: "meeting_transcript"}
	path, d := sealedAsset(t, dir, "7-a.asset", "[1]")
	src.set(Item{ID: "7", Payload: []byte(`{}`), Asset: d, AssetPath: path})
	p := r.publisher(src)
	if rep := r.cycle(p); rep.Saved != 1 {
		t.Fatalf("first = %+v", rep)
	}
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 0 {
		t.Fatalf("same payload and asset: %+v", rep)
	}

	path2, d2 := sealedAsset(t, dir, "7-b.asset", "[2]")
	src.set(Item{ID: "7", Payload: []byte(`{}`), Asset: d2, AssetPath: path2})
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 1 {
		t.Fatalf("the hash must cover the asset's content: %+v", rep)
	}
	var found bool
	for _, b := range r.tr.Attachments() {
		if plain, err := secure.DecryptAsset(b, *d2); err == nil && string(plain) == "[2]" {
			found = true
		}
	}
	if !found {
		t.Fatal("the changed asset was not uploaded")
	}
}

// twin of SlicePublisherTests.testTheAssetHashIsThePayloadPlusTheAssetContent.
func TestTheAssetHashIsThePayloadPlusTheAssetContent(t *testing.T) {
	plain := Item{ID: "7", Payload: []byte(`{}`)}
	if got, want := itemHash(plain), itemHash(Item{Payload: []byte(`{}`)}); got != want {
		t.Fatalf("no asset: %s, want the payload hash %s", got, want)
	}
	one, two := plain, plain
	one.Asset = &secure.AssetDescriptor{PlaintextDigest: [32]byte{1}}
	two.Asset = &secure.AssetDescriptor{PlaintextDigest: [32]byte{2}}
	if itemHash(one) == itemHash(two) || itemHash(one) == itemHash(plain) {
		t.Fatal("the asset hash must be the payload plus the asset content")
	}
}

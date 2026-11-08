package hub

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// The weekly relay key rotation end to end over the fake transport (relay
// client Phase 5, Task 6): the keyring, the link center's keyboxes, the slice
// publisher and the action processor on one sidecar, with twin phones that
// read their keyboxes and data zone, act, and read their echoes and controls.
// The publisher's content-free republish line is checked here too: on the
// fake it proves only that the count is right ("Measuring the cost").

// rotSource is one data kind's slice, set by the test.
type rotSource struct {
	kind  hubslices.Kind
	mu    sync.Mutex
	items []hubslices.Item
}

func (s *rotSource) Kind() hubslices.Kind { return s.kind }

func (s *rotSource) Items(context.Context) ([]hubslices.Item, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]hubslices.Item, len(s.items))
	for i, it := range s.items {
		it.Payload = slices.Clone(it.Payload)
		out[i] = it
	}
	return out, nil
}

// rotWorld is one hub's sidecar, keyring, link center, publisher and
// processor on the relay memfake, its data zone and what it applied.
type rotWorld struct {
	*zoneRig
	data       string
	disp       *actions.Dispatcher
	proc       *actions.Processor
	pub        *hubslices.Publisher
	srcs       []hubslices.Source
	logs       *logcanary.Sink
	records    int   // records the data zone holds: 3 data records + one keybox per phone
	assetBytes int64 // the sealed asset files' sizes

	mu      sync.Mutex
	applied map[string]int // test_noop applies per action id
}

const rotHubRelay = "hubrelay"

// newRotWorld is a relay hub at epoch 1 with two meeting transcripts (each
// with a sealed asset) and one workbench record, no phone linked yet.
func newRotWorld(t *testing.T) *rotWorld {
	t.Helper()
	w := &rotWorld{zoneRig: newZoneRig(t, "relay"), data: transport.DataZone(rotHubRelay),
		disp: actions.NewDispatcher(), logs: logcanary.Capture(t), applied: map[string]int{}}
	w.disp.Register("test_noop", func(_ context.Context, r actions.Request) actions.Outcome {
		w.mu.Lock()
		defer w.mu.Unlock()
		w.applied[r.Action.ID]++
		return actions.Outcome{Status: wire.StatusApplied}
	}, actions.KindOptions{})
	w.newProcessor()
	dir := t.TempDir()
	transcripts := &rotSource{kind: "meeting_transcript"}
	for i, plain := range []string{"[1]", "[1,2,3]"} {
		id := logcanary.Text("transcript.id") + strconv.Itoa(i)
		path, d := w.sealedAsset(dir, id, plain)
		transcripts.items = append(transcripts.items, hubslices.Item{ID: id,
			Payload: []byte(`{"title":"` + logcanary.Text("transcript.title") + `"}`), Asset: d, AssetPath: path})
	}
	bench := &rotSource{kind: "workbench", items: []hubslices.Item{{ID: logcanary.Text("workbench.id"),
		Payload: []byte(`{"name":"` + logcanary.Text("workbench.name") + `"}`)}}}
	w.records = 3
	w.srcs = []hubslices.Source{hubslices.GrantSource(w.center), transcripts, bench}
	w.restartPublisher()
	return w
}

// newProcessor is the action processor the runtime wires on a relay hub:
// echoes and controls sealed in the phone's epoch (hubRuntime.phoneEpoch).
func (w *rotWorld) newProcessor() {
	h := &hubRuntime{st: w.st, kr: w.kr}
	w.proc = actions.NewProcessor(actions.Config{
		Store: w.st, Transport: w.tr, Sealer: secure.NewSealer(w.kr), Opener: secure.NewOpener(w.kr, w.kr),
		Keys: w.kr, Dispatcher: w.disp, HubRelayID: rotHubRelay, Clock: w.clock, EpochFor: h.phoneEpoch,
	})
}

// restartPublisher is a new publisher over the same sidecar: what a hub
// restart starts with (nothing of the last one's memory).
func (w *rotWorld) restartPublisher() {
	w.pub = hubslices.NewPublisher(hubslices.Config{Store: w.st, Transport: w.rel, Sealer: secure.NewSealer(w.kr),
		DataZone: w.data, Sources: w.srcs, Clock: w.clock})
}

// sealedAsset writes plain as a sealed asset file and counts its size.
func (w *rotWorld) sealedAsset(dir, id, plain string) (string, *secure.AssetDescriptor) {
	w.t.Helper()
	key := make([]byte, 32)
	var aid secure.ID
	if _, err := rand.Read(key); err != nil {
		w.t.Fatal(err)
	}
	if _, err := rand.Read(aid[:]); err != nil {
		w.t.Fatal(err)
	}
	sealed, d, err := secure.EncryptAsset([]byte(plain), aid, key, secure.ChunkSize)
	if err != nil {
		w.t.Fatal(err)
	}
	path := filepath.Join(dir, strconv.Itoa(len(id))+"-"+strconv.FormatInt(w.assetBytes, 10)+".asset")
	if err := os.WriteFile(path, sealed, 0o600); err != nil {
		w.t.Fatal(err)
	}
	w.assetBytes += int64(len(sealed))
	return path, &d
}

// link links a twin phone; offering phones offer at once (epoch_ack of the
// current epoch with next_kx), as a phone on the relay route does.
func (w *rotWorld) link(offering bool) *hubtest.Phone {
	w.t.Helper()
	ph := w.phone()
	w.records++
	if offering {
		w.ack(ph, true)
	}
	return ph
}

// ack writes the phone's epoch_ack of the epoch it seals in (with its offer
// when offering) and runs a pass.
func (w *rotWorld) ack(ph *hubtest.Phone, offering bool) {
	w.t.Helper()
	var err error
	if offering {
		_, err = ph.AckEpoch(ph.Epoch())
	} else {
		e := ph.Epoch()
		_, err = ph.WriteControl(wire.Control{Kind: wire.ControlEpochAck, Epoch: &e})
	}
	if err != nil {
		w.t.Fatal(err)
	}
	w.pass()
}

func (w *rotWorld) pass() {
	w.t.Helper()
	if _, err := w.proc.Pass(context.Background()); err != nil {
		w.t.Fatal(err)
	}
}

// cycle is one full publisher cycle a second after the last (the spacing
// rule runs on the hub's clock).
func (w *rotWorld) cycle() hubslices.CycleReport {
	w.t.Helper()
	w.advance(time.Second)
	rep, err := w.pub.Cycle(context.Background(), nil)
	if err != nil {
		w.t.Fatal(err)
	}
	return rep
}

// rotate is the age rotation a week on.
func (w *rotWorld) rotate() {
	w.t.Helper()
	w.advance(week)
	w.rotateIfDue(true)
}

// takeKeybox has the phone read its data-zone keybox and merge its keys.
func (w *rotWorld) takeKeybox(ph *hubtest.Phone) {
	w.t.Helper()
	kb, ok, err := ph.ReadKeybox(w.data)
	if err != nil {
		w.t.Fatal(err)
	}
	if !ok || kb.Keys == nil {
		w.t.Fatal("no keybox with keys in the data zone")
	}
}

// openAll has the phone open every slice record of the data zone, each
// sealed in epoch.
func (w *rotWorld) openAll(ph *hubtest.Phone, epoch uint32) {
	w.t.Helper()
	recs, err := ph.OpenData(w.data)
	if err != nil {
		w.t.Fatal(err)
	}
	if len(recs) != 3 {
		w.t.Fatalf("the phone opened %d slice records, want 3", len(recs))
	}
	for _, rec := range recs {
		res, err := w.tr.Changes(context.Background(), w.data, 0)
		if err != nil {
			w.t.Fatal(err)
		}
		for _, s := range res.Changed {
			if s.Name != rec.Name {
				continue
			}
			if h, err := secure.ParseHeader(s.Envelope); err != nil || h.Epoch != epoch {
				w.t.Fatalf("slice record sealed in epoch %d, want %d (%v)", h.Epoch, epoch, err)
			}
		}
	}
}

func (w *rotWorld) appliedOnce(t *testing.T) {
	t.Helper()
	w.mu.Lock()
	defer w.mu.Unlock()
	for id, n := range w.applied {
		if n != 1 {
			t.Fatalf("action %s applied %d times", id, n)
		}
	}
}

var republishLine = regexp.MustCompile(`hub: rotation republish: .*`)

// republished is every republish line logged so far.
func (w *rotWorld) republished() []string {
	return republishLine.FindAllString(w.logs.String(), -1)
}

// wantRepublished checks the republish lines logged so far: each is numbers
// only, and their outcomes and counts are want ("complete 4 B" with B the
// asset bytes as a number).
func (w *rotWorld) wantRepublished(t *testing.T, want ...string) {
	t.Helper()
	strict := regexp.MustCompile(`^hub: rotation republish: (complete|interrupted), (\d+) records, (\d+) asset bytes, \d+ s$`)
	var got []string
	for _, l := range w.republished() {
		m := strict.FindStringSubmatch(l)
		if m == nil {
			t.Fatalf("republish line not numbers only: %q", l)
		}
		got = append(got, m[1]+" "+m[2]+" "+m[3])
	}
	if !slices.Equal(got, want) {
		t.Fatalf("republish lines %q, want %q", got, want)
	}
}

func (w *rotWorld) full(outcome string, records int) string {
	return outcome + " " + strconv.Itoa(records) + " " + strconv.FormatInt(w.assetBytes, 10)
}

// TestRotationRepublishLogsCounts: the cycle after a rotation reseals the
// whole window and logs one line with the records, the asset bytes and the
// time, and nothing else: no record name, wire name, hub or phone id. The
// first publish of a new hub is no republish and logs none.
func TestRotationRepublishLogsCounts(t *testing.T) {
	w := newRotWorld(t)
	ph := w.link(true)
	if rep := w.cycle(); rep.Saved != w.records {
		t.Fatalf("first cycle saved %d, want %d", rep.Saved, w.records)
	}
	w.wantRepublished(t)
	w.rotate()
	if rep := w.cycle(); rep.Saved != w.records {
		t.Fatalf("republish saved %d, want %d", rep.Saved, w.records)
	}
	w.wantRepublished(t, w.full("complete", w.records))
	if rep := w.cycle(); rep.Saved != 0 {
		t.Fatalf("a cycle after the republish saved %d", rep.Saved)
	}
	w.wantRepublished(t, w.full("complete", w.records))
	w.takeKeybox(ph)
	w.openAll(ph, 2)

	w.logs.AssertClean(t)
	res, err := w.tr.Changes(context.Background(), w.data, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range w.republished() {
		for _, s := range res.Changed {
			if strings.Contains(l, s.Name) {
				t.Fatalf("a wire name reached the republish line %q", l)
			}
		}
		for _, v := range []string{w.kr.HubID().String(), ph.ID().String(), ph.RelayDeviceID(), rotHubRelay, "meeting_transcript", "workbench", "keybox"} {
			if strings.Contains(l, v) {
				t.Fatalf("%q reached the republish line %q", v, l)
			}
		}
	}
}

// TestRotationRepublishInterruptedSaysSo: a rotation whose republish has not
// finished when the next one wipes the hashes again logs interrupted with
// the counts so far, then the next republish its own complete line.
func TestRotationRepublishInterruptedSaysSo(t *testing.T) {
	w := newRotWorld(t)
	w.link(true)
	w.cycle()
	w.rotate()
	w.advance(time.Second)
	if rep, err := w.pub.Cycle(context.Background(), []hubslices.Kind{"workbench"}); err != nil || rep.Saved != 1 {
		t.Fatalf("workbench-only cycle = %+v, %v", rep, err)
	}
	w.wantRepublished(t)
	w.rotate()
	if rep := w.cycle(); rep.Saved != w.records {
		t.Fatalf("republish saved %d, want %d", rep.Saved, w.records)
	}
	w.wantRepublished(t, "interrupted 1 0", w.full("complete", w.records))
}

// TestRuntime_RestartAfterRotationRepublishesOnce (F3): the rotation
// committed and the hub stopped before its publisher ran. The hashes stay
// wiped, so the restarted hub republishes the window once, in the new
// epoch, and does not rotate again; a further restart republishes nothing.
func TestRuntime_RestartAfterRotationRepublishesOnce(t *testing.T) {
	w := newRotWorld(t)
	ph := w.link(true)
	w.cycle()
	w.takeKeybox(ph)
	w.rotate()

	w.restart() // the keyring
	w.newProcessor()
	w.restartPublisher()
	w.rotateIfDue(false)
	if rep := w.cycle(); rep.Saved != w.records {
		t.Fatalf("the restarted hub republished %d, want %d", rep.Saved, w.records)
	}
	if w.epoch() != 2 {
		t.Fatalf("epoch %d after the restart, want 2", w.epoch())
	}
	w.takeKeybox(ph)
	w.openAll(ph, 2)
	if !ph.HoldsPair(2) {
		t.Fatal("the phone holds no pair for epoch 2")
	}
	w.restartPublisher()
	if rep := w.cycle(); rep.Saved != 0 {
		t.Fatalf("a second restart republished %d", rep.Saved)
	}
	w.wantRepublished(t, w.full("complete", w.records))
}

// TestRotationWhileRelayDownPublishesOnReturn (F4): the relay is unreachable
// at the rotation. It is local; the keybox and slices wait. Back on the
// relay, the phone still on the old epoch gets its echo in its acked epoch,
// then the republish goes and the phone moves to the new one.
func TestRotationWhileRelayDownPublishesOnReturn(t *testing.T) {
	w := newRotWorld(t)
	ph := w.link(true)
	w.cycle()
	w.takeKeybox(ph)

	w.tr.SetAvailable(false)
	w.rotate()
	if w.epoch() != 2 {
		t.Fatalf("epoch %d, want the local rotation to 2", w.epoch())
	}
	w.advance(time.Second)
	if rep, err := w.pub.Cycle(context.Background(), nil); err == nil || rep.Saved != 0 {
		t.Fatalf("cycle with the relay down = %+v, %v", rep, err)
	}
	w.wantRepublished(t)

	w.tr.SetAvailable(true)
	seq, err := ph.Act("test_noop")
	if err != nil {
		t.Fatal(err)
	}
	w.pass()
	if _, err := ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if ph.Echoes[seq].Status != wire.StatusApplied || ph.EchoEpochs[seq] != 1 {
		t.Fatalf("echo %+v in epoch %d, want applied in the acked epoch 1", ph.Echoes[seq], ph.EchoEpochs[seq])
	}

	if rep := w.cycle(); rep.Saved != w.records {
		t.Fatalf("the republish on return saved %d, want %d", rep.Saved, w.records)
	}
	w.wantRepublished(t, w.full("complete", w.records))
	w.takeKeybox(ph)
	w.openAll(ph, 2)
	w.ack(ph, true)
	seq, err = ph.Act("test_noop")
	if err != nil {
		t.Fatal(err)
	}
	w.pass()
	if _, err := ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if ph.Echoes[seq].Status != wire.StatusApplied || ph.EchoEpochs[seq] != 2 || !ph.HoldsPair(2) {
		t.Fatalf("echo %+v in epoch %d (pair 2 held %v), want applied in epoch 2", ph.Echoes[seq], ph.EchoEpochs[seq], ph.HoldsPair(2))
	}
	w.appliedOnce(t)
}

// TestRuntime_ThreeRotationsTwoPhones: one phone offers, one stays static.
// In every epoch each reads its keybox and the data zone, acks, gets its
// echoes and a resend_from control sealed in that epoch (the offering phone
// under the epoch's pair, the static one under static keys), and every
// action is applied once.
func TestRuntime_ThreeRotationsTwoPhones(t *testing.T) {
	w := newRotWorld(t)
	offered := w.link(true)
	static := w.link(false)
	w.cycle()
	var lines []string
	for e := uint32(2); e <= 4; e++ {
		w.rotate()
		if rep := w.cycle(); rep.Saved != w.records {
			t.Fatalf("epoch %d: republish saved %d, want %d", e, rep.Saved, w.records)
		}
		lines = append(lines, w.full("complete", w.records))
		for _, p := range []struct {
			ph       *hubtest.Phone
			offering bool
		}{{offered, true}, {static, false}} {
			ph := p.ph
			w.takeKeybox(ph)
			if ph.HoldsPair(e) != p.offering {
				t.Fatalf("epoch %d: pair held %v, want %v", e, ph.HoldsPair(e), p.offering)
			}
			w.openAll(ph, e)
			w.ack(ph, p.offering)

			// A gap: the hub holds the second action and asks resend_from.
			gap, err := ph.Queue(ph.NewAction("test_noop"))
			if err != nil {
				t.Fatal(err)
			}
			next, err := ph.Act("test_noop")
			if err != nil {
				t.Fatal(err)
			}
			w.pass()
			controls := len(ph.Controls)
			if _, err := ph.Sync(); err != nil { // the held echo and resend_from: the phone resends
				t.Fatal(err)
			}
			if len(ph.Controls) != controls+1 || ph.Controls[controls].Kind != wire.ControlResendFrom || ph.ControlEpochs[controls] != e {
				t.Fatalf("epoch %d: controls %+v in epochs %v, want a resend_from in %d", e, ph.Controls[controls:], ph.ControlEpochs[controls:], e)
			}
			w.pass()
			if _, err := ph.Sync(); err != nil {
				t.Fatal(err)
			}
			for _, s := range []uint64{gap, next} {
				if ph.Echoes[s].Status != wire.StatusApplied || ph.EchoEpochs[s] != e {
					t.Fatalf("epoch %d: echo of %d %+v in epoch %d", e, s, ph.Echoes[s], ph.EchoEpochs[s])
				}
			}
			if len(ph.Outbox()) != 0 {
				t.Fatalf("epoch %d: outbox %v left", e, ph.Outbox())
			}
		}
	}
	w.wantRepublished(t, lines...)
	w.appliedOnce(t)
	if len(w.applied) != 12 {
		t.Fatalf("%d actions applied, want 12", len(w.applied))
	}
}

// TestLostResendFromFilledByResendingUnechoed (F33): the phone's ack of the
// new epoch is lost, so the hub seals in its acked epoch, whose pair the
// phone has erased. The held echoes and the resend_from are dropped; the
// drop resends every unechoed action, which fills the gap: each is applied
// once and the held ones are released. Once the ack is sent again the
// phone reads its final echoes.
func TestLostResendFromFilledByResendingUnechoed(t *testing.T) {
	w := newRotWorld(t)
	ph := w.link(true)
	w.rotate()
	w.cycle()
	w.takeKeybox(ph)
	w.ack(ph, true) // acked 2, offer for 3
	w.rotate()
	w.cycle()
	w.takeKeybox(ph) // epoch 3; its ack is lost
	ph.ErasePair(2)
	ph.RequeueOnDrop = true

	first, err := ph.Queue(ph.NewAction("test_noop")) // never reaches the relay
	if err != nil {
		t.Fatal(err)
	}
	var held []uint64
	for range 2 {
		s, err := ph.Act("test_noop")
		if err != nil {
			t.Fatal(err)
		}
		held = append(held, s)
	}
	w.pass() // holds both, asks resend_from(first), sealed in epoch 2
	if _, err := ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if len(ph.Dropped) != 3 || len(ph.Controls) != 0 {
		t.Fatalf("dropped %d, controls %d: want the two held echoes and the resend_from dropped", len(ph.Dropped), len(ph.Controls))
	}
	w.pass() // the requeued actions: the gap filled, the held ones released
	w.mu.Lock()
	got := len(w.applied)
	w.mu.Unlock()
	if got != 3 {
		t.Fatalf("%d actions applied after the requeue, want 3", got)
	}
	if n := heldCount(t, w.st); n != 0 {
		t.Fatalf("%d actions still held", n)
	}

	w.ack(ph, true) // the lost ack goes again at the next raise
	for i := 0; i < 3 && len(ph.Outbox()) > 0; i++ {
		if _, err := ph.Sync(); err != nil {
			t.Fatal(err)
		}
		w.pass()
	}
	for _, s := range append([]uint64{first}, held...) {
		if ph.Echoes[s].Status != wire.StatusApplied {
			t.Fatalf("echo of %d: %+v", s, ph.Echoes[s])
		}
	}
	w.appliedOnce(t)
}

func heldCount(t *testing.T, st *state.Store) int {
	t.Helper()
	var n int
	if err := st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM held_actions`).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	return n
}

// ---- PROJ-21 across a rotation, through the real handlers ----

// rotSessions is the session-host port: every session the test starts runs,
// Interrupt counts its Escs.
type rotSessions struct {
	clock func() time.Time
	mu    sync.Mutex
	live  map[int64]bool
	escs  int
}

func (s *rotSessions) Live(_ context.Context, id int64) (handlers.LiveRun, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.live[id] {
		return handlers.LiveRun{}, false, nil
	}
	return handlers.LiveRun{SessionID: id, Run: 1, Agent: "claude", StartedAt: s.clock().Add(-time.Hour)}, true, nil
}

func (s *rotSessions) Deliver(context.Context, handlers.DeliverRequest) (handlers.DeliverResult, error) {
	return handlers.DeliverResult{}, os.ErrInvalid
}

func (s *rotSessions) Interrupt(context.Context, int64, uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.escs++
	return nil
}

func (s *rotSessions) Start(context.Context, handlers.StartRequest) (handlers.StartResult, error) {
	return handlers.StartResult{}, os.ErrInvalid
}

func (s *rotSessions) Stop(context.Context, int64) error { return os.ErrInvalid }

func (s *rotSessions) interrupts() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.escs
}

// proj21World is rotWorld with the real handlers on a workspace database,
// one running claude session on a workbench, and one phone (offering)
// holding the typing and the permissions grant.
type proj21World struct {
	*rotWorld
	db       *db.DB
	sessions *rotSessions
	sid      int64
	wb       int64
	ph       *hubtest.Phone
}

func newProj21World(t *testing.T) *proj21World {
	t.Helper()
	w := &proj21World{rotWorld: newRotWorld(t), db: db.OpenTestDB(t)}
	w.sessions = &rotSessions{clock: w.clock, live: map[int64]bool{}}
	handlers.Register(w.disp, handlers.Deps{DB: w.db, Store: w.st, Sessions: w.sessions, Clock: w.clock})
	w.ph = w.link(true)
	if err := w.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET typing_allowed = 1, permissions_allowed = 1 WHERE device_id = ? COLLATE NOCASE`, w.ph.ID().String())
		return err
	}); err != nil {
		t.Fatal(err)
	}
	wb, err := w.db.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w.wb = wb
	res, err := w.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'Ship it', '/tmp/acme', lower(hex(randomblob(16))))`, wb)
	if err != nil {
		t.Fatal(err)
	}
	w.sid, _ = res.LastInsertId()
	w.sessions.live[w.sid] = true
	w.cycle()
	w.takeKeybox(w.ph)
	return w
}

func (w *proj21World) permRequest() int64 {
	w.t.Helper()
	res, err := w.db.Exec(`INSERT INTO permission_requests
		(terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
		VALUES (?, ?, 'Bash', 'make test', 0, 'pending', ?)`, w.sid, w.wb, db.AgentStateStamp(w.clock().Add(-5*time.Second)))
	if err != nil {
		w.t.Fatal(err)
	}
	rid, _ := res.LastInsertId()
	return rid
}

// working writes the hooks' Working state, stamped a second ago.
func (w *proj21World) working() {
	w.t.Helper()
	if _, err := w.db.Exec(`UPDATE terminal_sessions SET agent_state = 'working', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(w.clock().Add(-time.Second)), w.sid); err != nil {
		w.t.Fatal(err)
	}
}

func (w *proj21World) answer(rid int64) uint64 {
	w.t.Helper()
	a := w.ph.NewAction("permission_answer")
	sid := strconv.FormatInt(w.sid, 10)
	a.EntityID = &sid
	req, _ := json.Marshal(rid)
	a.Params = map[string]json.RawMessage{"request_id": req, "behavior": json.RawMessage(`"allow"`)}
	seq, err := w.ph.Queue(a)
	if err != nil {
		w.t.Fatal(err)
	}
	return seq
}

func (w *proj21World) interrupt() uint64 {
	w.t.Helper()
	a := w.ph.NewAction("session_interrupt")
	sid := strconv.FormatInt(w.sid, 10)
	a.EntityID = &sid
	seq, err := w.ph.Queue(a)
	if err != nil {
		w.t.Fatal(err)
	}
	return seq
}

func (w *proj21World) row(rid int64) (status, decidedAt string) {
	w.t.Helper()
	var at sql.NullString
	if err := w.db.QueryRow(`SELECT status, decided_at FROM permission_requests WHERE id = ?`, rid).Scan(&status, &at); err != nil {
		w.t.Fatal(err)
	}
	return status, at.String
}

func echoReason(a wire.ActionRequest) string {
	if a.Reason == nil {
		return ""
	}
	return *a.Reason
}

// TestPermissionAnswerAcrossARotationAppliedOnce (F30, PROJ-21): an allow
// sealed in the old epoch, held behind a lost action across a rotation, is
// resealed in the new epoch on the hub's resend_from. The held copy decides
// the row by its compare-and-set once; the resealed copy is a repeat and
// decides nothing; a later answer to the same prompt gets not_pending.
func TestPermissionAnswerAcrossARotationAppliedOnce(t *testing.T) {
	w := newProj21World(t)
	w.advance(week - time.Minute) // the epoch is due in a minute
	rid := w.permRequest()
	lost, err := w.ph.Queue(w.ph.NewAction("test_noop")) // never reaches the relay
	if err != nil {
		t.Fatal(err)
	}
	seq := w.answer(rid)
	if err := w.ph.Send(seq); err != nil {
		t.Fatal(err)
	}
	w.advance(time.Minute)
	w.rotateIfDue(true)
	w.cycle()
	w.takeKeybox(w.ph) // the phone seals in epoch 2 now

	w.pass() // epoch 1 still retained: held behind the gap, resend_from asked
	if st, _ := w.row(rid); st != "pending" {
		t.Fatalf("row %s before the gap filled", st)
	}
	if _, err := w.ph.Sync(); err != nil { // resends lost and seq, resealed in epoch 2
		t.Fatal(err)
	}
	if !slices.Contains(w.ph.Resealed, seq) {
		t.Fatalf("resealed %v, want the answer %d resealed", w.ph.Resealed, seq)
	}
	w.pass()
	if _, err := w.ph.Sync(); err != nil {
		t.Fatal(err)
	}
	status, decided := w.row(rid)
	if status != "allowed" || w.ph.Echoes[seq].Status != wire.StatusApplied || w.ph.Echoes[lost].Status != wire.StatusApplied {
		t.Fatalf("row %s, echoes %+v / %+v", status, w.ph.Echoes[lost], w.ph.Echoes[seq])
	}

	// The resealed copy written again: a repeat, nothing decided again.
	if err := w.ph.WriteCopy(seq); err != nil {
		t.Fatal(err)
	}
	w.advance(time.Second)
	w.pass()
	if st, at := w.row(rid); st != "allowed" || at != decided {
		t.Fatalf("row %s at %s after the repeat, want allowed at %s", st, at, decided)
	}

	stale := w.answer(rid)
	if err := w.ph.Send(stale); err != nil {
		t.Fatal(err)
	}
	w.pass()
	if _, err := w.ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if e := w.ph.Echoes[stale]; e.Status != wire.StatusFailed || echoReason(e) != "not_pending" {
		t.Fatalf("stale answer echo %+v, want failed not_pending", e)
	}
}

// TestSessionInterruptAcrossARotationExpires (F30, PROJ-21): an Esc sealed
// before a rotation and read past its 120 s window is answered expired and
// types nothing; one sent in the new epoch within its window sends one Esc.
func TestSessionInterruptAcrossARotationExpires(t *testing.T) {
	w := newProj21World(t)
	w.advance(week - 3*time.Minute) // the epoch is due in three minutes
	late := w.interrupt()
	if err := w.ph.Send(late); err != nil {
		t.Fatal(err)
	}
	w.advance(3 * time.Minute)
	w.rotateIfDue(true)
	w.cycle()
	w.takeKeybox(w.ph)
	w.working()
	w.pass()
	if _, err := w.ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if e := w.ph.Echoes[late]; e.Status != wire.StatusExpired || echoReason(e) != "expired" {
		t.Fatalf("late interrupt echo %+v, want expired", e)
	}
	if n := w.sessions.interrupts(); n != 0 {
		t.Fatalf("%d Escs for an expired interrupt", n)
	}

	w.ack(w.ph, true)
	fresh := w.interrupt()
	if err := w.ph.Send(fresh); err != nil {
		t.Fatal(err)
	}
	w.working()
	w.pass()
	if _, err := w.ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if e := w.ph.Echoes[fresh]; e.Status != wire.StatusApplied || w.ph.EchoEpochs[fresh] != 2 {
		t.Fatalf("fresh interrupt echo %+v in epoch %d, want applied in 2", e, w.ph.EchoEpochs[fresh])
	}
	if n := w.sessions.interrupts(); n != 1 {
		t.Fatalf("%d Escs, want 1", n)
	}
}

package switcher_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// relayPhone links a phone over a pairing slot a minute from now (after
// relay_link_since): it has a relay id and no iCloud route, the link center
// recorded it as linked through a slot, and it reads the relay. pays is what
// the account lists for it.
func (w *world) relayPhone(pays bool) *hubtest.Phone {
	w.t.Helper()
	w.advance(time.Minute)
	ph := w.addPhone(pays)
	w.route(ph, false)
	w.slotLinked(ph)
	w.onRelay(ph)
	return ph
}

// slotLinked records ph in hub_meta relay_slot_links as the link center's
// confirm of a request that came through a pairing slot does.
func (w *world) slotLinked(ph *hubtest.Phone) {
	w.t.Helper()
	var row struct {
		Linked map[string]string `json:"linked"`
	}
	if raw, ok, err := w.st.Meta(state.MetaRelaySlotLinks); err != nil {
		w.t.Fatal(err)
	} else if ok {
		if err := json.Unmarshal([]byte(raw), &row); err != nil {
			w.t.Fatal(err)
		}
	}
	if row.Linked == nil {
		row.Linked = map[string]string{}
	}
	row.Linked[strings.ToUpper(ph.ID().String())] = ph.Device().LinkNonce
	b, err := json.Marshal(row)
	if err != nil {
		w.t.Fatal(err)
	}
	if err := w.st.SetMeta(state.MetaRelaySlotLinks, string(b)); err != nil {
		w.t.Fatal(err)
	}
}

// relayLinkCheck is the runtime's RelayLinkSoon and the Run that follows it:
// one PollOther, then a Step.
func (w *world) relayLinkCheck() {
	w.t.Helper()
	w.sw.RelayLinkSoon()
	w.sw.PollOther(w.ctx)
	if err := w.sw.Step(w.ctx); err != nil {
		w.t.Fatal(err)
	}
}

// accountReads is how many AccountPhones reads were made.
func (w *world) accountReads() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.reads
}

func (w *world) wantReads(n int) {
	w.t.Helper()
	if got := w.accountReads(); got != n {
		w.t.Fatalf("%d account reads, want %d", got, n)
	}
}

func (w *world) wantSwitchedBy(ph *hubtest.Phone) {
	w.t.Helper()
	if _, by, ok, err := w.sw.SwitchedAt(); err != nil || !ok || by != ph.ID().String() {
		w.t.Fatalf("switched_by %q %v %v, want %s", by, ok, err, ph.ID())
	}
}

func TestRelayLinkedPayingPhoneMovesTheHubToRelay(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		w.wantActive(transport.KindCloudKit)
		r := w.relayPhone(true)
		w.relayLinkCheck()
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r)
	})
}

// sinceStamp is relay_link_since as a start at now writes it: the second
// before now's whole second.
func sinceStamp(now time.Time) string {
	return strconv.FormatFloat(float64(now.Truncate(time.Second).Add(-time.Second).UnixNano())/1e9, 'f', -1, 64)
}

// A phone confirmed in the same second as the build's first start counts:
// the link center truncates linked_at to the second, so relay_link_since
// sits a second before the start's whole second.
func TestRelayLinkInTheStartSecondIsACandidate(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		if err := w.st.DeleteMeta(switcher.MetaRelayLinkSince); err != nil {
			t.Fatal(err)
		}
		w.advance(400 * time.Millisecond)
		w.rebuild(nil) // the first start of the build, mid-second
		ph := w.addPhone(true)
		w.route(ph, false)
		w.slotLinked(ph)
		w.onRelay(ph)
		// The link center's linked_at: the confirm's whole second.
		linked := float64(w.clock().Truncate(time.Second).UnixNano()) / 1e9
		err := w.st.WithTx(context.Background(), func(tx *sql.Tx) error {
			_, err := tx.Exec(`UPDATE devices SET linked_at = ? WHERE device_id = ?`, linked, ph.Device().ID)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		w.relayLinkCheck()
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(ph)
	})
}

// Q5: a phone linked over a pairing slot before the build that carries the
// check never moves the Mac by itself; relay_link_since is written once.
func TestRelayLinkBeforeTheUpdateIsNoCandidate(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		start := w.clock()
		want := sinceStamp(start)
		if v, ok, err := w.st.Meta(switcher.MetaRelayLinkSince); err != nil || !ok || v != want {
			t.Fatalf("relay_link_since %q %v %v, want %q", v, ok, err, want)
		}
		// The phone linked while the earlier build ran: the new build's first
		// start comes after it.
		w.relayPhone(true)
		if err := w.st.DeleteMeta(switcher.MetaRelayLinkSince); err != nil {
			t.Fatal(err)
		}
		w.advance(time.Hour)
		w.rebuild(nil)
		since, _, err := w.st.Meta(switcher.MetaRelayLinkSince)
		if err != nil {
			t.Fatal(err)
		}
		w.relayLinkCheck()
		w.advance(switcher.NoPayerPoll)
		w.sw.PollOther(w.ctx)
		w.wantActive(transport.KindCloudKit)
		w.wantReads(0)
		// A restart never rewrites it.
		w.advance(time.Hour)
		w.rebuild(nil)
		if v, _, _ := w.st.Meta(switcher.MetaRelayLinkSince); v != since {
			t.Fatalf("relay_link_since %q after a restart, want %q", v, since)
		}
		w.relayLinkCheck()
		w.wantActive(transport.KindCloudKit)
		w.wantReads(0)
	})
}

// F9: a read that failed, was not made afresh, hung past the old-side
// timeout or does not list the phone moves nothing; every next RelayLinkSoon
// reads again and a paying answer then moves the hub. A read that answered
// (or failed) uses up the NoPayerPoll slot, so a poll without a kick reads
// nothing; a read that was not made afresh is no read and the next poll
// tries again, as G2 does.
func TestRelayLinkWaitsOnAnUnknownRead(t *testing.T) {
	for _, how := range []string{"error", "not_fresh", "hang", "not_listed"} {
		t.Run(how, func(t *testing.T) {
			eachFlavourFor(t, hangingIf(how == "hang"), func(t *testing.T, w *world) {
				r := w.relayPhone(true)
				set := func(on bool) {
					w.mu.Lock()
					defer w.mu.Unlock()
					switch how {
					case "error":
						w.payErr = nil
						if on {
							w.payErr = errors.New("relay unreachable")
						}
					case "not_fresh":
						w.notFresh = on
					case "hang":
						w.payHang = on
					case "not_listed":
						w.gone = map[string]bool{strings.ToUpper(r.ID().String()): on}
					}
				}
				set(true)
				w.relayLinkCheck()
				w.wantActive(transport.KindCloudKit)
				w.wantReads(1)
				w.advance(switcher.OtherPoll)
				w.sw.PollOther(w.ctx) // no kick
				if how == "not_fresh" {
					w.wantReads(2)
				} else {
					w.wantReads(1)
					w.relayLinkCheck()
				}
				w.wantActive(transport.KindCloudKit)
				w.wantReads(2)
				set(false)
				w.relayLinkCheck()
				w.wantReads(3)
				w.wantActive(transport.KindRelay)
				w.wantSwitchedBy(r)
			})
		})
	}
}

// F5: listed as not paying moves nothing; the candidate stays, so a renewal
// moves the hub later.
func TestRelayLinkNotPayingStays(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		r := w.relayPhone(false)
		w.relayLinkCheck()
		w.wantActive(transport.KindCloudKit)
		w.wantReads(1)
		w.setPaying(r, true)
		w.relayLinkCheck()
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r)
	})
}

// F6/F10: a switch after the phone linked (here a person's move back to
// iCloud) is the later decision: the phone is no candidate any more.
func TestRelayLinkAfterALaterSwitchIsNoCandidate(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.route(a, true)
		r := w.relayPhone(false)
		w.advance(time.Minute)
		w.moveTo(a, wire.TransportRelay)
		w.advance(time.Minute)
		w.moveTo(a, wire.TransportCloudKit)
		w.advance(switcher.AntiFlap)
		w.setPaying(r, true)
		n := w.accountReads()
		w.relayLinkCheck()
		w.advance(switcher.NoPayerPoll)
		w.sw.PollOther(w.ctx)
		w.wantReads(n)
		w.wantActive(transport.KindCloudKit)
	})
}

// A slot link confirmed in the same second as a recorded switch counts: the
// link center truncates linked_at to the second, so the switched_at floor is
// compared at the second too (relayLinkSince).
func TestRelayLinkInTheSwitchSecondIsACandidate(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.route(a, true)
		w.advance(time.Minute)
		w.moveTo(a, wire.TransportRelay)
		w.advance(time.Minute + 400*time.Millisecond)
		w.moveTo(a, wire.TransportCloudKit)
		at, _, ok, err := w.sw.SwitchedAt()
		if err != nil || !ok {
			t.Fatalf("switched_at %v %v", ok, err)
		}
		r := w.addPhone(true)
		w.route(r, false)
		w.slotLinked(r)
		w.onRelay(r)
		// The link center's linked_at: the switch's whole second.
		linked := float64(at.Truncate(time.Second).UnixNano()) / 1e9
		err = w.st.WithTx(context.Background(), func(tx *sql.Tx) error {
			_, err := tx.Exec(`UPDATE devices SET linked_at = ? WHERE device_id = ?`, linked, r.Device().ID)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		w.advance(switcher.AntiFlap)
		w.relayLinkCheck()
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r)
	})
}

// F10: within AntiFlap of the last switch the check reads paying, accept
// answers too_soon, nothing is sent to any phone, and the check tries again
// once the wait is over, without waiting out NoPayerPoll and without a kick.
// A RelayLinkSoon during the wait does not bypass it.
func TestRelayLinkRespectsAntiFlap(t *testing.T) {
	for _, kick := range []bool{false, true} {
		t.Run("kick_in_the_wait="+strconv.FormatBool(kick), func(t *testing.T) {
			eachFlavour(t, func(t *testing.T, w *world) { relayLinkAntiFlap(t, w, kick) })
		})
	}
}

func relayLinkAntiFlap(t *testing.T, w *world, kick bool) {
	{
		a := w.addPhone(true)
		w.route(a, true)
		w.moveTo(a, wire.TransportRelay)
		w.moveTo(a, wire.TransportCloudKit) // switched_at = now
		w.advance(time.Minute)
		r := w.relayPhone(true) // two minutes after the switch
		for _, ph := range []*hubtest.Phone{a, r} {
			if _, err := ph.Sync(); err != nil {
				t.Fatal(err)
			}
		}
		aCtl, rCtl := len(a.Controls), len(r.Controls)
		e := w.epoch()
		n := w.accountReads()

		w.relayLinkCheck()
		w.wantReads(n + 1)
		w.wantActive(transport.KindCloudKit)
		if w.sw.Pending() {
			t.Fatal("a too_soon left a switch pending")
		}
		retry := switcher.AntiFlap - 2*time.Minute
		if retry >= switcher.NoPayerPoll {
			t.Fatalf("the retry %v must come before NoPayerPoll", retry)
		}
		w.advance(retry - time.Second)
		if kick {
			w.relayLinkCheck() // a kick inside the wait reads nothing
		}
		w.settle(a, r)
		w.wantReads(n + 1)
		w.wantActive(transport.KindCloudKit)
		if len(a.Controls) != aCtl || len(r.Controls) != rCtl || w.epoch() != e {
			t.Fatalf("controls a %d→%d, r %d→%d, epoch %d→%d: something was sent", aCtl, len(a.Controls), rCtl, len(r.Controls), e, w.epoch())
		}

		w.advance(time.Second)
		w.sw.PollOther(w.ctx) // no kick
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantReads(n + 2)
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r)
	}
}

// F10: the check reads nothing while a switch is pending or an ask waits for
// the Step; once the Step decided it, the next check reads.
func TestRelayLinkSkipsWhilePendingOrAsked(t *testing.T) {
	t.Run("pending", func(t *testing.T) {
		eachFlavour(t, func(t *testing.T, w *world) {
			w.relayPhone(true)
			w.sw.RelayLinkSoon()
			w.sw.PollOther(w.ctx) // accepted, not carried out yet
			w.wantReads(1)
			if !w.sw.Pending() {
				t.Fatal("no switch pending")
			}
			w.sw.RelayLinkSoon()
			w.sw.PollOther(w.ctx)
			w.wantReads(1)
			if err := w.sw.Step(w.ctx); err != nil {
				t.Fatal(err)
			}
			w.wantActive(transport.KindRelay)
		})
	})
	t.Run("asked", func(t *testing.T) {
		eachFlavour(t, func(t *testing.T, w *world) {
			a := w.addPhone(false)
			w.route(a, true)
			r := w.relayPhone(true)
			w.ask(a, wire.TransportRelay)
			if _, err := w.sw.ActiveProcessor().Pass(w.ctx); err != nil {
				t.Fatal(err)
			}
			w.sw.RelayLinkSoon()
			w.sw.PollOther(w.ctx)
			w.wantReads(0)
			if err := w.sw.Step(w.ctx); err != nil { // a does not pay: refused
				t.Fatal(err)
			}
			w.wantActive(transport.KindCloudKit)
			w.wantReads(0)
			w.sw.PollOther(w.ctx) // the RelayLinkSoon still stands
			w.wantReads(1)
			if err := w.sw.Step(w.ctx); err != nil {
				t.Fatal(err)
			}
			w.wantActive(transport.KindRelay)
			w.wantSwitchedBy(r)
		})
	})
}

// F4: a crash after the confirm, and a crash after the accept before the
// Step: one switch, one rotation.
func TestRelayLinkSurvivesRestart(t *testing.T) {
	t.Run("after_confirm", func(t *testing.T) {
		eachFlavour(t, func(t *testing.T, w *world) {
			r := w.relayPhone(false)
			w.sw.PollOther(w.ctx) // the first check after the start reads
			w.wantReads(1)
			w.setPaying(r, true)
			w.sw.PollOther(w.ctx) // inside NoPayerPoll, no kick: no read
			w.wantReads(1)
			w.rebuild(nil)
			w.sw.PollOther(w.ctx) // no kick: the first check after the start
			if err := w.sw.Step(w.ctx); err != nil {
				t.Fatal(err)
			}
			w.wantReads(2)
			w.wantActive(transport.KindRelay)
			w.wantSwitchedBy(r)
		})
	})
	t.Run("after_accept", func(t *testing.T) {
		eachFlavour(t, func(t *testing.T, w *world) {
			r := w.relayPhone(true)
			e := w.epoch()
			w.sw.PollOther(w.ctx) // accepted; the crash comes before the Step
			if !w.sw.Pending() {
				t.Fatal("no switch pending")
			}
			w.rebuild(nil)
			if err := w.sw.Step(w.ctx); err != nil {
				t.Fatal(err)
			}
			w.wantActive(transport.KindRelay)
			w.wantSwitchedBy(r)
			if w.epoch() != e+1 {
				t.Fatalf("epoch %d, want one rotation from %d", w.epoch(), e)
			}
			n := w.accountReads()
			w.relayLinkCheck()
			w.wantReads(n)
			if w.epoch() != e+1 {
				t.Fatalf("epoch %d after another check, want %d", w.epoch(), e+1)
			}
		})
	})
}

// A phone linked over iCloud (it has an iCloud route) is no candidate, even
// when it pays and linked after relay_link_since: it can follow the hub
// wherever it runs, so its link moves nothing.
func TestRelayLinkICloudLinkedPhoneIsNoCandidate(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		w.advance(time.Minute)
		a := w.addPhone(true)
		w.route(a, true)
		w.slotLinked(a) // even with a slot mark
		w.relayLinkCheck()
		w.wantReads(0)
		w.wantActive(transport.KindCloudKit)
	})
}

// The codex case: a private CloudKit link whose owner could not be read
// carries no iCloud user, like a slot link, and has a relay id the account
// lists as paying. Without the link center's slot record it is no candidate.
func TestRelayLinkACloudKitLinkWithAnEmptyOwnerIsNoCandidate(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		w.advance(time.Minute)
		w.addPhone(true) // no route, a relay id, paying; never through a slot
		w.relayLinkCheck()
		w.wantReads(0)
		w.wantActive(transport.KindCloudKit)
	})
}

// A slot mark names the link it was written for: a re-link by a writer that
// never updated the record (the row now carries another link nonce) leaves a
// mark that does not count, both in the candidates and at the accept.
func TestRelayLinkAStaleSlotMarkIsNoCandidate(t *testing.T) {
	relink := func(w *world, ph *hubtest.Phone) {
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
			_, err := tx.Exec(`UPDATE devices SET link_nonce = 'relinked' WHERE device_id = ? COLLATE NOCASE`, ph.ID().String())
			return err
		}); err != nil {
			w.t.Fatal(err)
		}
	}
	t.Run("before_the_read", func(t *testing.T) {
		eachFlavour(t, func(t *testing.T, w *world) {
			r := w.relayPhone(true)
			relink(w, r)
			w.relayLinkCheck()
			w.wantReads(0)
			w.wantActive(transport.KindCloudKit)
		})
	})
	t.Run("mark_for_another_link_during_the_read", func(t *testing.T) {
		eachFlavour(t, func(t *testing.T, w *world) {
			r := w.relayPhone(true)
			w.accountReadHook(func() {
				row := `{"linked":{"` + strings.ToUpper(r.ID().String()) + `":"another-link"}}`
				if err := w.st.SetMeta(state.MetaRelaySlotLinks, row); err != nil {
					t.Error(err)
				}
			})
			w.relayLinkCheck()
			w.wantReads(1)
			w.wantActive(transport.KindCloudKit)
			if w.sw.Pending() {
				t.Fatal("a switch by a stale slot mark is pending")
			}
		})
	})
}

// A relay_slot_links row that cannot be decoded reads as no candidate (the
// store class is logged), and the check works again once it is whole.
func TestRelayLinkACorruptSlotRowIsNoCandidate(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		r := w.relayPhone(true)
		good, _, err := w.st.Meta(state.MetaRelaySlotLinks)
		if err != nil {
			t.Fatal(err)
		}
		if err := w.st.SetMeta(state.MetaRelaySlotLinks, "{"); err != nil {
			t.Fatal(err)
		}
		w.relayLinkCheck()
		w.wantReads(0)
		w.wantActive(transport.KindCloudKit)
		if err := w.st.SetMeta(state.MetaRelaySlotLinks, good); err != nil {
			t.Fatal(err)
		}
		w.relayLinkCheck()
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r)
	})
}

// A slot mark that goes during the account read (the phone re-linked over
// CloudKit meanwhile) is checked again at the accept: nothing moves.
func TestRelayLinkASlotMarkGoneDuringTheReadMovesNothing(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		w.relayPhone(true)
		w.accountReadHook(func() {
			if err := w.st.DeleteMeta(state.MetaRelaySlotLinks); err != nil {
				t.Error(err)
			}
		})
		w.relayLinkCheck()
		w.wantReads(1)
		w.wantActive(transport.KindCloudKit)
		if w.sw.Pending() {
			t.Fatal("a switch by a phone no longer slot-linked is pending")
		}
	})
}

// F8: two relay-linked paying phones move the hub once, by the first linked.
func TestTwoRelayLinksSwitchOnce(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		r1 := w.relayPhone(true)
		w.relayPhone(true)
		e := w.epoch()
		w.relayLinkCheck()
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r1)
		if w.epoch() != e+1 {
			t.Fatalf("epoch %d, want one rotation from %d", w.epoch(), e)
		}
		n := w.accountReads()
		w.relayLinkCheck()
		w.wantReads(n)
		if w.epoch() != e+1 {
			t.Fatalf("epoch %d after another check, want %d", w.epoch(), e+1)
		}
	})
}

// F11: a phone unlinked before the check is no candidate.
func TestRelayLinkUnlinkedPhoneIsNoCandidate(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		r := w.relayPhone(true)
		if err := w.center.Unlink(r.ID().String()); err != nil {
			t.Fatal(err)
		}
		w.relayLinkCheck()
		w.wantReads(0)
		w.wantActive(transport.KindCloudKit)
	})
}

// F5 on a Mac that stays up for days: without a kick, at most one read per
// NoPayerPoll, never one per OtherPoll.
func TestRelayLinkReadsAtMostOncePerPollWithoutAKick(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		w.relayPhone(false)
		for range 10 {
			w.advance(switcher.OtherPoll)
			w.sw.PollOther(w.ctx)
		}
		w.wantReads(1)
		w.advance(switcher.NoPayerPoll)
		w.sw.PollOther(w.ctx)
		w.wantReads(2)
		w.wantActive(transport.KindCloudKit)
	})
}

// §3: the Mac's other phones hear of the move as on any switch to the relay.
func TestRelayLinkSwitchNoticesOtherPhones(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		unordered, ordered, payer := w.addPhone(false), w.addPhone(false), w.addPhone(true)
		for _, ph := range []*hubtest.Phone{unordered, ordered, payer} {
			w.route(ph, true)
		}
		w.act(ordered)
		w.settle(unordered, ordered, payer) // ordered is ordered now
		r := w.relayPhone(true)
		w.relayLinkCheck()
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r)
		w.settle(unordered, ordered, payer, r)
		if n := count(ordered, wire.ControlHubOnRelay); n != 1 {
			t.Fatalf("%d hub_on_relay for the ordered free phone", n)
		}
		for name, ph := range map[string]*hubtest.Phone{"unordered": unordered, "payer": payer} {
			got := switched(ph)
			if len(got) != 1 || *got[0].Target != wire.TransportRelay {
				t.Fatalf("%s: transport_switched %+v", name, got)
			}
		}
		w.follow(payer)
		w.settle(payer, r)
		if m, ok := w.marker(payer, w.relay, ""); !ok || *m.Target != wire.TransportRelay {
			t.Fatalf("relay marker %+v %v", m, ok)
		}
	})
}

// accountReadHook makes hook run inside every AccountPhones read, after the
// relay answered and before the answer reaches the switcher (a restart with
// the hook in the config).
func (w *world) accountReadHook(hook func()) {
	w.t.Helper()
	w.rebuild(func(c *switcher.Config) {
		read := c.AccountPhones
		c.AccountPhones = func(ctx context.Context) ([]switcher.AccountPhone, error) {
			phones, err := read(ctx)
			hook()
			return phones, err
		}
	})
}

// F11 during the read: the phone unlinked while the account was read is no
// candidate any more by the time the switch would be accepted.
func TestRelayLinkUnlinkDuringTheReadMovesNothing(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		r := w.relayPhone(true)
		w.accountReadHook(func() {
			if err := w.center.Unlink(r.ID().String()); err != nil {
				t.Error(err)
			}
		})
		w.relayLinkCheck()
		w.wantReads(1)
		w.wantActive(transport.KindCloudKit)
		if w.sw.Pending() {
			t.Fatal("a switch by an unlinked phone is pending")
		}
	})
}

// A person's ask read during the account read goes first: the check defers
// to the Step and reads again at the next poll, without a kick.
func TestRelayLinkAnAskDuringTheReadGoesFirst(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(false)
		w.route(a, true)
		r := w.relayPhone(true)
		asked := false
		w.accountReadHook(func() {
			if asked {
				return
			}
			asked = true
			w.ask(a, wire.TransportRelay)
			if _, err := w.sw.ActiveProcessor().Pass(w.ctx); err != nil {
				t.Error(err)
			}
		})
		w.sw.RelayLinkSoon()
		w.sw.PollOther(w.ctx)
		w.wantReads(1)
		if w.sw.Pending() {
			t.Fatal("the check accepted over a waiting ask")
		}
		if err := w.sw.Step(w.ctx); err != nil { // a does not pay: refused
			t.Fatal(err)
		}
		w.wantActive(transport.KindCloudKit)
		w.sw.PollOther(w.ctx) // no kick: the deferred check reads again
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantReads(2)
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r)
	})
}

// A relay_link_since that cannot be read moves nothing and is never mistaken
// for "no limit".
func TestRelayLinkUnreadableSinceMovesNothing(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		if err := w.st.SetMeta(switcher.MetaRelayLinkSince, "not a time"); err != nil {
			t.Fatal(err)
		}
		w.relayPhone(true)
		w.relayLinkCheck()
		w.wantReads(0)
		w.wantActive(transport.KindCloudKit)
	})
}

// A relay_link_since stamped while the Mac's clock ran ahead is pulled back
// to the second before now at the next check, so a phone that links
// afterwards counts.
func TestRelayLinkSinceInTheFutureIsPulledBack(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		now := w.clock()
		ahead := strconv.FormatFloat(float64(now.Add(time.Hour).UnixNano())/1e9, 'f', -1, 64)
		if err := w.st.SetMeta(switcher.MetaRelayLinkSince, ahead); err != nil {
			t.Fatal(err)
		}
		w.relayLinkCheck() // no candidate yet; the stamp comes back to now
		want := sinceStamp(now)
		if v, _, _ := w.st.Meta(switcher.MetaRelayLinkSince); v != want {
			t.Fatalf("relay_link_since %q, want %q (the second before now)", v, want)
		}
		r := w.relayPhone(true) // a minute later, still before the old stamp
		w.relayLinkCheck()
		w.wantActive(transport.KindRelay)
		w.wantSwitchedBy(r)
	})
}

// A relay_link_since that New cannot write never stops the hub: the key
// stays unset and the check stays off.
func TestRelayLinkSinceWriteFailureLeavesTheCheckOff(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		if err := w.st.DeleteMeta(switcher.MetaRelayLinkSince); err != nil {
			t.Fatal(err)
		}
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
			_, err := tx.Exec(`CREATE TRIGGER refuse_relay_link_since BEFORE INSERT ON hub_meta
				WHEN NEW.key = 'relay_link_since' BEGIN SELECT RAISE(ABORT, 'refused'); END`)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		w.rebuild(nil) // New does not fail
		if _, ok, err := w.st.Meta(switcher.MetaRelayLinkSince); err != nil || ok {
			t.Fatalf("relay_link_since set %v (%v)", ok, err)
		}
		w.relayPhone(true)
		w.relayLinkCheck()
		w.wantReads(0)
		w.wantActive(transport.KindCloudKit)
	})
}

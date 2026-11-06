package switcher

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Nothing in a processor's pass reads the relay (board #1562): a hung read
// there burned the pass's context, so the record stayed unread, the next pass
// met it first, and every mailbox behind it starved. What needs the account is
// recorded in the pass and decided by the Step, the same way a lapse is
// (entitlement.go): a phone's transport_switch toward the relay (not_paying,
// too_soon, accepted or told where the hub runs) and the answer to a phone that
// wrote on the standby transport while the hub is on the relay (hub_on_relay or
// transport_switched). A phone hears what it heard before, a moment later.
//
// The asks wait in hub_meta in the order the passes read them, so a restart
// loses none and the last accepted request still wins: while any ask waits, a
// request toward CloudKit (which needs no read) waits behind it instead of
// being overtaken. The Step decides them all first thing over one account read
// bounded by the old-side timeout, so a press behind a hung read waits at most
// that long. As before, a read that failed or timed out counts as paying. A
// host closing during the read decides nothing: the asks stay for the next run.
//
// Writers of the switch record meanwhile, all through acceptTx under s.mu: the
// Step's decisions here, a request toward CloudKit with no ask waiting (in a
// pass), rule 16's lapse (decided right after the asks in the same Step, so it
// supersedes them as it always did) and G2's poll, which skips its tick while
// an ask waits: its own move must not be replaced by a request read before it.

// metaAsks is the waiting asks (a JSON list, oldest first).
const metaAsks = "switch_asks"

// waitingAsk is one thing the Step owes a phone: a request (Target) or, with
// Stale, the answer to a write on the standby transport. Read is the transport
// it was read on, where a rejection or a stale answer goes. Link is the phone's
// link nonce then: a phone re-linked since never hears it, and the hub never
// acts on it.
type waitingAsk struct {
	Read   transport.Kind `json:"read"`
	Device string         `json:"device"`
	Link   string         `json:"link,omitempty"`
	Target transport.Kind `json:"target,omitempty"`
	Stale  bool           `json:"stale,omitempty"`
}

// loadAsks reads the waiting asks. A list that does not decode is dropped and
// logged: the phones repeat their requests, and a switch is never stopped on it.
func loadAsks(q func(string) (string, bool, error)) ([]waitingAsk, error) {
	raw, ok, err := q(metaAsks)
	if err != nil || !ok || raw == "" {
		return nil, err
	}
	return decodeAsks(raw), nil
}

func decodeAsks(raw string) []waitingAsk {
	var asks []waitingAsk
	if json.Unmarshal([]byte(raw), &asks) != nil {
		log.Printf("hub: switch: the waiting requests are unreadable: dropped")
		return nil
	}
	return asks
}

func asksTx(tx *sql.Tx) ([]waitingAsk, error) {
	return loadAsks(func(k string) (string, bool, error) { return state.MetaTx(tx, k) })
}

func saveAsksTx(tx *sql.Tx, asks []waitingAsk) error {
	if len(asks) == 0 {
		return state.SetMetaTx(tx, metaAsks, "")
	}
	raw, err := json.Marshal(asks)
	if err != nil {
		return err
	}
	return state.SetMetaTx(tx, metaAsks, string(raw))
}

// dropHeadTx removes the oldest ask (only the Step removes, so it is the one
// the Step read; the passes append behind it).
func dropHeadTx(tx *sql.Tx) error {
	asks, err := asksTx(tx)
	if err != nil || len(asks) == 0 {
		return err
	}
	return saveAsksTx(tx, asks[1:])
}

// dropHead removes the oldest ask on its own (decided with nothing to commit).
func (s *Switcher) dropHead() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.c.Store.WithTx(context.Background(), dropHeadTx)
}

// recordAsk adds a to the waiting asks and kicks the Step. It runs in a pass:
// it reads nothing from the relay. A phone no longer linked asks nothing.
func (s *Switcher) recordAsk(a waitingAsk) error {
	dev, linked, err := s.c.Store.Device(a.Device)
	if err != nil || !linked {
		return err
	}
	a.Link = dev.LinkNonce
	s.mu.Lock()
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		asks, err := asksTx(tx)
		if err != nil {
			return err
		}
		return saveAsksTx(tx, append(asks, a))
	})
	s.mu.Unlock()
	if err != nil {
		return err
	}
	s.resetBackoff()
	s.Kick()
	return nil
}

// asksWaiting reports whether the Step owes a decision.
func (s *Switcher) asksWaiting() bool {
	raw, ok, err := s.c.Store.Meta(metaAsks)
	return err == nil && ok && raw != ""
}

// requestToCloudKit is a person's request toward CloudKit: accepted at once, or
// behind the asks waiting so the order the passes read holds. accepted false
// with no ask recorded means the hub is on (or heading to) CloudKit.
func (s *Switcher) requestToCloudKit(k transport.Kind, from string) (accepted, behind bool, err error) {
	dev, linked, err := s.c.Store.Device(from)
	if err != nil {
		return false, false, err
	}
	link := ""
	if linked {
		link = dev.LinkNonce
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		accepted, behind = false, false
		asks, err := asksTx(tx)
		if err != nil {
			return err
		}
		if len(asks) > 0 {
			behind = true
			return saveAsksTx(tx, append(asks, waitingAsk{Read: k, Device: from, Link: link, Target: transport.KindCloudKit}))
		}
		accepted, err = s.acceptTx(tx, from, transport.KindCloudKit, now)
		return err
	})
	return accepted, behind, err
}

// accountRead is the one account read of a run of decisions.
type accountRead struct {
	done   bool
	known  bool // the read answered
	paying map[string]bool
}

// follows reports whether device can follow the hub onto the relay: the relay
// account lists it as paying; unknown (no Paying, an unreadable or unanswered
// account read) counts as able, so no phone is refused or told it cannot follow
// by mistake. An error means the host is closing, and nothing is decided.
func (s *Switcher) follows(ctx context.Context, read *accountRead, device string) (bool, error) {
	if s.c.Paying == nil {
		return true, nil
	}
	if !read.done {
		paying, err := s.readPaying(ctx)
		if cerr := ctx.Err(); cerr != nil {
			return false, cerr
		}
		read.done = true
		if err != nil {
			log.Printf("hub: switch: the relay account is unreadable (%s): the phone counts as paying", errClass(err))
		} else {
			read.known, read.paying = true, paying
		}
	}
	if !read.known {
		return true, nil
	}
	return read.paying[canonical(device)], nil
}

// decideAsks decides the waiting asks, oldest first, until none is left, the
// host closes or the store fails (what is left waits for the next Step). Called
// from a Step only.
func (s *Switcher) decideAsks(ctx context.Context) {
	var read accountRead
	for {
		asks, err := loadAsks(s.c.Store.Meta)
		if err == nil && len(asks) == 0 {
			return
		}
		if err == nil {
			err = s.decideAsk(ctx, asks[0], &read)
		}
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("hub: switch: a waiting request stays for the next step (%s)", errClass(err))
			}
			return
		}
	}
}

func (s *Switcher) decideAsk(ctx context.Context, a waitingAsk, read *accountRead) error {
	dev, linked, err := s.c.Store.Device(a.Device)
	if err != nil {
		return err
	}
	if !linked || dev.LinkNonce != a.Link {
		return s.dropHead()
	}
	if a.Stale {
		return s.decideStale(ctx, a, dev, read)
	}
	if a.Target == transport.KindRelay {
		follows, err := s.follows(ctx, read, dev.ID)
		if err != nil {
			return err
		}
		if !follows {
			return s.answerAsk(a, (&actions.SwitchRejected{Reason: wire.SwitchNotPaying}).Control(), 0)
		}
		// A lapsed phone that pays again (the account read lists it) is lapsed
		// no more, whether or not the hub moves.
		if dev.RelayLapsedAt != nil && read.paying[canonical(dev.ID)] {
			s.endLapse(ctx, dev.ID)
		}
	}
	return s.acceptAsk(a)
}

// acceptAsk is what Request did after its check: an accepted request is
// recorded with the ask's removal in one transaction; one for where the hub
// heads is told where it runs (a crash before the removal tells it twice, which
// the phone takes as the same answer).
func (s *Switcher) acceptAsk(a waitingAsk) error {
	now := s.now()
	accepted := false
	s.mu.Lock()
	err := s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		if accepted, err = s.acceptTx(tx, a.Device, a.Target, now); err != nil || !accepted {
			return err
		}
		return dropHeadTx(tx)
	})
	s.mu.Unlock()
	var rej *actions.SwitchRejected
	if errors.As(err, &rej) {
		return s.answerAsk(a, rej.Control(), 0)
	}
	if err != nil {
		return err
	}
	if !accepted {
		s.answerWhereItRuns(a.Device)
		s.answersQueued = true
		return s.dropHead()
	}
	log.Printf("hub: transport switch to %s accepted", a.Target)
	s.resetBackoff()
	s.Kick()
	return nil
}

// decideStale is the Step's half of Stale: the answer the phone is owed now.
func (s *Switcher) decideStale(ctx context.Context, a waitingAsk, dev state.Device, read *accountRead) error {
	active := s.activeKind()
	if active == a.Read {
		return s.dropHead()
	}
	follows := true
	if active == transport.KindRelay {
		var err error
		if follows, err = s.follows(ctx, read, dev.ID); err != nil {
			return err
		}
	}
	c, epoch, ok, err := s.staleAnswer(dev, follows)
	if err != nil {
		log.Printf("hub: device %s wrote on the standby transport: no answer (%s)", canonical(dev.ID), errClass(err))
		return s.dropHead()
	}
	if !ok {
		return s.dropHead()
	}
	return s.answerAsk(a, c, epoch)
}

// answerAsk queues c for the phone on the transport the ask was read on,
// removing the ask in the same transaction. A control that cannot be sealed is
// logged and the ask dropped, as an answer that cannot be made always was: the
// phone asks again, and no phone behind it waits on this one.
func (s *Switcher) answerAsk(a waitingAsk, c wire.Control, epoch uint32) error {
	var row *state.Control
	if p := s.procs[a.Read]; p != nil {
		sealed, ok, err := p.SealControlFor(a.Device, c, epoch)
		switch {
		case err != nil:
			log.Printf("hub: switch: a %s does not seal (%s): skipped for that phone", c.Kind, errClass(err))
		case ok:
			row = &sealed
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	err := s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		if row != nil {
			if err := state.Enqueue(tx, *row); err != nil {
				return err
			}
		}
		return dropHeadTx(tx)
	})
	if err != nil {
		return err
	}
	if row != nil {
		s.answersQueued = true
		log.Printf("hub: device %s: answered %s on %s", canonical(a.Device), c.Kind, a.Read)
	}
	return nil
}

// flushAnswers writes the answers a Step queued on the active transport without
// waiting for its next pass (bounded; what fails stays queued for that pass). The
// standby side's queue is written by the PollOther that follows every Step.
func (s *Switcher) flushAnswers(ctx context.Context) {
	if !s.answersQueued {
		return
	}
	s.answersQueued = false
	k := s.activeKind()
	p := s.procs[k]
	if p == nil {
		return
	}
	fctx, cancel := context.WithTimeout(ctx, s.oldSide())
	defer cancel()
	if _, _, err := p.FlushControls(fctx); err != nil {
		log.Printf("hub: switch: the answers on %s wait (%s)", k, errClass(err))
	}
}

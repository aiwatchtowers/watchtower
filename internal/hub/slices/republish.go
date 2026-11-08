package slices

import (
	"log"
	"os"
	"time"

	"watchtower/internal/hub/secure"
)

// The republish a rotation starts (relay client Phase 5, "Measuring the
// cost"): every rotation wipes the slice hashes (state.WipeSliceHashes), so
// the cycles after it reseal the whole window under the new epoch. The
// publisher counts what those cycles upload and logs one content-free line
// when the wiped kinds are all published, or when the next wipe cuts it
// short:
//
//	hub: rotation republish: complete|resumed|interrupted, N records, B asset bytes, E envelope bytes, D s
//
// N is the records of the wiped kinds the transport accepted, B the sizes of
// their sealed asset files, E the sizes of their sealed envelopes (B + E is
// the hub's upload; B alone is a lower bound of it), D the whole seconds
// since the publisher saw the wipe. Numbers only: no record name, wire name,
// hub or phone id. The line is an instrument, not the measurement.
//
// A wipe is seen as a new epoch at a kind's publish (each rotation wipes in
// its own transaction), or, at a hub's first publish, as rows whose hash is
// empty. Kept in memory under cycleMu, so a restart forgets the counts so
// far: a republish found on the first publish with some rows already hashed
// again (a hub restarted part way through) counts only the rest and ends
// "resumed", never "complete". One with every row still wiped (the hub
// stopped before its publisher ran, or an offline rotation) is whole, and
// ends "complete".
type republish struct {
	pending       map[Kind]bool // wiped kinds not yet published to the end
	resumed       bool          // part of it was published before a restart
	records       int
	assetBytes    int64
	envelopeBytes int64
	since         time.Time // monotonic
}

// trackEpoch is told the epoch a kind's publish read. On the publisher's
// first read, or on a new epoch, it reads which kinds hold wiped rows; a new
// epoch first ends the republish still running as interrupted.
func (p *Publisher) trackEpoch(epoch uint32) {
	if p.repEpoch == epoch {
		return
	}
	first := p.repEpoch == 0
	if p.rep != nil {
		p.rep.log("interrupted", p.mono())
		p.rep = nil
	}
	p.repEpoch = epoch
	pending := map[Kind]bool{}
	hashed := false
	for _, k := range p.sourceKinds() {
		known, err := p.c.Store.SliceHashes(string(k))
		if err != nil {
			// Not counted: the line is an instrument, publishing goes on.
			log.Printf("hub slices: rotation republish not counted (%s)", errClass(err))
			return
		}
		for _, r := range known {
			if r.Hash == "" {
				pending[k] = true
			} else {
				hashed = true
			}
		}
	}
	if len(pending) > 0 {
		p.rep = &republish{pending: pending, resumed: first && hashed, since: p.mono()}
	}
}

// countSaved adds the records of kind k the transport accepted while k is
// one the republish waits for.
func (p *Publisher) countSaved(k Kind, accepted []secure.Record) {
	if p.rep == nil || !p.rep.pending[k] {
		return
	}
	p.rep.records += len(accepted)
	for _, rec := range accepted {
		p.rep.envelopeBytes += int64(len(rec.Envelope()))
		if rec.AssetPath() == "" {
			continue
		}
		if fi, err := os.Stat(rec.AssetPath()); err == nil {
			p.rep.assetBytes += fi.Size()
		}
	}
}

// kindPublished ends a kind's part of the republish: its publish ran to its
// end this cycle. The last one logs the line.
func (p *Publisher) kindPublished(k Kind) {
	if p.rep == nil || !p.rep.pending[k] {
		return
	}
	delete(p.rep.pending, k)
	if len(p.rep.pending) == 0 {
		outcome := "complete"
		if p.rep.resumed {
			outcome = "resumed"
		}
		p.rep.log(outcome, p.mono())
		p.rep = nil
	}
}

func (r *republish) log(outcome string, now time.Time) {
	secs := int64(max(0, now.Sub(r.since)).Round(time.Second) / time.Second)
	log.Printf("hub: rotation republish: %s, %d records, %d asset bytes, %d envelope bytes, %d s",
		outcome, r.records, r.assetBytes, r.envelopeBytes, secs)
}

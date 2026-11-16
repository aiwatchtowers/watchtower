package slices

import "time"

// noteKindOutcome records whether kind k's attempt in a cycle went through
// whole (#1873): a failed save or source, or a record the cycle skipped
// (oversized, unsealable, refused by the transport), keeps k stuck from its
// first such attempt until an attempt goes through whole. at is the cycle's
// clock.
func (p *Publisher) noteKindOutcome(k Kind, whole bool, at time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if whole {
		delete(p.stuck, k)
		return
	}
	if _, ok := p.stuck[k]; ok {
		return
	}
	if p.stuck == nil {
		p.stuck = map[Kind]time.Time{}
	}
	p.stuck[k] = at
}

// StuckSince is when the oldest kind still stuck first failed to go through
// whole (the heartbeat's stuck_since); ok is false while every kind tried
// lately went through. A kind that fails while the transport is down is
// stuck too, but then the heartbeat cannot reach the phone either: the
// phone reads that from the heartbeat's age.
func (p *Publisher) StuckSince() (time.Time, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	var oldest time.Time
	for _, at := range p.stuck {
		if oldest.IsZero() || at.Before(oldest) {
			oldest = at
		}
	}
	return oldest, !oldest.IsZero()
}

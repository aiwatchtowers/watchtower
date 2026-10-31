package secure

// Verdict is a rollback guard's answer for an incoming (epoch, seq).
type Verdict int

// Newer: store and use; Same: an identical re-delivery (idempotent); Older:
// ignore (rollback).
const (
	Newer Verdict = iota
	Same
	Older
)

// RollbackGuard is keyed by (wire name, sender) (F3): one relay wire name
// carries the phone's p2h envelope (the phone's seq space) and later the hub's
// h2p echo (the hub's seq space); a guard keyed by the name alone would drop a
// valid echo. Record keeps the highest version seen.
type RollbackGuard interface {
	Check(wire string, sender ID, epoch uint32, seq uint64) (Verdict, error)
	Record(wire string, sender ID, epoch uint32, seq uint64) error
}

// CompareVersion compares an incoming (epoch, seq) with the stored one, epoch
// first: the rule every RollbackGuard applies.
func CompareVersion(storedEpoch uint32, storedSeq uint64, epoch uint32, seq uint64) Verdict {
	switch {
	case epoch == storedEpoch && seq == storedSeq:
		return Same
	case epoch > storedEpoch || (epoch == storedEpoch && seq > storedSeq):
		return Newer
	default:
		return Older
	}
}

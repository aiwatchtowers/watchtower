// Package sourcediff holds the guard shared by every diff that deletes local
// rows because a source listing no longer returns them.
package sourcediff

import "fmt"

// Floors are the minimum stored-row counts at which each refusal applies.
type Floors struct{ EmptyMin, HalfMin int }

// SlackFloors refuses on 0 hits over >=5 rows and on more than half of >=10 rows.
var SlackFloors = Floors{EmptyMin: 5, HalfMin: 10}

// MailFloors refuses on 0 IDs while any is stored and on more than half.
var MailFloors = Floors{EmptyMin: 1, HalfMin: 1}

// Check reports whether a diff may delete the missing rows. stored is the
// number of local rows inside the range the listing covers, listed how many of
// that range the listing returned, missing the stored rows absent from it.
// reason is non-empty exactly when a delete is refused.
func Check(stored, listed, missing int, f Floors) (ok bool, reason string) {
	if missing == 0 {
		return false, ""
	}
	if listed == 0 && stored >= f.EmptyMin {
		return false, fmt.Sprintf("listing returned 0 of %d stored rows", stored)
	}
	if 2*missing > stored && stored >= f.HalfMin {
		return false, fmt.Sprintf("would remove %d of %d stored rows", missing, stored)
	}
	return true, ""
}

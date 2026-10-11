package db

import (
	"errors"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

// IsBusy reports whether err is SQLite giving up on another connection's
// lock (SQLITE_BUSY or SQLITE_LOCKED, any extended code): a transient
// failure a caller may retry.
func IsBusy(err error) bool {
	var se *sqlite.Error
	if !errors.As(err, &se) {
		return false
	}
	switch se.Code() & 0xff {
	case sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED:
		return true
	}
	return false
}

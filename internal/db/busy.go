package db

import (
	"errors"

	"watchtower/internal/sqlcipher"
)

// IsBusy reports whether err is SQLite giving up on another connection's
// lock (SQLITE_BUSY or SQLITE_LOCKED, any extended code): a transient
// failure a caller may retry.
func IsBusy(err error) bool {
	var se sqlcipher.Error
	return errors.As(err, &se) && (se.Code == sqlcipher.ErrBusy || se.Code == sqlcipher.ErrLocked)
}

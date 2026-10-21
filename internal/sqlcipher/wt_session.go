//go:build cgo

package sqlcipher

import (
	"context"
	"database/sql/driver"
)

// ResetSession and IsValid make the connection a driver.SessionResetter and
// a driver.Validator, as modernc.org/sqlite's was (#603). database/sql keeps
// a connection whose transaction a cancelled context rolled back only when
// the driver implements both; without them it discards the connection, and
// with it an in-memory database or a warm page cache. Upstream mattn
// implements neither.

// ResetSession implements driver.SessionResetter: a closed connection is
// bad, any other is reused as is.
func (c *SQLiteConn) ResetSession(context.Context) error {
	if !c.dbConnOpen() {
		return driver.ErrBadConn
	}
	return nil
}

// IsValid implements driver.Validator: the connection is usable until it is
// closed.
func (c *SQLiteConn) IsValid() bool { return c.dbConnOpen() }

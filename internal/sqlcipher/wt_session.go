//go:build cgo

package sqlcipher

/*
#include "sqlite3-binding.h"
*/
import "C"

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

// ResetSession implements driver.SessionResetter: a closed connection, or
// one left inside a transaction (a raw BEGIN on a *sql.Conn returned without
// COMMIT), is bad; any other is reused as is.
func (c *SQLiteConn) ResetSession(context.Context) error {
	if !c.reusable() {
		return driver.ErrBadConn
	}
	return nil
}

// IsValid implements driver.Validator: the connection is usable while it is
// open and not inside a transaction.
func (c *SQLiteConn) IsValid() bool { return c.reusable() }

// reusable reports whether the connection is open and in autocommit mode.
func (c *SQLiteConn) reusable() bool {
	if c == nil {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.db != nil && C.sqlite3_get_autocommit(c.db) != 0
}

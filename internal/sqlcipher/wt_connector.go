//go:build cgo

package sqlcipher

/*
#include <stdlib.h>
#include <string.h>
#include "sqlite3-binding.h"

static int wt_key(sqlite3 *db, const void *key, int n) {
	return sqlite3_key_v2(db, "main", key, n);
}

// sqlite3_db_config is variadic, so cgo needs this wrapper. It returns the
// setting SQLite reports back, or -1 when the call itself fails.
static int wt_no_ckpt_on_close(sqlite3 *db) {
	int out = -1;
	int rv = sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &out);
	return rv == SQLITE_OK ? out : -1;
}
*/
import "C"

import (
	"context"
	"database/sql/driver"
	"encoding/hex"
	"errors"
	"fmt"
	"unsafe"
)

// KeyLen is the length of a raw SQLCipher key: 256 bits, passed as
// x'<64 hex>' so SQLCipher runs no PBKDF2 over it.
const KeyLen = 32

// Connector opens connections to one database for database/sql
// (sql.OpenDB). Path is the file name or a file: URI, exactly as mattn's
// driver takes it; Params is the query part without the '?'. Key, when set,
// returns the raw key each connection is keyed with: the bytes are applied
// with sqlite3_key_v2 right after sqlite3_open_v2 and before any PRAGMA,
// followed by PRAGMA cipher_compatibility = 4, and are zeroed after the
// call. The key never enters a DSN string. Key nil opens the file without a
// key, which is mattn's open unchanged (a plaintext SQLite file).
type Connector struct {
	Path   string
	Params string
	Key    func() ([]byte, error)
	// NoCheckpointOnClose turns on SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE and
	// sets PRAGMA wal_autocheckpoint = 0 on every connection, so neither a
	// commit nor the last close copies the WAL into the main file. A reader
	// that must leave the main file byte-identical sets it; Connect fails
	// with ErrNoCheckpointGuard when SQLite does not report it on.
	NoCheckpointOnClose bool
}

// ErrNoCheckpointGuard is returned by Connect when NoCheckpointOnClose is
// set and SQLite does not report SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE as on.
var ErrNoCheckpointGuard = errors.New("sqlcipher: no-checkpoint-on-close not confirmed")

// confirmNoCkpt reads the value SQLite reports for the setting; a seam so a
// test (which cannot use cgo) can force the failure path.
var confirmNoCkpt = func(out int) bool { return out == 1 }

var _ driver.Connector = (*Connector)(nil)

// DSN is the name mattn's driver opens: Path plus "?"+Params.
func (c *Connector) DSN() string {
	if c.Params == "" {
		return c.Path
	}
	return c.Path + "?" + c.Params
}

// Connect opens one connection.
func (c *Connector) Connect(ctx context.Context) (driver.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var key []byte
	if c.Key != nil {
		k, err := c.Key()
		if err != nil {
			return nil, fmt.Errorf("reading the database key: %w", err)
		}
		defer clear(k)
		if len(k) != KeyLen {
			return nil, fmt.Errorf("database key is %d bytes, want %d", len(k), KeyLen)
		}
		key = k
	}
	conn, err := driverInstance.open(c.DSN(), key)
	if err != nil || !c.NoCheckpointOnClose {
		return conn, err
	}
	sc, ok := conn.(*SQLiteConn)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("%w (unexpected connection type %T)", ErrNoCheckpointGuard, conn)
	}
	if err := noCheckpointOnClose(ctx, sc); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

// noCheckpointOnClose turns off the close-time and automatic checkpoints on
// one fresh connection.
func noCheckpointOnClose(ctx context.Context, conn *SQLiteConn) error {
	out := int(C.wt_no_ckpt_on_close(conn.db))
	if !confirmNoCkpt(out) {
		return fmt.Errorf("%w (sqlite reported %d)", ErrNoCheckpointGuard, out)
	}
	if _, err := conn.exec(ctx, "PRAGMA wal_autocheckpoint = 0", nil); err != nil {
		return fmt.Errorf("turning off wal_autocheckpoint: %w", err)
	}
	return nil
}

// Driver is the registered "sqlite3" driver.
func (c *Connector) Driver() driver.Driver { return driverInstance }

// driverInstance is the driver every Connector opens through: a plain
// SQLiteDriver, as sql.Register("sqlite3", …) registers.
var driverInstance = &SQLiteDriver{}

// errKeyRejected is returned when sqlite3_key_v2 itself fails.
var errKeyRejected = errors.New("sqlcipher rejected the key")

// applyKey keys db with the raw key as x'<hex>' and pins the cipher
// settings. Every buffer holding key material is zeroed before return.
func applyKey(db *C.sqlite3, key []byte) error {
	lit := make([]byte, 0, 3+2*len(key))
	lit = append(lit, 'x', '\'')
	lit = hex.AppendEncode(lit, key)
	lit = append(lit, '\'')
	defer clear(lit)

	n := C.size_t(len(lit))
	p := C.malloc(n)
	if p == nil {
		return errors.New("sqlcipher: out of memory for the key")
	}
	defer func() {
		C.memset(p, 0, n)
		C.free(p)
	}()
	copy(unsafe.Slice((*byte)(p), len(lit)), lit)
	if rv := C.wt_key(db, p, C.int(len(lit))); rv != C.SQLITE_OK {
		return fmt.Errorf("%w: %w", errKeyRejected, lastError(db))
	}
	cs := C.CString("PRAGMA cipher_compatibility = 4;")
	defer C.free(unsafe.Pointer(cs))
	if rv := C.sqlite3_exec(db, cs, nil, nil, nil); rv != C.SQLITE_OK {
		return fmt.Errorf("setting cipher_compatibility: %w", lastError(db))
	}
	return nil
}

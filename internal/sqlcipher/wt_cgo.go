//go:build cgo

package sqlcipher

// Watchtower's build of the SQLCipher community amalgamation (board #603),
// on top of the defines mattn's sqlite3.go sets. Darwin uses CommonCrypto;
// Linux (CI and tests only) uses OpenSSL's libcrypto. DBSTAT_VTAB keeps the
// dbstat table modernc.org/sqlite had (size checks in tests and diagnostics);
// MATH_FUNCTIONS, STAT4 and LIKE_DOESNT_MATCH_BLOBS keep modernc's SQL
// behaviour (ceil/floor/…, the STAT4 planner, a BLOB never LIKE-matches).
// MATH_FUNCTIONS and STAT4 repeat the defines of mattn's sqlite_math_functions
// and sqlite_stat4 tag files, which the build never sets; a repeated
// identical -D is harmless.

/*
#cgo CFLAGS: -DSQLITE_HAS_CODEC
#cgo CFLAGS: -DSQLITE_TEMP_STORE=2
#cgo CFLAGS: -DSQLITE_ENABLE_FTS5
#cgo CFLAGS: -DSQLITE_ENABLE_DBSTAT_VTAB
#cgo CFLAGS: -DSQLITE_ENABLE_MATH_FUNCTIONS
#cgo CFLAGS: -DSQLITE_ENABLE_STAT4
#cgo CFLAGS: -DSQLITE_LIKE_DOESNT_MATCH_BLOBS
#cgo CFLAGS: -DSQLITE_EXTRA_INIT=sqlcipher_extra_init
#cgo CFLAGS: -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown
#cgo darwin CFLAGS: -DSQLCIPHER_CRYPTO_CC
#cgo darwin LDFLAGS: -framework Security -framework CoreFoundation
#cgo linux CFLAGS: -DSQLCIPHER_CRYPTO_OPENSSL
#cgo linux LDFLAGS: -lcrypto -lm
*/
import "C"

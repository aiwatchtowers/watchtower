//go:build cgo

package sqlcipher

// Watchtower's build of the SQLCipher community amalgamation (board #603),
// on top of the defines mattn's sqlite3.go sets. Darwin uses CommonCrypto;
// Linux (CI and tests only) uses OpenSSL's libcrypto.

/*
#cgo CFLAGS: -DSQLITE_HAS_CODEC
#cgo CFLAGS: -DSQLITE_TEMP_STORE=2
#cgo CFLAGS: -DSQLITE_ENABLE_FTS5
#cgo CFLAGS: -DSQLITE_EXTRA_INIT=sqlcipher_extra_init
#cgo CFLAGS: -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown
#cgo darwin CFLAGS: -DSQLCIPHER_CRYPTO_CC
#cgo darwin LDFLAGS: -framework Security -framework CoreFoundation
#cgo linux CFLAGS: -DSQLCIPHER_CRYPTO_OPENSSL
#cgo linux LDFLAGS: -lcrypto
*/
import "C"

//go:build !cgo

package sqlcipher

// Watchtower's SQLite engine is the cgo SQLCipher build in this package; a
// CGO_ENABLED=0 build has no engine at all and must never fall back to some
// other one. This undefined identifier stops such a build at compile time.
var _ = watchtower_needs_cgo_for_sqlcipher

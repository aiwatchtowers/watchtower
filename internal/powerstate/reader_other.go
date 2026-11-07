//go:build !darwin || !cgo

package powerstate

// UseSystemReader is a no-op where there is no IOKit power management:
// FullWake keeps answering true.
func UseSystemReader() {}

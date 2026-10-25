//go:build !darwin || !cgo

package policy

// Managed preferences exist only on macOS: elsewhere there is no policy and
// reader keeps its empty default.

// Package cftest writes CoreFoundation preference values for the policy
// reader's tests. It is imported only from _test.go files, so it is never
// linked into the shipped binary (cgo is not allowed in _test.go files, which
// is why it is a package at all).
package cftest

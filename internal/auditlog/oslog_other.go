//go:build !darwin

package auditlog

// osLog does nothing off darwin: there is no unified log to write to.
func osLog(string) {}

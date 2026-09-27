package extsync

// ExtractDeadline exposes extractDeadline to the external test package,
// which can import internal/extract (extsync itself must not).
var ExtractDeadline = extractDeadline

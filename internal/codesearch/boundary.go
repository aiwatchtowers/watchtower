package codesearch

// isIdent reports whether b can be part of an identifier for --word:
// [A-Za-z0-9_$]. The `$` makes PHP/JS `$x` one word, which regexp's \b
// would split.
func isIdent(b byte) bool {
	return b == '_' || b == '$' ||
		('a' <= b && b <= 'z') || ('A' <= b && b <= 'Z') || ('0' <= b && b <= '9')
}

// wordAt reports whether line[s:e] stands as a whole word: an identifier
// character at either edge of the match must not continue into its
// neighbour. An edge that is not an identifier character (`foo(`) needs no
// boundary, so --word never rejects a match for its own punctuation.
func wordAt(line []byte, s, e int) bool {
	if s > 0 && isIdent(line[s]) && isIdent(line[s-1]) {
		return false
	}
	if e < len(line) && isIdent(line[e-1]) && isIdent(line[e]) {
		return false
	}
	return true
}

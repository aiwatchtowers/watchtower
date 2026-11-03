package automations

// LLMCallSites counts the llm( call sites in a script, lexically over the
// same scan as PreParse: comments, strings and template text are skipped, a
// property call (`x.llm(`) and an object key (`{llm: 1}`) are not call
// sites, and whitespace between llm and ( is allowed. validate --json's
// adds_llm compares this count with the confirmed text's (spec "The AI-step
// warning"); a moved call keeps the count.
func LLMCallSites(script string) int {
	s := &jsScan{src: script, line: 1}
	n := 0
	for s.i < len(s.src) {
		word, start := s.next()
		if word == "llm" && !s.afterDot(start) && s.nextByte() == '(' {
			n++
		}
	}
	return n
}

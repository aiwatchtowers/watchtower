package automations

// LLMCallSites counts the llm( call sites in a script, lexically over the
// same scan as PreParse: comments, strings and template text are skipped, a
// property call (`x.llm(`) and an object key (`{llm: 1}`) are not call
// sites, and whitespace between llm and ( is allowed. validate --json's
// adds_llm compares this count with the confirmed text's (spec "The AI-step
// warning"); a moved call keeps the count. It is a hint for the owner, not a
// guard: a regular-expression literal is not told apart (an llm( inside one
// counts), and an optional call (`llm?.(`), a parenthesised callee
// (`(llm)(`) or an alias (`const f = llm; f(`) is not counted. Every llm()
// call still needs the manifest's llm: permission at run time.
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

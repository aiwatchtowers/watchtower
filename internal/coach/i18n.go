package coach

import (
	"fmt"

	"watchtower/internal/agentreport"
)

// importWhy is the reason of a proposal carried over from an instruction
// suggestion, in the owner's language (digest.language): n is the number of
// sessions the miner saw the line in.
func importWhy(lang string, n int) string {
	if agentreport.LangOf(lang) == agentreport.Russian {
		word := "сессиях"
		if n%10 == 1 && n%100 != 11 {
			word = "сессии"
		}
		return fmt.Sprintf("Ты говорил это в %d %s", n, word)
	}
	if n == 1 {
		return "You said this in 1 session"
	}
	return fmt.Sprintf("You said this in %d sessions", n)
}

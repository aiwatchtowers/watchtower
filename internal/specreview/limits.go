package specreview

// Caps on a reviewer reply: the only place they live.
const (
	maxAgreements   = 200
	maxDecidedAlone = 100
	maxBlindSpots   = 100
	maxChecks       = 300
	maxResolved     = 300
	maxVerdicts     = 300
	maxNotes        = 20

	maxFieldRunes   = 600  // runes of any one free-text field
	maxSummaryRunes = 2000 // runes of the summary

	// minQuoteRunes: a quote shorter than this (after Normalize) is too weak
	// to anchor anything.
	minQuoteRunes = 8

	// maxQuoteRunes: a longer quote is rejected, never clipped, so every stored
	// quote is still a real substring.
	maxQuoteRunes = 1000

	keyHexDigits = 12
)

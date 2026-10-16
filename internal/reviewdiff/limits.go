package reviewdiff

// Caps of one review diff (spec §4.4); the only place these numbers live.
const (
	MaxFileBytes        = 1 << 20
	MaxFileChangedLines = 5000
	MaxTotalLines       = 50000
)

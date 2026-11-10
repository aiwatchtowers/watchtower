// Package reviewmap builds the instant, AI-free map of a review: which files
// are noise ("Can skip"), how dangerous each change is, the repository's own
// patterns from .watchtower/review-map.md, the lanes of a big branch and the
// chapters they form. It is pure except for git reads, which go through
// reviewdiff.Repo's hardened runner (REVIEW-05).
package reviewmap

package specreview

import (
	"strconv"
	"strings"
)

// QuestionTimeout is how long the author has to answer a thread's question
// before the daemon's sweep closes it as expired (spec 2026-11-08 §3).
const QuestionTimeout = AuthorTimeout

// ThreadContextID is the conversation key of a spec review thread:
// "<workbench>:<root>:<key>", where root is the first ask of the review chain,
// so a re-round's card with the same item key continues the same thread. The
// Desktop computes the same key (testdata/thread_keys.json is the shared
// fixture).
func ThreadContextID(workbenchID, rootAskID int64, itemKey string) string {
	return strconv.FormatInt(workbenchID, 10) + ":" + strconv.FormatInt(rootAskID, 10) + ":" + itemKey
}

// ParseThreadContextID splits a key ThreadContextID made. Both ids are
// positive decimals in canonical form and the item key (which may hold
// colons) is not empty; anything else is not ok.
func ParseThreadContextID(s string) (workbenchID, rootAskID int64, itemKey string, ok bool) {
	wb, rest, ok1 := strings.Cut(s, ":")
	root, key, ok2 := strings.Cut(rest, ":")
	if !ok1 || !ok2 || key == "" {
		return 0, 0, "", false
	}
	w, okW := canonicalID(wb)
	r, okR := canonicalID(root)
	if !okW || !okR {
		return 0, 0, "", false
	}
	return w, r, key, true
}

// canonicalID parses a positive decimal id written as FormatInt writes it.
func canonicalID(s string) (int64, bool) {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 || strconv.FormatInt(v, 10) != s {
		return 0, false
	}
	return v, true
}

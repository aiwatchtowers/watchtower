package inboxfeed

import (
	"sort"
	"strings"
	"unicode/utf8"

	"watchtower/internal/tower/api"
)

// Limit keeps at most n of cards (n > 0): Needs approval's cards first
// (those in approvalsFolder; on a tree without it, nil, the approval
// entries the root lists: a<action>, r<reminder>, n<built-in move>), then
// the pinned ones (Waiting for me), then the rest newest first by stamp. The kept cards stay in their list order; more
// counts, per folder in first-seen order, the cards left out. Folders and
// their counts are never cut: only cards past the cap leave.
func Limit(cards []api.Card, approvalsFolder *int64, n int) (kept []api.Card, more []api.FolderMore) {
	if n <= 0 || len(cards) <= n {
		return cards, nil
	}
	tier := func(c api.Card) int {
		switch {
		case approvalsFolder != nil && c.FolderID == *approvalsFolder,
			approvalsFolder == nil && isApprovalEntry(c):
			return 0
		case c.Pinned:
			return 1
		}
		return 2
	}
	order := make([]int, len(cards))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(i, j int) bool {
		a, b := cards[order[i]], cards[order[j]]
		if ta, tb := tier(a), tier(b); ta != tb {
			return ta < tb
		}
		return a.Stamp > b.Stamp // RFC 3339 UTC, one layout: text order is time order
	})
	keep := make([]bool, len(cards))
	for _, i := range order[:n] {
		keep[i] = true
	}
	cut := map[int64]int{}
	var folders []int64
	for i, c := range cards {
		if keep[i] {
			kept = append(kept, c)
			continue
		}
		if cut[c.FolderID] == 0 {
			folders = append(folders, c.FolderID)
		}
		cut[c.FolderID]++
	}
	for _, f := range folders {
		more = append(more, api.FolderMore{FolderID: f, Count: cut[f]})
	}
	return kept, more
}

// isApprovalEntry reports whether c is one of Needs approval's own
// entries: a native approval, a due reminder or a failed built-in move.
func isApprovalEntry(c api.Card) bool {
	switch c.CardKind {
	case api.CardApprovalNative, api.CardReminder:
		return true
	case api.CardNotice:
		return strings.HasPrefix(c.ID, "n")
	case api.CardArtifact, api.CardLegacy:
		return false
	}
	return false
}

// Clip cuts body to at most max bytes on a rune boundary; clipped reports
// whether it cut. A body already within max is returned as is.
func Clip(body string, maxBytes int) (out string, clipped bool) {
	if len(body) <= maxBytes {
		return body, false
	}
	end := maxBytes
	for end > 0 && !utf8.RuneStart(body[end]) {
		end--
	}
	return body[:end], true
}

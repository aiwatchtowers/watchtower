package inboxfeed

import (
	"strconv"
	"strings"

	"watchtower/internal/tower/api"
)

// recipeDiff is OwnerAskSnapshotDiff's lines: previous and current split on
// "\n" ("" is no lines), diffed as Swift's `current.difference(from:
// previous)` does (its Myers descent and backtrack, ported so the same
// lines are marked), then walked in order: a removed old line first, then
// an inserted new one, else a line both share.
func recipeDiff(previous, current string) []api.DiffLine {
	old, cur := splitLines(previous), splitLines(current)
	removed, inserted := myersChanges(old, cur)
	var out []api.DiffLine
	i, j := 0, 0
	for i < len(old) || j < len(cur) {
		switch {
		case i < len(old) && removed[i]:
			out = append(out, api.DiffLine{Kind: api.DiffRemoved, Text: old[i]})
			i++
		case j < len(cur) && inserted[j]:
			out = append(out, api.DiffLine{Kind: api.DiffAdded, Text: cur[j]})
			j++
		default:
			out = append(out, api.DiffLine{Kind: api.DiffSame, Text: cur[j]})
			i++
			j++
		}
	}
	return out
}

func splitLines(text string) []string {
	if text == "" {
		return nil
	}
	return strings.Split(text, "\n")
}

// myersChanges is the Swift standard library's _myers: the forward descent
// keeps each round's V before it is overwritten, then the backtrack from
// the end marks, per round, one insertion (new offset) or one removal (old
// offset).
func myersChanges(a, b []string) (removed, inserted map[int]bool) {
	removed, inserted = map[int]bool{}, map[int]bool{}
	n, m := len(a), len(b)
	maxD := n + m
	// v maps k (-d…d) to x; offset keeps indexes non-negative.
	offset := maxD + 1
	newV := func() []int { return make([]int, 2*offset+1) }
	var trace [][]int
	v := newV()
	v[offset+1] = 0
	var x, y int
descent:
	for d := 0; d <= maxD; d++ {
		prev := v
		trace = append(trace, prev)
		v = newV()
		for k := -d; k <= d; k += 2 {
			switch {
			case k == -d:
				x = prev[offset+k+1]
			case k != d && prev[offset+k-1] < prev[offset+k+1]:
				x = prev[offset+k+1]
			default:
				x = prev[offset+k-1] + 1
			}
			y = x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[offset+k] = x
			if x >= n && y >= m {
				break descent
			}
		}
	}
	x, y = n, m
	for d := len(trace) - 1; d > 0; d-- {
		vd := trace[d]
		k := x - y
		prevK := k - 1
		if k == -d || (k != d && vd[offset+k-1] < vd[offset+k+1]) {
			prevK = k + 1
		}
		prevX := vd[offset+prevK]
		prevY := prevX - prevK
		for x > prevX && y > prevY {
			x--
			y--
		}
		if y != prevY {
			inserted[prevY] = true
		} else {
			removed[prevX] = true
		}
		x, y = prevX, prevY
	}
	return removed, inserted
}

// recipeLineCount is the "N lines" of SaveAutomationCardModel.recipeDisclosureTitle:
// the "\n"-separated pieces, a trailing newline not counted.
func recipeLineCount(text string) int {
	n := strings.Count(text, "\n") + 1
	if strings.HasSuffix(text, "\n") {
		n--
	}
	return n
}

// recipeDisclosureTitle is SaveAutomationCardModel.recipeDisclosureTitle.
func recipeDisclosureTitle(text string) string {
	n := recipeLineCount(text)
	word := "lines"
	if n == 1 {
		word = "line"
	}
	return "Show the whole recipe (" + strconv.Itoa(n) + " " + word + ")"
}

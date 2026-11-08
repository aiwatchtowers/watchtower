package reviewai

import (
	"cmp"
	"slices"

	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
)

// collapsedKey is the map's "Can skip" chapter: never packed, never
// described.
const collapsedKey = "collapsed"

// notShownWhat describes a chapter none of whose files has a diff the model
// could read (binary, collapsed, or cut by the diff's size cap).
const notShownWhat = "Not shown to the AI: its files are binary or too large for the diff."

// Batch is the input of one model call: whole chapters in reading order,
// their files as the call shows them and the diff lines shown in all.
type Batch struct {
	Chapters []reviewmap.Chapter
	// Files are the chapters' files in prompt order, hunks cut to what the
	// call shows; a file with no lines left is listed by name only.
	Files []reviewdiff.File
	Lines int

	omitted map[string]int // path → lines of a cut file not shown
	// others are, on the one batch of the whole map, the changed files of
	// the chapters Pack leaves out ("collapsed" and chapters with nothing
	// to show): the one full call lists them by name so its coverage can
	// still name them. truncated is the diff's size cap, said to that call.
	others    []reviewdiff.File
	truncated bool
}

// unit is one chapter ready to pack: its diff files and shown lines.
type unit struct {
	ch    reviewmap.Chapter
	files []reviewdiff.File
	lines int
}

// Pack packs the map's chapters into batches (tech spec §3.1): first fit in
// reading order, at most MaxBatchLines shown lines each; "collapsed" and
// chapters with nothing to show are never packed. A chapter over the budget
// gets a batch of its own with its files in descending level, then path,
// shown until the budget is spent. Each file shows at most
// MaxOverviewFileLines lines. Chapters in have (they have a part row) are
// left out, unless every packable chapter fits one batch: then that one
// batch of all of them is returned (a small change is never judged from
// descriptions alone).
func Pack(m reviewmap.Map, d reviewdiff.Diff, have map[string]bool) []Batch {
	all := packUnits(m, d)
	if len(all) == 0 {
		return nil
	}
	if bs := firstFit(all, m); len(bs) == 1 {
		bs[0].others = leftOut(m, d, bs[0])
		bs[0].truncated = m.DiffTruncated
		return bs
	}
	todo := slices.DeleteFunc(all, func(u unit) bool { return have[u.ch.Key] })
	return firstFit(todo, m)
}

// NotShown describes, without a call, the chapters Pack leaves out because
// none of their files has a diff to show.
func NotShown(m reviewmap.Map, d reviewdiff.Diff) map[string]ChapterDesc {
	byPath := filesByPath(d)
	out := map[string]ChapterDesc{}
	for _, ch := range m.Chapters {
		if ch.Key == collapsedKey {
			continue
		}
		if _, lines := chapterFiles(ch, byPath); lines == 0 {
			out[ch.Key] = ChapterDesc{Key: ch.Key, What: notShownWhat, Risks: []Risk{}}
		}
	}
	return out
}

// leftOut is the diff's files of the map's chapters that b does not carry,
// in map order.
func leftOut(m reviewmap.Map, d reviewdiff.Diff, b Batch) []reviewdiff.File {
	in := b.paths()
	byPath := filesByPath(d)
	var out []reviewdiff.File
	for _, ch := range m.Chapters {
		for _, p := range ch.Paths {
			if f, ok := byPath[p]; ok && !in[p] {
				in[p] = true
				out = append(out, f)
			}
		}
	}
	return out
}

func packUnits(m reviewmap.Map, d reviewdiff.Diff) []unit {
	byPath := filesByPath(d)
	var out []unit
	for _, ch := range m.Chapters {
		if ch.Key == collapsedKey {
			continue
		}
		if files, lines := chapterFiles(ch, byPath); lines > 0 {
			out = append(out, unit{ch: ch, files: files, lines: lines})
		}
	}
	return out
}

// filesByPath indexes the diff's files; the first of a repeated path wins.
func filesByPath(d reviewdiff.Diff) map[string]reviewdiff.File {
	out := make(map[string]reviewdiff.File, len(d.Files))
	for _, f := range d.Files {
		if _, dup := out[f.Path]; !dup {
			out[f.Path] = f
		}
	}
	return out
}

// chapterFiles is the chapter's diff files in its path order and the lines
// they would show; a path missing from the diff is skipped.
func chapterFiles(ch reviewmap.Chapter, byPath map[string]reviewdiff.File) ([]reviewdiff.File, int) {
	var files []reviewdiff.File
	lines := 0
	for _, p := range ch.Paths {
		if f, ok := byPath[p]; ok {
			files = append(files, f)
			lines += shownLines(f)
		}
	}
	return files, lines
}

// shownLines is how many diff lines of f a call may show: none for a
// binary or collapsed file, else at most MaxOverviewFileLines.
func shownLines(f reviewdiff.File) int {
	if f.Binary || f.CollapsedReason != "" {
		return 0
	}
	return min(fileLines(f), MaxOverviewFileLines)
}

// firstFit puts each unit, in order, into the first batch with room; a
// unit over MaxBatchLines takes a batch of its own, cut to the budget.
func firstFit(units []unit, m reviewmap.Map) []Batch {
	var out []Batch
	for _, u := range units {
		if u.lines > MaxBatchLines {
			out = append(out, oversized(u, m))
			continue
		}
		i := slices.IndexFunc(out, func(b Batch) bool { return b.Lines+u.lines <= MaxBatchLines })
		if i < 0 {
			out = append(out, Batch{omitted: map[string]int{}})
			i = len(out) - 1
		}
		b := &out[i]
		b.Chapters = append(b.Chapters, u.ch)
		for _, f := range u.files {
			b.addFile(f, shownLines(f))
		}
	}
	return out
}

// oversized is the batch of one chapter over the budget: files by level
// descending, then path, each shown while the budget lasts.
func oversized(u unit, m reviewmap.Map) Batch {
	level := map[string]reviewmap.Level{}
	for _, fi := range m.Files {
		level[fi.Path] = fi.Level
	}
	files := slices.Clone(u.files)
	slices.SortStableFunc(files, func(a, b reviewdiff.File) int {
		return cmp.Or(cmp.Compare(level[b.Path], level[a.Path]), cmp.Compare(a.Path, b.Path))
	})
	b := Batch{Chapters: []reviewmap.Chapter{u.ch}, omitted: map[string]int{}}
	for _, f := range files {
		b.addFile(f, min(shownLines(f), MaxBatchLines-b.Lines))
	}
	return b
}

// addFile adds f showing its first n diff lines.
func (b *Batch) addFile(f reviewdiff.File, n int) {
	cut := f
	cut.Hunks = nil
	left := n
	for _, h := range f.Hunks {
		if left <= 0 {
			break
		}
		if len(h.Lines) > left {
			h.Lines = h.Lines[:left]
		}
		cut.Hunks = append(cut.Hunks, h)
		left -= len(h.Lines)
	}
	// A readable file the budget cut, even to nothing, says how much is
	// missing; a binary or collapsed one is "not shown" by name only.
	if rest := fileLines(f) - n; rest > 0 && shownLines(f) > 0 {
		b.omitted[f.Path] = rest
	}
	b.Files = append(b.Files, cut)
	b.Lines += n
}

// paths is every file path of the batch.
func (b Batch) paths() map[string]bool {
	out := make(map[string]bool, len(b.Files))
	for _, f := range b.Files {
		out[f.Path] = true
	}
	return out
}

// changedPaths is every path the batch's call is told about: its files and
// the left-out files listed by name.
func (b Batch) changedPaths() map[string]bool {
	out := b.paths()
	for _, f := range b.others {
		out[f.Path] = true
	}
	return out
}

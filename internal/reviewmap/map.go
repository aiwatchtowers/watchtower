package reviewmap

import (
	"cmp"
	"maps"
	"slices"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
)

// collapsedKey is the noise chapter's key (the Desktop's key, kept so a
// saved review_checks row still matches); its title is collapsedTitle.
const (
	collapsedKey   = "collapsed"
	collapsedTitle = "Can skip"
)

// Chapter is one chapter of the map. Key is "agent:<n>", "collapsed",
// "lane:<lane>", "lane:<lane>/<dir>[#N]" or "dir:<dir>[#N]". Level is the
// highest of its files' ("collapsed" is always normal); Core is true for a
// breaking chapter and for an agent chapter marked core. Lane, TargetID and
// JiraKey are set on a lane chapter (the last two when the lane's ticket was
// found).
type Chapter struct {
	Key            string         `json:"key"`
	Title          string         `json:"title"`
	Level          Level          `json:"level"`
	Core           bool           `json:"core"`
	Paths          []string       `json:"paths"`
	ChangedLines   int            `json:"changed_lines"`
	Lane           string         `json:"lane,omitempty"`
	TargetID       int64          `json:"target_id,omitempty"`
	JiraKey        string         `json:"jira_key,omitempty"`
	SignalsSummary map[string]int `json:"signals_summary"`

	agent bool // built from the agent's chapters (reading order)
}

// FileInfo is one changed file of the map: its chapter, level and danger
// signals, its lane and its other lanes when attributed.
type FileInfo struct {
	Path    string   `json:"path"`
	Chapter string   `json:"chapter"`
	Level   Level    `json:"level"`
	Signals []string `json:"signals"`
	Lane    string   `json:"lane,omitempty"`
	Also    []string `json:"also,omitempty"`
}

// LaneInfo is one lane the attribution found, whether or not a chapter of
// its own came of it (its files may all have gone to the agent's chapters
// or to noise): its name, its title (the name when none was found) and its
// ticket when found.
type LaneInfo struct {
	Name     string `json:"name"`
	Title    string `json:"title"`
	TargetID int64  `json:"target_id,omitempty"`
	JiraKey  string `json:"jira_key,omitempty"`
}

// Map is the instant, AI-free map of a review (tech spec §2.6): chapters
// in reading order, every diff file in diff order, every lane by name.
type Map struct {
	Chapters      []Chapter  `json:"chapters"`
	Files         []FileInfo `json:"files"`
	Lanes         []LaneInfo `json:"lanes"`
	LanesPartial  bool       `json:"lanes_partial"`
	DiffTruncated bool       `json:"diff_truncated"`
	Notes         []string   `json:"notes"`
}

// Input is everything Build needs; the caller does the git and database
// reads. AgentChapters are the session's review notes in ord order (notes
// of another kind are skipped and take no number).
type Input struct {
	Diff          reviewdiff.Diff
	AgentChapters []db.ReviewNote
	Attribution   Attribution
	Patterns      Patterns
}

// Build makes the map (tech spec §2.5): the agent's chapters, then noise
// in "collapsed", then lane chapters (a lane over 400 changed lines split
// by directory), then the rest by directory; each step gets only the files
// no earlier step took. Chapters come in reading order: level, agent
// chapters first, changed lines descending, "collapsed" last.
func Build(in Input) Map {
	chapters := buildChapters(in)

	fileSignals := map[string][]string{}
	for _, f := range in.Diff.Files {
		fileSignals[f.Path] = nonNil(Signals(f, in.Patterns))
	}
	chapterOf := map[string]string{}
	for i := range chapters {
		c := &chapters[i]
		c.SignalsSummary = map[string]int{}
		for _, p := range c.Paths {
			chapterOf[p] = c.Key
			for _, s := range fileSignals[p] {
				c.SignalsSummary[s]++
			}
			// "Can skip" stays normal and non-core whatever its files carry;
			// they keep their own levels in Files.
			if c.Key != collapsedKey {
				c.Level = max(c.Level, LevelOf(fileSignals[p]))
			}
		}
		c.Core = c.Core || c.Level == Breaking
	}
	slices.SortStableFunc(chapters, readingOrder)

	files := make([]FileInfo, 0, len(in.Diff.Files))
	for _, f := range in.Diff.Files {
		files = append(files, FileInfo{
			Path:    f.Path,
			Chapter: chapterOf[f.Path],
			Level:   LevelOf(fileSignals[f.Path]),
			Signals: fileSignals[f.Path],
			Lane:    in.Attribution.FileLane[f.Path],
			Also:    in.Attribution.Also[f.Path],
		})
	}
	lanes := make([]LaneInfo, 0, len(in.Attribution.Lanes))
	for _, name := range slices.Sorted(maps.Keys(in.Attribution.Lanes)) {
		l := in.Attribution.Lanes[name]
		lanes = append(lanes, LaneInfo{Name: name, Title: cmp.Or(l.Title, name), TargetID: l.TargetID, JiraKey: l.JiraKey})
	}
	return Map{
		Chapters:      chapters,
		Files:         files,
		Lanes:         lanes,
		LanesPartial:  in.Attribution.Partial,
		DiffTruncated: in.Diff.Truncated,
		Notes:         nonNil(in.Patterns.Notes),
	}
}

// buildChapters makes the chapters in build order, without levels or
// signals. Agent and "dir:" chapters are the Desktop's, byte for byte
// (testdata/chapters_golden.json, recorded from the Swift builder before it
// was removed).
func buildChapters(in Input) []Chapter {
	lines := map[string]int{}    // noise costs no reading time
	rawLines := map[string]int{} // what the "Can skip" chapter shows
	noise := map[string]bool{}
	for _, f := range in.Diff.Files {
		if _, dup := rawLines[f.Path]; dup {
			continue
		}
		rawLines[f.Path] = f.Additions + f.Deletions
		if IsNoise(f, in.Patterns) {
			noise[f.Path] = true
			lines[f.Path] = 0
		} else {
			lines[f.Path] = f.Additions + f.Deletions
		}
	}

	var specs []spec
	for _, n := range in.AgentChapters {
		if n.Kind == "chapter" {
			specs = append(specs, spec{title: n.Text, paths: n.Paths, core: n.Core})
		}
	}
	taken := map[string]bool{}
	chapters := agentChapters(specs, lines, taken)

	var skip []string
	byLane := map[string][]string{}
	var rest []string
	for _, f := range in.Diff.Files {
		p := f.Path
		if taken[p] {
			continue
		}
		taken[p] = true
		switch lane := in.Attribution.FileLane[p]; {
		case noise[p]:
			skip = append(skip, p)
		case lane != "":
			byLane[lane] = append(byLane[lane], p)
		default:
			rest = append(rest, p)
		}
	}
	if len(skip) > 0 {
		chapters = append(chapters, Chapter{
			Key: collapsedKey, Title: collapsedTitle, Paths: skip, ChangedLines: sumLines(skip, rawLines),
		})
	}

	laneNames := make([]string, 0, len(byLane))
	for name := range byLane {
		laneNames = append(laneNames, name)
	}
	slices.Sort(laneNames)
	for _, name := range laneNames {
		chapters = append(chapters, laneChapters(name, in.Attribution.Lanes[name], byLane[name], lines)...)
	}

	for _, part := range splitByDir(rest, lines) {
		chapters = append(chapters, Chapter{
			Key: "dir:" + part.keySuffix(), Title: part.title(), Paths: part.paths, ChangedLines: part.lines,
		})
	}
	return chapters
}

// laneChapters is one "lane:<lane>" chapter, or, for a lane over
// maxChapterLines, its directory split "lane:<lane>/<dir>[#N]" titled
// "<lane title> · <dir>".
func laneChapters(name string, lane Lane, paths []string, lines map[string]int) []Chapter {
	title := cmp.Or(lane.Title, name)
	parts := splitByDir(paths, lines)
	mk := func(key, chTitle string, chPaths []string, n int) Chapter {
		return Chapter{
			Key: key, Title: chTitle, Paths: chPaths, ChangedLines: n,
			Lane: name, TargetID: lane.TargetID, JiraKey: lane.JiraKey,
		}
	}
	if total := sumLines(paths, lines); total <= maxChapterLines {
		var all []string
		for _, part := range parts {
			all = append(all, part.paths...)
		}
		return []Chapter{mk("lane:"+name, title, all, total)}
	}
	out := make([]Chapter, 0, len(parts))
	for _, part := range parts {
		out = append(out, mk("lane:"+name+"/"+part.keySuffix(), title+" · "+part.title(), part.paths, part.lines))
	}
	return out
}

// readingOrder: "collapsed" last; then level (breaking first), agent
// chapters before the others, changed lines descending. Stable, so ties
// keep build order.
func readingOrder(a, b Chapter) int {
	if c := cmp.Compare(boolRank(a.Key == collapsedKey), boolRank(b.Key == collapsedKey)); c != 0 {
		return c
	}
	if c := cmp.Compare(b.Level, a.Level); c != 0 {
		return c
	}
	if c := cmp.Compare(boolRank(!a.agent), boolRank(!b.agent)); c != 0 {
		return c
	}
	return cmp.Compare(b.ChangedLines, a.ChangedLines)
}

func boolRank(b bool) int {
	if b {
		return 1
	}
	return 0
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

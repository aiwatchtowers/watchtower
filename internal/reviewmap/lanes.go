package reviewmap

import (
	"context"
	"errors"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/reviewdiff"
)

// Walk bounds of the lane attribution (tech spec §2.1): past them the
// remaining files have no lane and the attribution is partial.
const (
	maxWalkCommits = 2000
	maxWalkLanes   = 200
)

// Lane is a line of work merged into the reviewed branch, or a ticket a
// direct commit names. Name is the lane's label (the merged branch, or the
// commit's tag as is; "?" for a merge whose subject names no branch).
// Branch is the merged branch's name ("" for a tag). Title is the lane's
// ticket title when one is found, else Name. TargetID and JiraKey are set
// when a board target or a synced Jira issue was found.
type Lane struct {
	Name, Branch, Title string
	TargetID            int64
	JiraKey             string
}

// TargetTitle is a workbench target: its id and its text.
type TargetTitle struct {
	ID   int64
	Text string
}

// LaneTitles is what the database knows about the lanes' branches and
// tags. Missing maps mean nothing found.
type LaneTitles struct {
	// BranchTargets: a target of this workbench whose branch is the key
	// (open or closed, the newest one).
	BranchTargets map[string]TargetTitle
	// Jira: issue summaries of the keys found in jira_issues.
	Jira map[string]string
	// JiraProjects: project keys with synced issues. A commit's key of an
	// unsynced project is kept only when the lane's branch name carries it.
	JiraProjects map[string]bool
	// BoardRefs: the targets of this workbench among the asked ids.
	BoardRefs map[int64]TargetTitle
}

// TitleSource looks lanes' titles up (Task 5 wires the database). It is
// called once per attribution, after the walk.
type TitleSource interface {
	Titles(branches []string, jiraKeys []string, boardRefs []int64) LaneTitles
}

// Attribution maps the files committed on the branch to lanes. FileLane is
// the lane with the most commits touching the file (a tie goes to the
// lane that touched it later); Also lists its other lanes, sorted. A file
// with no lane (uncommitted, only in untagged direct commits of the
// branch, or past the walk bounds) is in neither map. Partial is true when
// the walk could not finish: no head commit, the bounds or the budget.
type Attribution struct {
	FileLane map[string]string
	Also     map[string][]string
	Lanes    map[string]Lane
	Partial  bool
}

// Attribute walks head's first-parent history down to base and attributes
// each committed file to a lane (tech spec §2.1). headBranch is the
// reviewed branch's name when known ("" otherwise): a merge of it into
// another branch is named by that branch, and a commit's key of an
// unsynced Jira project is kept when the name carries it. defaultTip is
// the default branch's tip ("" = none): a merge of its history is a base
// sync and is skipped. head "" (a round made before head_sha existed) or a
// walk past budget gives a partial attribution with no lanes and no error;
// a done ctx or a failing git is an error. Every git read goes through
// repo's hardened runner (REVIEW-05).
func Attribute(ctx context.Context, repo *reviewdiff.Repo, base, head, headBranch, defaultTip string,
	titles TitleSource, budget time.Duration) (Attribution, error) {
	return attribute(ctx, repo, base, head, headBranch, defaultTip, titles, budget, maxWalkCommits, maxWalkLanes)
}

func attribute(ctx context.Context, repo *reviewdiff.Repo, base, head, headBranch, defaultTip string,
	titles TitleSource, budget time.Duration, maxCommits, maxLanes int) (Attribution, error) {
	if head == "" {
		return partialAttribution(), nil
	}
	walkCtx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	w := &walker{
		repo: repo, defaultTip: defaultTip,
		commitsLeft: maxCommits, lanesLeft: maxLanes,
	}
	if base != "" && base != reviewdiff.EmptyTree {
		w.base = base
	}
	top := &walkLane{branch: headBranch, top: true}
	if err := w.walk(walkCtx, top, head, w.excludeWith()); err != nil {
		if ctx.Err() == nil && errors.Is(walkCtx.Err(), context.DeadlineExceeded) {
			return partialAttribution(), nil
		}
		return Attribution{}, err
	}
	return w.attribution(titles), nil
}

func partialAttribution() Attribution {
	return Attribution{FileLane: map[string]string{}, Also: map[string][]string{}, Lanes: map[string]Lane{}, Partial: true}
}

// walkLane is one first-parent walk: the top branch or a merged lane.
type walkLane struct {
	name, branch string
	top          bool
	integration  bool // its own walk merges lanes (the top always is)
}

// record is one direct (non-merge) commit in reading order.
type record struct {
	seq     int
	lane    *walkLane
	subject string
	files   []string
}

type walker struct {
	repo                   *reviewdiff.Repo
	base, defaultTip       string
	commitsLeft, lanesLeft int
	partial                bool
	seq                    int
	records                []record
	lanes                  []*walkLane
}

func (w *walker) excludeWith(revs ...string) []string {
	if w.base != "" {
		revs = append(revs, w.base)
	}
	return revs
}

// walk reads one first-parent walk and records its direct commits oldest
// first, recursing into each lane merge before the commits after it, so
// records come in an order where a later commit is never read earlier.
func (w *walker) walk(ctx context.Context, lane *walkLane, tip string, exclude []string) error {
	if w.commitsLeft <= 0 {
		w.partial = true
		return nil
	}
	commits, err := w.repo.FirstParentWalk(ctx, tip, exclude, w.commitsLeft+1)
	if err != nil {
		return err
	}
	if len(commits) > w.commitsLeft {
		commits, w.partial = commits[:w.commitsLeft], true
	}
	w.commitsLeft -= len(commits)

	merges := make([]string, len(commits)) // lane name per lane merge, "" otherwise
	isSync := make([]bool, len(commits))
	direct := 0
	for i, c := range commits {
		if len(c.Parents) < 2 {
			direct++
			continue
		}
		if w.defaultTip != "" {
			sync, err := w.repo.IsAncestor(ctx, c.Parents[1], w.defaultTip)
			if err != nil {
				return err
			}
			if sync {
				isSync[i] = true
				continue
			}
		}
		merges[i] = mergeLaneName(c.Subject, lane.branch)
		lane.integration = true
	}
	if lane.top {
		lane.integration = true
	}
	var files map[string][]string
	if direct > 0 {
		if files, err = w.repo.CommitFiles(ctx, tip, exclude, direct); err != nil {
			return err
		}
	}
	for i := len(commits) - 1; i >= 0; i-- {
		c := commits[i]
		switch {
		case isSync[i]:
		case merges[i] != "":
			if w.lanesLeft <= 0 {
				w.partial = true
				continue
			}
			w.lanesLeft--
			child := &walkLane{name: merges[i], branch: mergeBranch(merges[i])}
			w.lanes = append(w.lanes, child)
			if err := w.walk(ctx, child, c.Parents[1], w.excludeWith(c.Parents[0])); err != nil {
				return err
			}
		case len(c.Parents) < 2:
			w.seq++
			w.records = append(w.records, record{seq: w.seq, lane: lane, subject: c.Subject, files: files[c.SHA]})
		}
	}
	return nil
}

func mergeBranch(name string) string {
	if name == unparsedLane {
		return ""
	}
	return name
}

// attribution labels the records, looks the titles up once and counts.
func (w *walker) attribution(src TitleSource) Attribution {
	titles := w.titles(src)
	a := Attribution{FileLane: map[string]string{}, Also: map[string][]string{}, Lanes: map[string]Lane{}, Partial: w.partial}
	type touch struct{ count, last int }
	touches := map[string]map[string]*touch{}
	for _, r := range w.records {
		name, tag := w.label(r, titles)
		if name == "" {
			continue
		}
		if _, ok := a.Lanes[name]; !ok {
			a.Lanes[name] = laneOf(name, tag, r.lane, titles)
		}
		for _, f := range r.files {
			byLane := touches[f]
			if byLane == nil {
				byLane = map[string]*touch{}
				touches[f] = byLane
			}
			t := byLane[name]
			if t == nil {
				t = &touch{}
				byLane[name] = t
			}
			t.count++
			t.last = r.seq
		}
	}
	for f, byLane := range touches {
		best, bt := "", &touch{}
		for name, t := range byLane {
			if t.count > bt.count || (t.count == bt.count && t.last > bt.last) {
				best, bt = name, t
			}
		}
		a.FileLane[f] = best
		for name := range byLane {
			if name != best {
				a.Also[f] = append(a.Also[f], name)
			}
		}
		slices.Sort(a.Also[f])
	}
	// A merged lane none of whose commits survived (all tagged elsewhere,
	// or empty) is still a lane of the branch.
	for _, l := range w.lanes {
		if _, ok := a.Lanes[l.name]; !ok {
			a.Lanes[l.name] = laneOf(l.name, false, l, titles)
		}
	}
	return a
}

// label is the lane a direct commit belongs to: on an integration lane its
// subject's tag (tag = true), else the lane itself; "" = no lane (an
// untagged direct commit of the top branch).
func (w *walker) label(r record, titles LaneTitles) (name string, tag bool) {
	if r.lane.integration {
		if t := commitTag(r.subject, r.lane.branch, titles); t != "" {
			return t, true
		}
	}
	return r.lane.name, false
}

// titles asks src once for every branch, Jira key and board ref the walk
// saw.
func (w *walker) titles(src TitleSource) LaneTitles {
	if src == nil {
		return LaneTitles{}
	}
	var branches, keys []string
	var refs []int64
	for _, l := range w.lanes {
		if l.branch != "" {
			branches = append(branches, l.branch)
			keys = append(keys, jiraKeyRe.FindAllString(l.branch, -1)...)
		}
	}
	for _, r := range w.records {
		if !r.lane.integration {
			continue
		}
		keys = append(keys, jiraKeyRe.FindAllString(r.subject, -1)...)
		for _, m := range boardRefRe.FindAllStringSubmatch(r.subject, -1) {
			if id, err := strconv.ParseInt(m[1], 10, 64); err == nil {
				refs = append(refs, id)
			}
		}
	}
	return src.Titles(sortedUnique(branches), sortedUnique(keys), sortedUnique(refs))
}

func sortedUnique[T string | int64](s []T) []T {
	slices.Sort(s)
	return slices.Compact(s)
}

// laneOf builds a lane with its title (§2.1 "Lane titles"): a target whose
// branch is the lane's, a Jira key in the branch name or the tag, a board
// ref tag, else the name.
func laneOf(name string, tag bool, from *walkLane, titles LaneTitles) Lane {
	l := Lane{Name: name, Title: name}
	if !tag {
		l.Branch = from.branch
	}
	if l.Branch != "" {
		if t, ok := titles.BranchTargets[l.Branch]; ok {
			l.Title, l.TargetID = t.Text, t.ID
			return l
		}
	}
	for _, key := range jiraKeyRe.FindAllString(l.Branch+" "+tagText(name, tag), -1) {
		if summary, ok := titles.Jira[key]; ok {
			l.Title, l.JiraKey = summary, key
			return l
		}
	}
	if tag {
		if m := boardRefRe.FindStringSubmatch(name); m != nil && m[0] == name {
			id, _ := strconv.ParseInt(m[1], 10, 64)
			if t, ok := titles.BoardRefs[id]; ok {
				l.Title, l.TargetID = t.Text, t.ID
			}
		}
	}
	return l
}

func tagText(name string, tag bool) string {
	if tag {
		return name
	}
	return ""
}

const unparsedLane = "?"

var (
	mergePRRe     = regexp.MustCompile(`^Merge pull request #\d+ from [^/\s]+/(\S+)`)
	mergeBranchRe = regexp.MustCompile(`^Merge (?:remote-tracking )?branch '(?:origin/)?([^']+)'(?: into '?([^'\s]+)'?)?`)
	mergeBareRe   = regexp.MustCompile(`^Merge (?:origin/)?([^\s:]+)[: ]`)

	jiraKeyRe  = regexp.MustCompile(`\b[A-Z][A-Z0-9]{1,9}-\d+\b`)
	boardRefRe = regexp.MustCompile(`#(\d{2,6})\b`)
	planTagRe  = regexp.MustCompile(`\(([A-Z]{1,2}\d+[a-z]?)\b`)
	scopeRe    = regexp.MustCompile(`^\w+\(([^)]+)\)!?:`)
)

// mergeLaneName is the lane a merge's subject names (§2.1): the source
// branch, or the `into` target when the source is the walked lane's own
// branch (the walked branch fast-forwarded to a merge made on that lane);
// "?" when the subject names no branch.
func mergeLaneName(subject, walked string) string {
	if m := mergePRRe.FindStringSubmatch(subject); m != nil {
		return m[1]
	}
	if m := mergeBranchRe.FindStringSubmatch(subject); m != nil {
		if walked != "" && m[1] == walked && m[2] != "" {
			return m[2]
		}
		return m[1]
	}
	if m := mergeBareRe.FindStringSubmatch(subject); m != nil {
		return m[1]
	}
	return unparsedLane
}

// commitTag is a direct commit's tag on an integration lane, first match
// wins (§2.1): a Jira key (validated against the synced issues when its
// project is synced, else kept only when the lane's branch name carries
// it), a board ref that is a target of this workbench, a plan tag, a
// conventional-commit scope; "" = untagged. A candidate that fails its
// check falls through to the next kind.
func commitTag(subject, branch string, titles LaneTitles) string {
	for _, key := range jiraKeyRe.FindAllString(subject, -1) {
		project, _, _ := strings.Cut(key, "-")
		if titles.JiraProjects[project] {
			if _, ok := titles.Jira[key]; ok {
				return key
			}
			continue
		}
		if branch != "" && slices.Contains(jiraKeyRe.FindAllString(branch, -1), key) {
			return key
		}
	}
	for _, m := range boardRefRe.FindAllStringSubmatch(subject, -1) {
		id, err := strconv.ParseInt(m[1], 10, 64)
		if err != nil {
			continue
		}
		if _, ok := titles.BoardRefs[id]; ok {
			return "#" + m[1]
		}
	}
	if m := planTagRe.FindStringSubmatch(subject); m != nil {
		return m[1]
	}
	if m := scopeRe.FindStringSubmatch(subject); m != nil {
		return m[1]
	}
	return ""
}

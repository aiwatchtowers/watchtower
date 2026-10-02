package projectcheck

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// ghCallTimeout bounds one `gh pr view`; ghBudget bounds them all, so a slow
// network never stalls a check for long.
const (
	ghCallTimeout = 10 * time.Second
	ghBudget      = 30 * time.Second
)

// prChecker reads pull request states through the gh CLI, when it is
// installed and signed in. Used only with Options.Network.
type prChecker struct {
	o         Options
	available bool
	deadline  time.Time
	notes     []string
	skipped   int    // pull requests whose state could not be read
	firstErr  string // why the first of them could not
}

func newPRChecker(ctx context.Context, o Options) *prChecker {
	p := &prChecker{o: o, deadline: time.Now().Add(ghBudget)}
	cctx, cancel := context.WithTimeout(ctx, ghCallTimeout)
	defer cancel()
	if _, _, err := o.Run(cctx, o.Folder, nil, "gh", "auth", "status"); err != nil {
		switch {
		case errors.Is(err, exec.ErrNotFound):
			p.notes = append(p.notes, "gh CLI not found; pull request states not checked")
		case cctx.Err() != nil:
			p.notes = append(p.notes, "gh CLI did not answer in time; pull request states not checked")
		default:
			p.notes = append(p.notes, "gh CLI is not signed in or failed ("+clipNote(err.Error())+"); pull request states not checked")
		}
		return p
	}
	p.available = true
	return p
}

// state returns OPEN, MERGED or CLOSED for ref (a number, #number or URL),
// or "" when it cannot be read.
func (p *prChecker) state(ctx context.Context, ref string) string {
	if !p.available {
		return ""
	}
	ref = strings.TrimPrefix(ref, "#")
	switch {
	case ref == "" || strings.HasPrefix(ref, "-"):
		return p.skip("invalid reference " + ref)
	case time.Now().After(p.deadline):
		return p.skip("the gh time budget was spent")
	}
	cctx, cancel := context.WithTimeout(ctx, ghCallTimeout)
	defer cancel()
	out, _, err := p.o.Run(cctx, p.o.Folder, nil, "gh", "pr", "view", ref, "--json", "state")
	if err != nil {
		return p.skip(err.Error())
	}
	var v struct {
		State string `json:"state"`
	}
	if err := json.Unmarshal(out, &v); err != nil || v.State == "" {
		return p.skip("unreadable gh output")
	}
	return strings.ToUpper(v.State)
}

// skip counts a pull request whose state could not be read; Check turns
// the count into a note and withholds PRChecked.
func (p *prChecker) skip(why string) string {
	if p.skipped == 0 {
		p.firstErr = clipNote(why)
	}
	p.skipped++
	return ""
}

// summary is the note for the skipped pull requests, "" when none were.
func (p *prChecker) summary() string {
	if p.skipped == 0 {
		return ""
	}
	return fmt.Sprintf("the state of %d pull request(s) could not be read (%s)", p.skipped, p.firstErr)
}

func clipNote(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 160 {
		return string(r[:159]) + "…"
	}
	return s
}

func (p *prChecker) finding(ctx context.Context, tc targetCtx) (Finding, bool) {
	ref := tc.prRef
	switch st := p.state(ctx, ref); {
	case st == "MERGED" && !isClosed(tc.status):
		return tc.mk(KindMergedOpen, fmt.Sprintf("pull request %s is merged", ref), mergedOpenFix(tc)), true
	case st == "OPEN" && tc.status == "done" && !tc.sharedRef:
		return tc.mk(KindDoneUnmerged, fmt.Sprintf("pull request %s is still open", ref), fixDoneUnmerged), true
	case st == "CLOSED" && !isClosed(tc.status):
		return tc.mk(KindPRClosed, fmt.Sprintf("pull request %s was closed without a merge", ref), fixPRClosed), true
	}
	return Finding{}, false
}

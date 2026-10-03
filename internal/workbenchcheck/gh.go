package workbenchcheck

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
	if ok, note := GHStatus(ctx, o.Folder, o.Run); !ok {
		p.notes = append(p.notes, note)
		return p
	}
	p.available = true
	return p
}

// GHStatus probes the gh CLI with `gh auth status` run in folder: ok when it
// is installed and signed in, otherwise a note saying why pull request
// states are not checked.
func GHStatus(ctx context.Context, folder string, run Runner) (ok bool, note string) {
	cctx, cancel := context.WithTimeout(ctx, ghCallTimeout)
	defer cancel()
	if _, _, err := run(cctx, folder, nil, "gh", "auth", "status"); err != nil {
		switch {
		case errors.Is(err, exec.ErrNotFound):
			return false, "gh CLI not found; pull request states not checked"
		case cctx.Err() != nil:
			return false, "gh CLI did not answer in time; pull request states not checked"
		default:
			return false, "gh CLI is not signed in or failed (" + ClipNote(err.Error()) + "); pull request states not checked"
		}
	}
	return true, ""
}

// errGHUnreadable: gh ran, but its output was not the JSON asked for.
var errGHUnreadable = errors.New("unreadable gh output")

// GHJSON runs gh with args in folder and decodes its JSON output into v.
func GHJSON(ctx context.Context, folder string, run Runner, v any, args ...string) error {
	out, _, err := run(ctx, folder, nil, "gh", args...)
	if err != nil {
		return err
	}
	if json.Unmarshal(out, v) != nil {
		return errGHUnreadable
	}
	return nil
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
	var v struct {
		State string `json:"state"`
	}
	if err := GHJSON(cctx, p.o.Folder, p.o.Run, &v, "pr", "view", ref, "--json", "state"); err != nil {
		return p.skip(err.Error())
	}
	if v.State == "" {
		return p.skip(errGHUnreadable.Error())
	}
	return strings.ToUpper(v.State)
}

// skip counts a pull request whose state could not be read; Check turns
// the count into a note and withholds PRChecked.
func (p *prChecker) skip(why string) string {
	if p.skipped == 0 {
		p.firstErr = ClipNote(why)
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

// ClipNote folds s onto one line of at most 160 runes, for a note.
func ClipNote(s string) string {
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

package lockstats

import (
	"bytes"
	"fmt"
	"io"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

const (
	// maxTextSites and maxTextBusy cap the text tables; --json has all rows.
	maxTextSites = 15
	maxTextBusy  = 20
	textTSLayout = "2006-01-02 15:04:05.000"
)

// WriteText prints r as compact aligned tables. The report is rendered into
// a buffer first (writes to it cannot fail) and written to w once.
func WriteText(w io.Writer, r Report) error {
	var buf bytes.Buffer
	tw := tabwriter.NewWriter(&buf, 0, 4, 2, ' ', 0)
	p := func(format string, a ...any) { _, _ = fmt.Fprintf(tw, format, a...) }

	p("Lock events %s .. %s UTC (last %s): %d events\n",
		r.Window.From.UTC().Format(textTSLayout), r.Window.To.UTC().Format(textTSLayout),
		time.Duration(r.Window.SinceSeconds)*time.Second, r.Window.Events)
	if r.Malformed > 0 {
		p("%d malformed lines skipped\n", r.Malformed)
	}

	p("\nSlow write sites (by total hold)\n")
	if len(r.Sites) == 0 {
		p("  none\n")
	} else {
		p("  SITE\tCOUNT\tTOTAL_HOLD_MS\tMAX_HOLD_MS\t>1S\t>5S\tMAX_WAIT_MS\n")
		for _, s := range r.Sites[:min(len(r.Sites), maxTextSites)] {
			p("  %s\t%d\t%d\t%d\t%d\t%d\t%d\n", s.Site, s.Count, s.TotalHoldMS, s.MaxHoldMS, s.Over1s, s.Over5s, s.MaxWaitMS)
		}
		if len(r.Sites) > maxTextSites {
			p("  ... %d more sites (--json for all)\n", len(r.Sites)-maxTextSites)
		}
	}

	p("\nBusy errors\n")
	if len(r.Busy) == 0 {
		p("  none\n")
	} else {
		p("  PROC\tSITE\tCOUNT\tBUSY_TIMEOUT_MS\tERR\n")
		for _, g := range r.Busy {
			timeouts := make([]string, len(g.BusyTimeoutsMS))
			for i, t := range g.BusyTimeoutsMS {
				timeouts[i] = strconv.FormatInt(t, 10)
			}
			p("  %s\t%s\t%d\t%s\t%s\n", g.Proc, g.Site, g.Count, strings.Join(timeouts, ","), strings.Join(g.Errs, ","))
		}
	}
	_ = tw.Flush() // a bytes.Buffer write never fails

	// The holder list is indented free text, not a table.
	p = func(format string, a ...any) { _, _ = fmt.Fprintf(&buf, format, a...) }
	p("\nWho held the lock (slow tx/exec of other pids overlapping each busy wait)\n")
	busy := r.BusyHolders
	if len(busy) == 0 {
		p("  none\n")
	} else if len(busy) > maxTextBusy {
		p("  latest %d of %d (--json for all)\n", maxTextBusy, len(busy))
		busy = busy[len(busy)-maxTextBusy:]
	}
	for _, b := range busy {
		p("  %s  %s pid %d  %s  busy_timeout %dms\n",
			b.TS.UTC().Format(textTSLayout), b.Proc, b.PID, b.Site, b.BusyTimeoutMS)
		if len(b.Holders) == 0 {
			p("    no recorded holder (holds under the threshold are not logged)\n")
		}
		for _, h := range b.Holders {
			p("    held by %s pid %d %s %s hold %dms, ended %s\n",
				h.Proc, h.PID, h.Kind, h.Site, h.HoldMS, h.TS.UTC().Format(textTSLayout))
		}
	}

	tw = tabwriter.NewWriter(&buf, 0, 4, 2, ' ', 0)
	p = func(format string, a ...any) { _, _ = fmt.Fprintf(tw, format, a...) }
	p("\nWAL size (bytes)\n")
	if r.WAL.Samples == 0 {
		p("  none\n")
	} else {
		p("  %d samples  min %d  median %d  max %d\n", r.WAL.Samples, r.WAL.MinBytes, r.WAL.MedianBytes, r.WAL.MaxBytes)
		p("  %d checkpoints, %d busy, %d incomplete", r.WAL.Checkpoints, r.WAL.CheckpointBusy, r.WAL.CheckpointIncomplete)
		if r.WAL.CheckpointUnparsed > 0 {
			p(", %d unparsed", r.WAL.CheckpointUnparsed)
		}
		if r.WAL.LastCheckpoint != "" {
			p("; last %s", r.WAL.LastCheckpoint)
		}
		p("\n")
	}

	p("\nPool waits\n")
	if len(r.PoolWait) == 0 {
		p("  none\n")
	} else {
		p("  PROC\tCOUNT\tTOTAL_WAIT_MS\tMAX_WAIT_MS\n")
		for _, pw := range r.PoolWait {
			p("  %s\t%d\t%d\t%d\n", pw.Proc, pw.Count, pw.TotalWaitMS, pw.MaxWaitMS)
		}
	}
	_ = tw.Flush() // a bytes.Buffer write never fails
	if _, err := buf.WriteTo(w); err != nil {
		return fmt.Errorf("writing report: %w", err)
	}
	return nil
}

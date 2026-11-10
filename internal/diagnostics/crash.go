package diagnostics

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"os"
	"regexp"
	"time"
)

// CrashScan is what ScanCrashes found in the logs. Place is "" when the
// newest crash's trace has no watchtower/ frame ("location unknown"); Time
// is UTC and meaningful only with TimeKnown. The panic message itself is
// never kept.
type CrashScan struct {
	Count     int
	Time      time.Time
	TimeKnown bool
	Place     string
	Stopped   bool
	ScannedMB int
	NoLogs    bool
}

const (
	// crashHeaderWindow is how many lines after a "panic: "/"fatal error: "
	// line may hold the goroutine header for it to count as a crash.
	crashHeaderWindow = 5
	// crashLineBuffer is the reader buffer; a longer line is kept only up
	// to this size (crash and frame lines are short) and the rest skipped.
	crashLineBuffer = 1 << 20
	// logTimeLayout is log.LstdFlags' prefix, as cmd/logfile.go writes it.
	logTimeLayout = "2006/01/02 15:04:05"
)

var goroutineHeader = regexp.MustCompile(`^goroutine \d+ \[`)

type crashHit struct {
	time      time.Time
	timeKnown bool
	place     string
}

// ScanCrashes streams files — in the order watchtower.log, watchtower.log.1,
// daemon.log, which is also the tie order — whole, line by line, and counts
// Go runtime crashes: a line starting with "panic: " or "fatal error: "
// followed within 5 lines by a "goroutine N [" header. A crash's time is the
// nearest preceding timestamped line in the same file (parsed in loc,
// returned in UTC); its place is the first frame of that goroutine trace
// starting with "watchtower/". The newest crash is chosen by time, ties and
// unknown times by file order. The deadline is shared by all files and
// checked between lines; hitting it sets Stopped and ScannedMB. Missing or
// unreadable files are skipped; all skipped sets NoLogs.
func ScanCrashes(files []string, deadline time.Time, now func() time.Time, loc *time.Location) CrashScan {
	if loc == nil {
		loc = time.Local
	}
	var (
		out     CrashScan
		scanned int64
		best    *crashHit
		opened  int
	)
	for _, path := range files {
		if out.Stopped {
			break
		}
		f, err := openRegular(path)
		if err != nil {
			continue
		}
		opened++
		count, last, n, stopped := scanCrashFile(f, deadline, now, loc)
		_ = f.Close()
		scanned += n
		out.Count += count
		out.Stopped = stopped
		if last != nil && (best == nil ||
			(best.timeKnown && last.timeKnown && last.time.After(best.time))) {
			best = last
		}
	}
	out.NoLogs = opened == 0
	if out.Stopped {
		out.ScannedMB = int((scanned + 1<<20 - 1) >> 20)
	}
	if best != nil {
		out.Time, out.TimeKnown, out.Place = best.time, best.timeKnown, best.place
	}
	return out
}

func openRegular(path string) (*os.File, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	if st, err := f.Stat(); err != nil || !st.Mode().IsRegular() {
		_ = f.Close()
		return nil, errors.New("not a regular file")
	}
	return f, nil
}

// scanCrashFile returns the file's crash count, its last crash, the bytes
// consumed and whether the deadline stopped it.
func scanCrashFile(r io.Reader, deadline time.Time, now func() time.Time, loc *time.Location) (
	count int, last *crashHit, consumed int64, stopped bool,
) {
	br := bufio.NewReaderSize(r, crashLineBuffer)
	var (
		lastTime      time.Time
		lastTimeKnown bool
		pending       *crashHit // a panic/fatal line waiting for its header
		pendingLeft   int
		inTrace       bool // inside the crashing goroutine's frames
	)
	for {
		if !now().Before(deadline) {
			return count, last, consumed, true
		}
		line, n, err := readLogLine(br)
		consumed += n
		if n == 0 && err != nil {
			return count, last, consumed, false
		}
		line = bytes.TrimSuffix(line, []byte("\r"))

		switch {
		case bytes.HasPrefix(line, []byte("panic: ")) || bytes.HasPrefix(line, []byte("fatal error: ")):
			pending = &crashHit{time: lastTime, timeKnown: lastTimeKnown}
			pendingLeft = crashHeaderWindow
			inTrace = false
		case pending != nil && goroutineHeader.Match(line):
			count++
			last, pending, inTrace = pending, nil, true
		case pending != nil:
			if pendingLeft--; pendingLeft == 0 {
				pending = nil
			}
		case inTrace:
			if len(line) == 0 {
				inTrace = false
			} else if last.place == "" && bytes.HasPrefix(line, []byte("watchtower/")) {
				last.place = frameFunction(line)
				inTrace = false
			}
		}
		if t, ok := parseLogTime(line, loc); ok {
			lastTime, lastTimeKnown = t, true
			inTrace = false
		}
		if err != nil {
			return count, last, consumed, false
		}
	}
}

// readLogLine reads one line without its newline. A line longer than the
// buffer keeps its first buffer-full and the rest is consumed and dropped.
// n is the number of bytes consumed, newline included. The line is valid
// until the next read.
func readLogLine(br *bufio.Reader) (line []byte, n int64, err error) {
	chunk, err := br.ReadSlice('\n')
	n = int64(len(chunk))
	line = chunk
	if errors.Is(err, bufio.ErrBufferFull) {
		line = append([]byte(nil), chunk...)
	}
	for errors.Is(err, bufio.ErrBufferFull) {
		chunk, err = br.ReadSlice('\n')
		n += int64(len(chunk))
	}
	return bytes.TrimSuffix(line, []byte("\n")), n, err
}

func parseLogTime(line []byte, loc *time.Location) (time.Time, bool) {
	if len(line) < len(logTimeLayout) {
		return time.Time{}, false
	}
	t, err := time.ParseInLocation(logTimeLayout, string(line[:len(logTimeLayout)]), loc)
	if err != nil {
		return time.Time{}, false
	}
	return t.UTC(), true
}

// frameFunction cuts a frame line's argument list:
// "watchtower/x.(*T).run(0xc0, {0x1})" → "watchtower/x.(*T).run".
func frameFunction(line []byte) string {
	if bytes.HasSuffix(line, []byte(")")) {
		if i := bytes.LastIndexByte(line, '('); i > 0 {
			line = line[:i]
		}
	}
	return string(line)
}

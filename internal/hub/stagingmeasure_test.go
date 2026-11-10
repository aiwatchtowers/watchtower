package hub

// The pure parts of the staging traffic measurement (relay client Phase 5,
// "Measuring the cost" M-B, traffic half): the republish line's reading, the
// synthetic workload's presets and the per-rotation verdict. The harness
// itself is interop_staging_measure_test.go (build tags interop and
// relaystaging); these build and run with the package's default tests.

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// rotationLimitBytes is the owner's threshold per rotation, both for the
// hub's upload and for the phone's download (ask #1131): 1 GB.
const rotationLimitBytes int64 = 1_000_000_000

// republishReading is one `hub: rotation republish: …` line.
type republishReading struct {
	Outcome       string // complete, resumed or interrupted
	Records       int
	AssetBytes    int64
	EnvelopeBytes int64
	Seconds       int64
}

// Upload is the hub's upload the line accounts for: asset plus envelope bytes.
func (r republishReading) Upload() int64 { return r.AssetBytes + r.EnvelopeBytes }

var republishReadingRE = regexp.MustCompile(`hub: rotation republish: (complete|resumed|interrupted), (\d+) records, (\d+) asset bytes, (\d+) envelope bytes, (\d+) s`)

// parseRepublish reads the republish line in a log line (with or without the
// log package's date prefix); ok is false when the line holds none.
func parseRepublish(line string) (republishReading, bool) {
	m := republishReadingRE.FindStringSubmatch(line)
	if m == nil {
		return republishReading{}, false
	}
	n, err1 := strconv.Atoi(m[2])
	a, err2 := strconv.ParseInt(m[3], 10, 64)
	e, err3 := strconv.ParseInt(m[4], 10, 64)
	s, err4 := strconv.ParseInt(m[5], 10, 64)
	if err := errors.Join(err1, err2, err3, err4); err != nil {
		return republishReading{}, false
	}
	return republishReading{Outcome: m[1], Records: n, AssetBytes: a, EnvelopeBytes: e, Seconds: s}, true
}

// measureWorkload is the synthetic slice set the measured hub publishes:
// Transcripts meeting_transcript records each with a sealed asset of
// AssetBytes plain bytes, and Records inbox_item records of RecordBytes of
// payload each. No real content.
type measureWorkload struct {
	Name        string
	Transcripts int
	AssetBytes  int64
	Records     int
	RecordBytes int
}

// The relay's limits a workload must fit (staging: envelope 1 MiB,
// attachment 100 MiB, hub storage 5 GiB).
const (
	maxMeasureAsset    int64 = 100 << 20
	maxMeasureRecord         = 900 << 10 // the hub's own envelope ceiling
	maxMeasureHubStore int64 = 5 << 30
	assetSealSlack           = 1.01 // chunk tags and header, generously
)

var workloadPresets = map[string]measureWorkload{
	// The owner's size (M-A): a handful of transcripts, about 1 800 records.
	"owner": {Name: "owner", Transcripts: 2, AssetBytes: 64 << 10, Records: 1800, RecordBytes: 512},
	// The plan's worst case scaled to fit staging: old and new attachments
	// of one rotation stay under the hub's 5 GiB.
	"heavy": {Name: "heavy", Transcripts: 50, AssetBytes: 20 << 20, Records: 1800, RecordBytes: 512},
}

// parseWorkload reads a preset name ("" is owner) or a custom
// "transcripts=N,asset_bytes=B,records=R,record_bytes=P" (keys optional,
// starting from owner's values), and checks it fits the relay's limits.
func parseWorkload(s string) (measureWorkload, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		s = "owner"
	}
	if w, ok := workloadPresets[s]; ok {
		return w, nil
	}
	w := workloadPresets["owner"]
	w.Name = "custom"
	for _, kv := range strings.Split(s, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(kv), "=")
		if !ok {
			return measureWorkload{}, fmt.Errorf("workload %q: want a preset (owner, heavy) or key=value pairs", s)
		}
		n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil || n < 0 {
			return measureWorkload{}, fmt.Errorf("workload %q: %s is not a non-negative number", s, k)
		}
		switch strings.TrimSpace(k) {
		case "transcripts":
			w.Transcripts = int(n)
		case "asset_bytes":
			w.AssetBytes = n
		case "records":
			w.Records = int(n)
		case "record_bytes":
			w.RecordBytes = int(n)
		default:
			return measureWorkload{}, fmt.Errorf("workload %q: unknown key %q", s, k)
		}
	}
	return w, w.check()
}

func (w measureWorkload) check() error {
	switch {
	case w.Transcripts > 0 && w.AssetBytes <= 0:
		return errors.New("workload: a transcript needs asset_bytes > 0")
	case float64(w.AssetBytes)*assetSealSlack > float64(maxMeasureAsset):
		return fmt.Errorf("workload: asset_bytes %d passes the relay's 100 MiB attachment cap once sealed", w.AssetBytes)
	case w.RecordBytes <= 0 || w.RecordBytes > maxMeasureRecord:
		return fmt.Errorf("workload: record_bytes %d is outside 1…%d", w.RecordBytes, maxMeasureRecord)
	case w.Records+w.Transcripts == 0:
		return errors.New("workload: nothing to publish")
	case 2*float64(w.Transcripts)*float64(w.AssetBytes)*assetSealSlack > float64(maxMeasureHubStore):
		return fmt.Errorf("workload: old and new attachments (%d × %d B, twice) pass the hub's 5 GiB", w.Transcripts, w.AssetBytes)
	}
	return nil
}

func (w measureWorkload) String() string {
	return fmt.Sprintf("%s: %d transcripts × %d B assets, %d records × %d B", w.Name, w.Transcripts, w.AssetBytes, w.Records, w.RecordBytes)
}

// judgeRotation is one rotation's verdict: only a complete line counts, and
// the hub's upload (the line) and the phone's download each stay at or under
// rotationLimitBytes.
func judgeRotation(r republishReading, phoneDownload int64) (bool, string) {
	var why []string
	if r.Outcome != "complete" {
		why = append(why, r.Outcome+" does not count: double the epoch and run again")
	}
	if r.Upload() > rotationLimitBytes {
		why = append(why, fmt.Sprintf("hub upload %d B > %d B", r.Upload(), rotationLimitBytes))
	}
	if phoneDownload > rotationLimitBytes {
		why = append(why, fmt.Sprintf("phone download %d B > %d B", phoneDownload, rotationLimitBytes))
	}
	if len(why) == 0 {
		return true, "PASS"
	}
	return false, "FAIL: " + strings.Join(why, "; ")
}

func TestStagingMeasure_ParseRepublish(t *testing.T) {
	got, ok := parseRepublish("2026/11/10 12:00:00 hub: rotation republish: complete, 1803, records, 1 asset bytes, 2 envelope bytes, 3 s")
	if ok {
		t.Fatalf("malformed line parsed: %+v", got)
	}
	got, ok = parseRepublish("2026/11/10 12:00:00 hub: rotation republish: complete, 1803 records, 131200 asset bytes, 1900000 envelope bytes, 42 s")
	want := republishReading{Outcome: "complete", Records: 1803, AssetBytes: 131200, EnvelopeBytes: 1900000, Seconds: 42}
	if !ok || got != want || got.Upload() != 2031200 {
		t.Fatalf("parse = %+v %v, want %+v", got, ok, want)
	}
	if got, ok := parseRepublish("hub: rotation republish: interrupted, 5 records, 0 asset bytes, 1280 envelope bytes, 0 s"); !ok || got.Outcome != "interrupted" {
		t.Fatalf("interrupted line: %+v %v", got, ok)
	}
	if _, ok := parseRepublish("hub slices: rotation republish not counted (x)"); ok {
		t.Fatal("the not-counted line is no reading")
	}
}

func TestStagingMeasure_ParseWorkload(t *testing.T) {
	for _, name := range []string{"", "owner", "heavy"} {
		w, err := parseWorkload(name)
		if err != nil {
			t.Fatalf("%q: %v", name, err)
		}
		if err := w.check(); err != nil {
			t.Fatalf("preset %q does not fit: %v", name, err)
		}
	}
	w, err := parseWorkload("transcripts=3, asset_bytes=1024,records=10")
	if err != nil || w.Transcripts != 3 || w.AssetBytes != 1024 || w.Records != 10 || w.RecordBytes != 512 || w.Name != "custom" {
		t.Fatalf("custom = %+v, %v", w, err)
	}
	for _, bad := range []string{
		"huge", "records=x", "records=-1", "colour=3",
		"asset_bytes=104857600",                  // 100 MiB plain passes the cap once sealed
		"transcripts=40,asset_bytes=80000000",    // old+new past 5 GiB
		"transcripts=0,records=0",                // nothing
		"record_bytes=0", "record_bytes=1000000", // envelope ceiling
	} {
		if _, err := parseWorkload(bad); err == nil {
			t.Errorf("%q parsed", bad)
		}
	}
}

func TestStagingMeasure_JudgeRotation(t *testing.T) {
	ok := republishReading{Outcome: "complete", AssetBytes: 600_000_000, EnvelopeBytes: 400_000_000}
	if pass, why := judgeRotation(ok, rotationLimitBytes); !pass {
		t.Fatalf("at the limit: %s", why)
	}
	over := ok
	over.EnvelopeBytes++
	if pass, why := judgeRotation(over, 0); pass || !strings.Contains(why, "hub upload") {
		t.Fatalf("hub over: %v %s", pass, why)
	}
	if pass, why := judgeRotation(ok, rotationLimitBytes+1); pass || !strings.Contains(why, "phone download") {
		t.Fatalf("phone over: %v %s", pass, why)
	}
	small := republishReading{Outcome: "interrupted", EnvelopeBytes: 10}
	if pass, why := judgeRotation(small, 10); pass || !strings.Contains(why, "double the epoch") {
		t.Fatalf("interrupted: %v %s", pass, why)
	}
}

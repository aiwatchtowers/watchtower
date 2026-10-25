package specreview

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "rewrite testdata/result_keys.golden")

const testDoc = "# Title\n\nGoal: the owner can mute a channel for a day.\n\n## Behaviour\n\nMuting lasts twenty-four hours\nand then expires by itself.\n\n```\n## not a heading\n```\n\n### Detail\n\nThe mute button sits in the channel header.\n\n## Decisions\n\n- Mute state lives in the local database.\n"

func testSources() Sources {
	return Sources{
		Doc:          testDoc,
		Conversation: map[string]string{"entry:1": "Please let me mute a channel for a day, nothing more."},
		Asks:         map[string]string{"ask:1": "Yes, keep the state local to this Mac."},
	}
}

func parseOne(t *testing.T, raw string, src Sources) Result {
	t.Helper()
	r, err := Parse(raw, src, Spec)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return r
}

func agreementJSON(text, quote string) string {
	b, _ := json.Marshal(map[string]any{
		"text": text, "status": "as_agreed", "note": "n",
		"source": map[string]string{"kind": "conversation", "ref": "entry:1", "quote": "mute a channel for a day"},
		"where":  map[string]string{"heading": "## Behaviour", "quote": quote},
	})
	return string(b)
}

func TestClassifyDoc(t *testing.T) {
	cases := []struct {
		explicit, path string
		want           DocType
	}{
		{"plan", "docs/superpowers/specs/x-design.md", Plan},
		{"", "docs/superpowers/specs/x-design.md", Spec},
		{"", "docs/superpowers/plans/x.md", Plan},
		{"", "x-design.md", Spec},
		{"", "README.md", Other},
		{"bogus", "docs/superpowers/plans/x.md", Plan},
		{"bogus", "README.md", Other},
	}
	for _, c := range cases {
		if got := ClassifyDoc(c.explicit, c.path); got != c.want {
			t.Errorf("ClassifyDoc(%q,%q) = %q, want %q", c.explicit, c.path, got, c.want)
		}
	}
}

func TestChapters_SpecAndPlan(t *testing.T) {
	ch := Chapters(testDoc, Spec)
	var heads []string
	for _, c := range ch {
		heads = append(heads, c.Key+"="+c.Heading)
	}
	if got, want := strings.Join(heads, "|"), "ch:0=Intro|ch:1=Behaviour|ch:2=Decisions"; got != want {
		t.Fatalf("spec chapters = %s, want %s", got, want)
	}
	if !strings.Contains(testDoc[ch[1].Start:ch[1].End], "### Detail") {
		t.Error("deeper level should fold into its chapter")
	}
	if ch[2].End != len(testDoc) || ch[1].End != ch[2].Start {
		t.Error("chapters must be contiguous to the end of the document")
	}

	plan := "Intro text\n\n## Notes\n\n### Task 1: One\n\nbody\n\n### Task 2: Two\n\nbody 2\n"
	pc := Chapters(plan, Plan)
	if len(pc) != 3 || pc[0].Key != "ch:0" || pc[1].Heading != "Task 1: One" || pc[2].Key != "ch:2" || pc[2].Heading != "Task 2: Two" {
		t.Fatalf("plan chapters = %+v", pc)
	}
	if !strings.Contains(plan[pc[0].Start:pc[0].End], "## Notes") {
		t.Error("a ## heading in a plan folds into the intro")
	}

	if got := Chapters("\n  \n## A\nx\n", Spec); len(got) != 1 || got[0].Key != "ch:1" {
		t.Errorf("blank intro must be absent: %+v", got)
	}
	if got := Chapters("   \n", Spec); len(got) != 0 {
		t.Errorf("blank doc has no chapters: %+v", got)
	}
}

func TestSpecReview03_ParseDropsInventedQuotes(t *testing.T) {
	raw := `{"summary":"s","agreements":[` +
		agreementJSON("lasts a day", "Muting lasts twenty-four hours") + "," +
		agreementJSON("never expires", "Muting never expires, ever") + `]}`
	r := parseOne(t, raw, testSources())
	if len(r.Agreements) != 1 || r.Dropped != 1 {
		t.Fatalf("kept %d dropped %d, want 1/1", len(r.Agreements), r.Dropped)
	}
	if r.Agreements[0].Text != "lasts a day" || r.Agreements[0].Chapter != "ch:1" || !strings.HasPrefix(r.Agreements[0].Key, "ag:") || len(r.Agreements[0].Key) != 15 {
		t.Errorf("agreement = %+v", r.Agreements[0])
	}
}

func TestParse_WhitespaceNormalised(t *testing.T) {
	// the doc has a line break between "hours" and "and"
	raw := `{"summary":"s","agreements":[` +
		agreementJSON("a", "Muting lasts twenty-four hours and then expires") + "," +
		agreementJSON("b", "Muting lasts twenty-four hours and then expires by herself") + `]}`
	r := parseOne(t, raw, testSources())
	if len(r.Agreements) != 1 || r.Agreements[0].Text != "a" || r.Dropped != 1 {
		t.Fatalf("got %+v dropped %d", r.Agreements, r.Dropped)
	}
}

func TestParse_WeakQuoteAndAnchorRules(t *testing.T) {
	raw := `{"summary":"s","agreements":[` +
		agreementJSON("short", "Muting") + "," + // under 8 runes
		agreementJSON("wrong heading, unique quote", "The mute button sits in the channel header") + "," +
		agreementJSON("known heading, quote elsewhere", "Mute state lives in the local database") + `]}`
	raw = strings.Replace(raw, `"heading":"## Behaviour","quote":"The mute button`, `"heading":"## Nowhere","quote":"The mute button`, 1)
	r := parseOne(t, raw, testSources())
	if len(r.Agreements) != 1 || r.Dropped != 2 {
		t.Fatalf("got %+v dropped %d", r.Agreements, r.Dropped)
	}
	if a := r.Agreements[0]; a.Chapter != "ch:1" || a.Where.Heading != "Behaviour" {
		t.Errorf("re-homed agreement = %+v", a)
	}
}

func TestParse_SourceRefMustExist(t *testing.T) {
	good := `{"text":"a","status":"as_agreed","source":{"kind":"ask","ref":"ask:1","quote":"keep the state local"}}`
	bad := `{"text":"b","status":"as_agreed","source":{"kind":"ask","ref":"ask:999","quote":"keep the state local"}}`
	wrongText := `{"text":"c","status":"as_agreed","source":{"kind":"ask","ref":"ask:1","quote":"put it in the cloud"}}`
	badEnum := `{"text":"d","status":"maybe","source":{"kind":"ask","ref":"ask:1","quote":"keep the state local"}}`
	r := parseOne(t, `{"summary":"s","agreements":[`+good+","+bad+","+wrongText+","+badEnum+`]}`, testSources())
	if len(r.Agreements) != 1 || r.Agreements[0].Text != "a" || r.Dropped != 3 {
		t.Fatalf("got %+v dropped %d", r.Agreements, r.Dropped)
	}
	if r.Agreements[0].Where != nil || r.Agreements[0].Chapter != "" {
		t.Error("an agreement without an anchor has no chapter")
	}
}

func TestParse_KeysStable(t *testing.T) {
	a := agreementJSON("lasts a day", "Muting lasts twenty-four hours")
	b := agreementJSON("button in header", "The mute button sits in the channel header")
	r1 := parseOne(t, `{"summary":"s","agreements":[`+a+","+b+`]}`, testSources())
	r2 := parseOne(t, `{"summary":"s","agreements":[`+b+","+a+`]}`, testSources())
	r3 := parseOne(t, `{"summary":"s","agreements":[`+a+","+b+`]}`, testSources())
	if len(r1.Agreements) != 2 || r1.Agreements[0].Key != r3.Agreements[0].Key || r1.Agreements[1].Key != r3.Agreements[1].Key {
		t.Fatalf("same raw, different keys: %+v vs %+v", r1.Agreements, r3.Agreements)
	}
	if r1.Agreements[0].Key != r2.Agreements[1].Key || r1.Agreements[1].Key != r2.Agreements[0].Key || r1.Agreements[0].Key == r1.Agreements[1].Key {
		t.Fatalf("reordering moved keys: %+v vs %+v", r1.Agreements, r2.Agreements)
	}
	// whitespace in the text does not change the key; a duplicate is dropped
	dup := strings.Replace(a, "lasts a day", "lasts   a\\nday", 1)
	r4 := parseOne(t, `{"summary":"s","agreements":[`+a+","+dup+`]}`, testSources())
	if len(r4.Agreements) != 1 || r4.Dropped != 1 {
		t.Errorf("duplicate kept: %+v", r4)
	}
}

func TestParse_EvidenceOutsideFolderDropped(t *testing.T) {
	parent := t.TempDir()
	folder := filepath.Join(parent, "repo")
	if err := os.MkdirAll(filepath.Join(folder, "pkg"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "pkg", "a.go"), []byte("package pkg\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parent, "secret.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	src := testSources()
	src.Folder = folder
	spot := func(path string) string {
		b, _ := json.Marshal(map[string]any{"text": "t " + path, "why": "w", "evidence": map[string]any{"path": path, "line": 1}})
		return string(b)
	}
	raw := `{"summary":"s","blind_spots":[` + strings.Join([]string{
		spot("pkg/a.go"), spot("../secret.txt"), spot(filepath.Join(parent, "secret.txt")),
		spot("/etc/passwd"), spot("../etc/passwd"), spot("pkg"), spot("pkg/missing.go"),
	}, ",") + `]}`
	r := parseOne(t, raw, src)
	if len(r.BlindSpots) != 1 || r.BlindSpots[0].Evidence.Path != "pkg/a.go" || r.Dropped != 6 {
		t.Fatalf("got %+v dropped %d", r.BlindSpots, r.Dropped)
	}
	if !strings.HasPrefix(r.BlindSpots[0].Key, "bs:") {
		t.Errorf("key = %q", r.BlindSpots[0].Key)
	}

	// a FIFO must not hang Parse
	fifo := filepath.Join(folder, "pipe")
	if err := syscall.Mkfifo(fifo, 0o600); err == nil {
		done := make(chan Result, 1)
		go func() { done <- parseOne(t, `{"summary":"s","blind_spots":[`+spot("pipe")+`]}`, src) }()
		select {
		case r := <-done:
			if len(r.BlindSpots) != 0 {
				t.Error("FIFO accepted as evidence")
			}
		case <-time.After(5 * time.Second):
			t.Fatal("Parse hangs on a FIFO evidence path")
		}
	}
	// a symlink out of the folder is refused too
	if err := os.Symlink(filepath.Join(parent, "secret.txt"), filepath.Join(folder, "link.txt")); err == nil {
		if r := parseOne(t, `{"summary":"s","blind_spots":[`+spot("link.txt")+`]}`, src); len(r.BlindSpots) != 0 {
			t.Error("symlink escaping the folder was accepted")
		}
	}
	// no folder: evidence cannot be checked, so it is dropped
	if r := parseOne(t, `{"summary":"s","blind_spots":[`+spot("pkg/a.go")+`]}`, testSources()); len(r.BlindSpots) != 0 {
		t.Error("evidence accepted without a folder")
	}
}

func TestParse_ChecksDecidedResolvedIdea(t *testing.T) {
	src := testSources()
	src.PrevComments = []string{"Please name the retention period explicitly."}
	raw := `{"summary":"  s  ","code_read":true,
	"idea":{"owner_quote":"mute a channel for a day","goal_quote":"the owner can mute a channel","verdict":"matches","note":"n","owner_source":{"kind":"conversation","ref":"entry:1","quote":"mute a channel for a day"}},
	"decided_alone":[{"text":"local db","note":"n","where":{"heading":"Decisions","quote":"Mute state lives in the local database"}},
	                 {"text":"no anchor","where":{"heading":"Decisions","quote":""}}],
	"checks":[{"chapter":"ch:1","lens":"promises","question":"q1","answer":"ok","note":""},
	          {"chapter":"Decisions","lens":"promises","question":"q2","answer":"concern","note":"n"},
	          {"chapter":"ch:9","lens":"promises","question":"q3","answer":"ok"},
	          {"chapter":"ch:1","lens":"promises","question":"q4","answer":"fine"}],
	"resolved":[{"comment_quote":"name the retention period","status":"resolved","note":"n"},
	            {"comment_quote":"a comment nobody wrote","status":"open"}],
	"notes":["trimmed"]}`
	r := parseOne(t, raw, src)
	if r.Summary != "s" || !r.CodeRead || r.Idea.Verdict != "matches" || len(r.DecidedAlone) != 1 || r.DecidedAlone[0].Chapter != "ch:2" {
		t.Errorf("result = %+v", r)
	}
	if len(r.Checks) != 2 || r.Checks[1].Chapter != "ch:2" || !strings.HasPrefix(r.Checks[0].Key, "ck:") {
		t.Errorf("checks = %+v", r.Checks)
	}
	if len(r.Resolved) != 1 || len(r.Notes) != 1 || r.Dropped != 4 {
		t.Errorf("resolved %+v notes %v dropped %d", r.Resolved, r.Notes, r.Dropped)
	}

	bad := strings.Replace(raw, `"goal_quote":"the owner can mute a channel"`, `"goal_quote":"something the doc never says"`, 1)
	if r := parseOne(t, bad, src); r.Idea != (Idea{}) || r.Dropped != 5 {
		t.Errorf("invented goal quote kept: %+v dropped %d", r.Idea, r.Dropped)
	}
}

func TestParse_Failures(t *testing.T) {
	for name, raw := range map[string]string{
		"no json":       "sorry",
		"bad json":      `{"summary": }`,
		"empty summary": `{"summary":"  "}`,
		"array":         `[{"summary":"s"}]`,
	} {
		if _, err := Parse(raw, testSources(), Spec); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	r, err := Parse("```json\n{\"summary\":\"ok\"}\n```", testSources(), Spec)
	if err != nil || r.Agreements == nil || r.Notes == nil || len(r.Chapters) != 3 {
		t.Errorf("fenced reply: %+v %v", r, err)
	}
}

func TestParse_Caps(t *testing.T) {
	var ags []string
	for i := 0; i < maxAgreements+5; i++ {
		ags = append(ags, strings.Replace(agreementJSON("t", "Muting lasts twenty-four hours"), `"text":"t"`, `"text":"t`+strings.Repeat("x", i)+`"`, 1))
	}
	r := parseOne(t, `{"summary":"s","agreements":[`+strings.Join(ags, ",")+`]}`, testSources())
	if len(r.Agreements) != maxAgreements || r.Dropped != 5 {
		t.Errorf("kept %d dropped %d", len(r.Agreements), r.Dropped)
	}
	long := strings.Repeat("я", maxFieldRunes+50)
	r = parseOne(t, `{"summary":"s","blind_spots":[{"text":"`+long+`","why":"w"}]}`, testSources())
	if n := len([]rune(r.BlindSpots[0].Text)); n != maxFieldRunes {
		t.Errorf("text runes = %d", n)
	}
}

func TestResult_JSONKeysPinned(t *testing.T) {
	r := Result{
		Summary: "The spec matches the idea; one promise has no task.",
		Idea: Idea{
			OwnerQuote: "mute a channel for a day", GoalQuote: "the owner can mute a channel for a day",
			Verdict: "matches", Note: "Same scope.",
			OwnerSource: Source{Kind: "conversation", Ref: "entry:1", Quote: "mute a channel for a day"},
		},
		Agreements: []Agreement{{
			Key: "ag:0123456789ab", Text: "A mute lasts one day", Status: "as_agreed", Note: "Stated in Behaviour.", Chapter: "ch:1",
			Source: Source{Kind: "ask", Ref: "ask:1", Quote: "keep the state local"},
			Where:  &Anchor{Heading: "Behaviour", Quote: "Muting lasts twenty-four hours"},
		}},
		DecidedAlone: []DecidedAlone{{
			Key: "da:0123456789ab", Text: "State is kept in the local database", Note: "Nobody asked for it.", Chapter: "ch:2",
			Where: Anchor{Heading: "Decisions", Quote: "Mute state lives in the local database"},
		}},
		BlindSpots: []BlindSpot{{
			Key: "bs:0123456789ab", Text: "No word on muted threads", Why: "A mention would stay silent.", Chapter: "ch:1",
			Where:    &Anchor{Heading: "Behaviour", Quote: "Muting lasts twenty-four hours"},
			Evidence: &Evidence{Path: "internal/notify/mute.go", Line: 42},
		}},
		Checks: []Check{{
			Key: "ck:0123456789ab", Chapter: "ch:1", Lens: "promises", Question: "Does every promise have a task?",
			Answer: "concern", Note: "Expiry has none.",
		}},
		Resolved: []Resolved{{CommentQuote: "name the retention period", Status: "resolved", Note: "Now stated."}},
		Chapters: []Chapter{{Key: "ch:0", Heading: "Intro", Start: 0, End: 40}, {Key: "ch:1", Heading: "Behaviour", Start: 40, End: 200}},
		Notes:    []string{"The conversation was trimmed to the last 50 entries."},
		CodeRead: true,
		Dropped:  2,
	}
	got, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	got = append(got, '\n')
	golden := filepath.Join("testdata", "result_keys.golden")
	if *update {
		if err := os.WriteFile(golden, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("JSON keys changed (a cross-language contract, the Desktop decodes this file); got:\n%s\nwant:\n%s", got, want)
	}
	var back Result
	if err := json.Unmarshal(want, &back); err != nil || back.Dropped != 2 {
		t.Errorf("golden does not decode: %v", err)
	}
}

func FuzzParse(f *testing.F) {
	f.Add(`{"summary":"s","agreements":[{"text":"a","status":"as_agreed","source":{"kind":"ask","ref":"ask:1","quote":"keep the state local"},"where":{"heading":"x","quote":"y"}}]}`)
	f.Add("```json\n{}\n```")
	f.Fuzz(func(t *testing.T, raw string) {
		if r, err := Parse(raw, testSources(), Spec); err == nil && r.Summary == "" {
			t.Fatal("empty summary accepted")
		}
	})
}

func TestParse_DecisionsSourceNeedsDecisionsSection(t *testing.T) {
	mk := func(quote string) string {
		return `{"summary":"s","agreements":[{"text":"a","status":"as_agreed","source":{"kind":"decisions","ref":"","quote":"` + quote + `"}}]}`
	}
	src := testSources()
	if r := parseOne(t, mk("Mute state lives in the local database"), src); len(r.Agreements) != 1 {
		t.Errorf("quote in Decisions dropped: %+v", r)
	}
	if r := parseOne(t, mk("The mute button sits in the channel header"), src); len(r.Agreements) != 0 || r.Dropped != 1 {
		t.Errorf("quote outside Decisions kept: %+v", r)
	}
	src.Doc = "## Behaviour\n\nMuting lasts twenty-four hours.\n"
	if r := parseOne(t, mk("Muting lasts twenty-four hours"), src); len(r.Agreements) != 0 {
		t.Errorf("no Decisions section, entry kept: %+v", r)
	}
}

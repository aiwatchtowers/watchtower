package specreview

import (
	"cmp"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/sessionfeed"
)

// Input caps: the document is never cut; everything else is bounded so the
// whole message stays well inside the provider's input.
const (
	// MaxConversationRunes bounds the conversation block; the newest
	// entries are kept.
	MaxConversationRunes = 120_000

	maxMockupBytes      = 200 << 10 // one linked mockup
	maxMockupsBytes     = 600 << 10 // all mockups together
	maxStyleGuideBytes  = 200 << 10
	maxSpecBytes        = 1 << 20 // a plan's spec
	maxPrevDocRunes     = 300_000 // the previous round's document
	maxSourceAsks       = 100     // answered asks, newest kept
	styleGuidePath      = "docs/design/desktop-style-guide.md"
	dataLine            = "=== DATA ==="
	blockIndent         = "  "
	conversationHeadLen = len("<<<conversation\n")
)

var (
	// mockupLink finds a link to a committed mockup, written from the repo
	// root or relative to the document (../../design/mockups/…).
	mockupLink = regexp.MustCompile(`[A-Za-z0-9._/-]*design/mockups/[A-Za-z0-9._/-]+`)
	// screenWord marks a document or target that involves a screen.
	screenWord = regexp.MustCompile(`(?i)\b(screens?|swiftui|buttons?|sheets?|mockups?|watchtowerdesktop)\b`)
	// planSpecLine is a plan's header line naming its spec.
	planSpecLine = regexp.MustCompile(`(?m)^\*\*Spec:\*\*[ \t]*(.+)$`)
	// specPathText finds a spec path in free text (the target intent).
	specPathText = regexp.MustCompile(`[A-Za-z0-9._/-]*specs/[A-Za-z0-9._/-]+\.md|[A-Za-z0-9._/-]+-design\.md`)
	backticked   = regexp.MustCompile("`([^`]+)`")
	mdLinkTarget = regexp.MustCompile(`\]\(([^)\s]+)\)`)
)

// inputs accumulates the blocks of the user message, the quote sources and
// the notes.
type inputs struct {
	blocks []string
	src    Sources
	notes  []string
}

func (in *inputs) note(format string, args ...any) {
	in.notes = append(in.notes, fmt.Sprintf(format, args...))
}

// add fences body as data: every body line is indented, so no data line can
// close the block or open another.
func (in *inputs) add(head, body string) {
	in.blocks = append(in.blocks, fence(head, body))
}

func fence(head, body string) string {
	return "<<<" + head + "\n" + indentLines(body, blockIndent) + ">>>\n"
}

// indentLines prefixes every non-empty line and ends the text with a newline.
func indentLines(s, prefix string) string {
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return ""
	}
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		if strings.TrimSpace(l) != "" {
			lines[i] = prefix + strings.TrimRight(l, "\r")
		} else {
			lines[i] = ""
		}
	}
	return strings.Join(lines, "\n") + "\n"
}

// BuildInputs assembles what the reviewer reads: the quote sources, the user
// message (the data line, then one fenced block per input) and the notes on
// what was trimmed or could not be read. Files are read through os.Root on
// folder, so nothing outside it is opened. Only a database error fails.
func BuildInputs(ctx context.Context, d Deps, ask *db.OwnerAsk, folder string) (Sources, string, []string, error) {
	in := &inputs{src: Sources{
		Doc: ask.DocSnapshot, Folder: folder,
		Conversation: map[string]string{}, Asks: map[string]string{}, Comments: map[string]string{},
		OwnerWords: map[string][]string{},
	}}
	t := DocType(ask.DocType)

	var root *os.Root
	if r, err := os.OpenRoot(folder); err == nil {
		root = r
		defer func() { _ = r.Close() }()
	} else {
		in.note("the folder could not be opened, no files read: %v", err)
	}

	target, parent, err := in.target(d.DB, ask)
	if err != nil {
		return Sources{}, "", nil, err
	}
	mockups := mockupPaths(ask.DocSnapshot)
	design := len(mockups) > 0 || screenWord.MatchString(ask.DocSnapshot) ||
		(target != nil && screenWord.MatchString(target.Text+"\n"+target.Intent))

	in.add("review", reviewHeader(ask, t, design))
	in.add("document", ask.DocSnapshot)
	in.conversation(ctx, d, ask)
	if err := in.asks(d.DB, ask); err != nil {
		return Sources{}, "", nil, err
	}
	in.targetBlock(target, parent)
	if target != nil {
		if err := in.comments(d.DB, ask); err != nil {
			return Sources{}, "", nil, err
		}
	}
	if t == Plan {
		in.planSpec(root, ask.DocSnapshot, target)
	}
	if err := in.previous(d.DB, ask); err != nil {
		return Sources{}, "", nil, err
	}
	in.mockups(root, mockups)
	if design {
		in.styleGuide(root)
	}
	in.lenses(folder)
	if len(in.notes) > 0 {
		in.add("notes", "- "+strings.Join(in.notes, "\n- "))
	}
	return in.src, dataLine + "\n\n" + strings.Join(in.blocks, "\n"), in.notes, nil
}

func reviewHeader(ask *db.OwnerAsk, t DocType, design bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "doc_type: %s\npath: %s\ntitle: %s\n", t, ask.DocPath, ask.Title)
	if s := strings.TrimSpace(ask.Summary); s != "" {
		fmt.Fprintf(&b, "summary: %s\n", s)
	}
	if s := strings.TrimSpace(ask.Changes); s != "" {
		fmt.Fprintf(&b, "changes since the previous round: %s\n", s)
	}
	b.WriteString("chapters:\n")
	decisions := "absent"
	for _, c := range Chapters(ask.DocSnapshot, t) {
		fmt.Fprintf(&b, "  %s %s\n", c.Key, c.Heading)
		if normHeading(c.Heading) == "decisions" {
			decisions = "present"
		}
	}
	lens := "inactive"
	if design {
		lens = "active"
	}
	fmt.Fprintf(&b, "decisions_section: %s\ndesign_lens: %s\n", decisions, lens)
	return b.String()
}

// conversation renders the session's owner lines, agent text and ask
// answers, newest kept within MaxConversationRunes.
func (in *inputs) conversation(ctx context.Context, d Deps, ask *db.OwnerAsk) {
	if !ask.SessionID.Valid || d.Feed == nil {
		in.note("no session conversation: the ask has no session")
		return
	}
	entries, err := d.Feed(ctx, ask.SessionID.Int64)
	if err != nil {
		in.note("conversation not read: %v", err)
		return
	}
	var heads, refs, texts []string
	byRef := map[string]sessionfeed.Entry{}
	for _, e := range entries {
		if strings.TrimSpace(e.Text) == "" {
			continue
		}
		var head string
		switch e.Kind {
		case sessionfeed.KindOwner, sessionfeed.KindAgent:
			head = string(e.Kind)
		case sessionfeed.KindAskAnswer:
			head = fmt.Sprintf("ask_answer ask #%d %s", e.AskID, oneLineText(e.Title))
		default:
			continue
		}
		ref := "entry:" + e.ID
		if !e.At.IsZero() {
			head += " " + e.At.UTC().Format(time.RFC3339)
		}
		heads, refs, texts = append(heads, "["+ref+"] "+head), append(refs, ref), append(texts, e.Text)
		byRef[ref] = e
	}
	items := make([]string, len(texts))
	for i := range texts {
		items[i] = convItem(heads[i], texts[i])
	}
	budget, first := MaxConversationRunes-conversationHeadLen-len(">>>\n"), len(items)
	for first > 0 {
		n := utf8.RuneCountInString(items[first-1])
		if n > budget {
			break
		}
		budget -= n
		first--
	}
	if first == len(items) && first > 0 {
		// The newest entry alone is over the cap: keep its beginning.
		last := first - 1
		texts[last], items[last] = cutToFit(heads[last], texts[last], budget)
		first = last
		in.note("conversation trimmed: the newest entry was cut to %d characters", utf8.RuneCountInString(texts[last]))
	}
	if first > 0 {
		in.note("conversation trimmed to the last %d of %d entries", len(items)-first, len(items))
	}
	for i := first; i < len(items); i++ {
		in.src.Conversation[refs[i]] = texts[i]
		if e := byRef[refs[i]]; e.Kind == sessionfeed.KindOwner {
			in.src.OwnerWords[refs[i]] = []string{texts[i]}
		} else if e.Kind == sessionfeed.KindAskAnswer {
			// The entry carries the rendered ask, the agent's questions
			// included: only the stored answer's own texts are the owner's.
			in.src.OwnerWords[refs[i]] = askOwnerWords(d.DB, ask.WorkbenchID, e.AskID)
		}
	}
	// Items are already indented: fence them as they are.
	in.blocks = append(in.blocks, "<<<conversation\n"+strings.Join(items[first:], "")+">>>\n")
}

// convItem is one conversation entry as fenced: its head line, then its text
// one level deeper.
func convItem(head, text string) string {
	return indentLines(head+"\n"+indentLines(text, blockIndent), blockIndent)
}

// cutToFit cuts text from its end until its item fits budget runes.
func cutToFit(head, text string, budget int) (string, string) {
	r := []rune(text)
	for {
		item := convItem(head, string(r))
		over := utf8.RuneCountInString(item) - budget
		if over <= 0 || len(r) == 0 {
			return string(r), item
		}
		r = r[:max(0, len(r)-over)]
	}
}

// asks renders the answered asks of the session and of the target (not the
// ask under review, no automation's), newest maxSourceAsks kept.
func (in *inputs) asks(d *db.DB, ask *db.OwnerAsk) error {
	list, err := d.ListOwnerAsks(ask.WorkbenchID, db.OwnerAskFilter{
		Statuses: []string{"answered", "delivered"}, ExcludeAutomation: true,
	})
	if err != nil {
		return err
	}
	var picked []db.OwnerAsk
	for _, a := range list {
		sameSession := ask.SessionID.Valid && a.SessionID == ask.SessionID
		sameTarget := ask.TargetID.Valid && a.TargetID == ask.TargetID
		if a.ID != ask.ID && (sameSession || sameTarget) {
			picked = append(picked, a)
		}
	}
	slices.SortFunc(picked, func(a, b db.OwnerAsk) int { return cmp.Compare(a.ID, b.ID) })
	if len(picked) > maxSourceAsks {
		in.note("asks trimmed to the newest %d of %d", maxSourceAsks, len(picked))
		picked = picked[len(picked)-maxSourceAsks:]
	}
	var b strings.Builder
	for _, a := range picked {
		text, answer, err := asks.RenderStored(a.Kind, a.Payload, a.Answer)
		if err != nil {
			in.note("ask #%d left out: %v", a.ID, err)
			continue
		}
		ref := "ask:" + strconv.FormatInt(a.ID, 10)
		in.src.Asks[ref] = text
		in.src.OwnerWords[ref] = ownerAnswerWords(answer)
		fmt.Fprintf(&b, "[%s] %s %q answered %s\n%s", ref, a.Kind, oneLineText(a.Title), a.AnsweredAt, indentLines(text, blockIndent))
	}
	if b.Len() > 0 {
		in.add("asks", b.String())
	}
	return nil
}

// ownerAnswerWords is what the owner wrote or picked in an answer: the
// chosen labels and free answers, the check notes, the comment bodies and the
// note. The questions, check items, quoted document text and the dismissal
// line are the agent's (or Watchtower's) words.
func ownerAnswerWords(a asks.Answer) []string {
	var out []string
	add := func(s string) {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	for _, q := range a.Answers {
		for _, l := range q.Labels {
			add(l)
		}
		add(q.Other)
	}
	for _, c := range a.Checklist {
		add(c.Note)
	}
	for _, c := range a.Comments {
		add(c.Body)
	}
	add(a.Note)
	return out
}

// askOwnerWords is ownerAnswerWords of an answered ask of the workbench; an
// ask that is gone, open or unreadable has no owner words.
func askOwnerWords(d *db.DB, workbenchID, askID int64) []string {
	a, err := d.GetOwnerAsk(workbenchID, askID)
	if err != nil || (a.Status != "answered" && a.Status != "delivered") {
		return nil
	}
	_, answer, err := asks.RenderStored(a.Kind, a.Payload, a.Answer)
	if err != nil {
		return nil
	}
	return ownerAnswerWords(answer)
}

// target loads the ask's target and its parent; a target that is gone is a
// note, not a failure.
func (in *inputs) target(d *db.DB, ask *db.OwnerAsk) (target, parent *db.Target, err error) {
	if !ask.TargetID.Valid {
		return nil, nil, nil
	}
	if target, err = d.GetTargetByID(int(ask.TargetID.Int64)); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			in.note("the ask's target #%d is gone", ask.TargetID.Int64)
			return nil, nil, nil
		}
		return nil, nil, err
	}
	if target.ParentID.Valid {
		if parent, err = d.GetTargetByID(int(target.ParentID.Int64)); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return target, nil, nil
			}
			return nil, nil, err
		}
	}
	return target, parent, nil
}

func (in *inputs) targetBlock(target, parent *db.Target) {
	if target == nil {
		return
	}
	var b, src strings.Builder
	fmt.Fprintf(&b, "[target] #%d %s\n", target.ID, target.Text)
	src.WriteString(target.Text + "\n")
	if s := strings.TrimSpace(target.Intent); s != "" {
		b.WriteString("intent:\n" + indentLines(s, blockIndent))
		src.WriteString(s + "\n")
	}
	if parent != nil {
		fmt.Fprintf(&b, "parent group: #%d %s\n", parent.ID, parent.Text)
		src.WriteString(parent.Text + "\n")
		if s := strings.TrimSpace(parent.Intent); s != "" {
			b.WriteString("parent intent:\n" + indentLines(s, blockIndent))
			src.WriteString(s + "\n")
		}
	}
	in.src.Target = src.String()
	in.add("target", b.String())
}

func (in *inputs) comments(d *db.DB, ask *db.OwnerAsk) error {
	list, err := d.ListWorkbenchComments(db.WorkbenchCommentFilter{WorkbenchID: ask.WorkbenchID, TargetID: ask.TargetID.Int64})
	if err != nil {
		return err
	}
	var b strings.Builder
	for _, c := range list {
		ref := "comment:" + strconv.FormatInt(c.ID, 10)
		in.src.Comments[ref] = c.Body
		if c.Author == "owner" {
			in.src.OwnerWords[ref] = []string{c.Body}
		}
		fmt.Fprintf(&b, "[%s] %s %s\n%s", ref, c.Author, c.CreatedAt, indentLines(c.Body, blockIndent))
	}
	if b.Len() > 0 {
		in.add("comments", b.String())
	}
	return nil
}

// planSpec reads the spec a plan names on its **Spec:** line, else on its
// target, from inside the folder.
func (in *inputs) planSpec(root *os.Root, doc string, target *db.Target) {
	path := ""
	if m := planSpecLine.FindStringSubmatch(doc); m != nil {
		path = firstPath(m[1])
	} else if target != nil {
		path = specPathText.FindString(target.Intent + "\n" + target.Text)
	}
	if path == "" {
		in.note("plan's spec not found: no **Spec:** line and no spec path on the target")
		return
	}
	if root == nil {
		in.note("plan's spec not found: %s", path)
		return
	}
	data, err := readRootFile(root, path, maxSpecBytes)
	if err != nil {
		in.note("plan's spec not found: %s", path)
		return
	}
	in.src.Spec = data
	in.add("spec "+safeHead(path), data)
}

// firstPath is the path a **Spec:** line names: its first backticked span,
// else its first markdown link target, else its first word.
func firstPath(s string) string {
	if m := backticked.FindStringSubmatch(s); m != nil {
		return strings.TrimSpace(m[1])
	}
	if m := mdLinkTarget.FindStringSubmatch(s); m != nil {
		return m[1]
	}
	if f := strings.Fields(s); len(f) > 0 {
		return strings.TrimRight(f[0], ".,;:")
	}
	return ""
}

// previous renders a re-round's previous document and the owner's comments
// on it (PrevComments, what resolved[] may quote).
func (in *inputs) previous(d *db.DB, ask *db.OwnerAsk) error {
	if !ask.PreviousAskID.Valid {
		return nil
	}
	prev, err := d.GetOwnerAsk(ask.WorkbenchID, ask.PreviousAskID.Int64)
	if errors.Is(err, db.ErrAskNotFound) {
		in.note("the previous round's ask #%d is gone", ask.PreviousAskID.Int64)
		return nil
	}
	if err != nil {
		return err
	}
	doc := prev.DocSnapshot
	if utf8.RuneCountInString(doc) > maxPrevDocRunes {
		doc = string([]rune(doc)[:maxPrevDocRunes])
		in.note("the previous round's document was trimmed to %d characters", maxPrevDocRunes)
	}
	in.add("previous_round ask:"+strconv.FormatInt(prev.ID, 10), doc)
	if err := in.previousFindings(d, prev.ID); err != nil {
		return err
	}
	if prev.Status != "answered" && prev.Status != "delivered" {
		return nil
	}
	_, answer, err := asks.RenderStored(prev.Kind, prev.Payload, prev.Answer)
	if err != nil {
		in.note("the previous round's answer left out: %v", err)
		return nil
	}
	var b strings.Builder
	for i, c := range answer.Comments {
		in.src.PrevComments = append(in.src.PrevComments, c.Body)
		fmt.Fprintf(&b, "[prev:%d] under %q\n", i+1, oneLineText(c.Heading))
		if q := strings.TrimSpace(c.Quote); q != "" {
			b.WriteString("  on the text:\n" + indentLines(q, "    "))
		}
		b.WriteString("  comment:\n" + indentLines(c.Body, "    "))
	}
	if b.Len() > 0 {
		in.add("previous_comments", b.String())
	}
	return nil
}

// previousFindings renders the previous round's stored reviewer result, when
// that review is done, so the reviewer can tell what changed.
func (in *inputs) previousFindings(d *db.DB, prevID int64) error {
	row, err := d.GetSpecReview(prevID)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if row.Status != "done" || row.Result == "" {
		return nil
	}
	var r Result
	if err := json.Unmarshal([]byte(row.Result), &r); err != nil {
		in.note("the previous round's findings left out: %v", err)
		return nil
	}
	var b strings.Builder
	b.WriteString("summary: " + oneLineText(r.Summary) + "\n")
	for _, a := range r.Agreements {
		fmt.Fprintf(&b, "- agreement [%s] %s", a.Status, oneLineText(a.Text))
		if a.Note != "" {
			b.WriteString(" — " + oneLineText(a.Note))
		}
		b.WriteString("\n")
	}
	for _, x := range r.DecidedAlone {
		fmt.Fprintf(&b, "- decided alone: %s\n", oneLineText(x.Text))
	}
	for _, x := range r.BlindSpots {
		fmt.Fprintf(&b, "- blind spot: %s\n", oneLineText(x.Text))
	}
	for _, c := range r.Checks {
		if c.Answer == "concern" {
			fmt.Fprintf(&b, "- concern (%s, %s): %s\n", c.Lens, c.Chapter, oneLineText(c.Note))
		}
	}
	in.add("previous_findings ask:"+strconv.FormatInt(prevID, 10), b.String())
	return nil
}

// mockupPaths lists the docs/design/mockups/ paths doc links, in order, once.
func mockupPaths(doc string) []string {
	var out []string
	for _, m := range mockupLink.FindAllString(doc, -1) {
		p := "docs/" + m[strings.Index(m, "design/mockups/"):]
		p = strings.TrimRight(p, "./,")
		if p != "docs/design/mockups" && !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

func (in *inputs) mockups(root *os.Root, paths []string) {
	if root == nil {
		return
	}
	total := 0
	for _, p := range paths {
		if total >= maxMockupsBytes {
			in.note("mockup not read, %d KB of mockups already included: %s", maxMockupsBytes>>10, p)
			continue
		}
		data, err := readRootFile(root, p, int64(min(maxMockupBytes, maxMockupsBytes-total)))
		if err != nil {
			in.note("mockup not read: %s (%v)", p, err)
			continue
		}
		total += len(data)
		in.add("mockup "+safeHead(p), data)
	}
}

func (in *inputs) styleGuide(root *os.Root) {
	if root == nil {
		return
	}
	data, err := readRootFile(root, styleGuidePath, maxStyleGuideBytes)
	if err != nil {
		in.note("style guide not read: %v", err)
		return
	}
	in.add("style_guide "+styleGuidePath, data)
}

// lenses passes every lens of the folder (built-in and .watchtower/review.md).
func (in *inputs) lenses(folder string) {
	lenses, notes := reviewdiff.LoadLenses(folder)
	in.notes = append(in.notes, notes...)
	var b strings.Builder
	for _, l := range lenses {
		fmt.Fprintf(&b, "[%s] %s\n", l.ID, oneLineText(l.Name))
		for _, it := range l.Items {
			b.WriteString("  - " + oneLineText(it.Text) + "\n")
		}
	}
	if b.Len() > 0 {
		in.add("lenses", b.String())
	}
}

var errTooLarge = errors.New("too large")

// readRootFile reads rel under root: a regular file only (a FIFO is opened
// non-blocking and refused), at most limit bytes, as valid UTF-8 text.
func readRootFile(root *os.Root, rel string, limit int64) (string, error) {
	f, err := root.OpenFile(rel, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	st, err := f.Stat()
	if err != nil {
		return "", err
	}
	if !st.Mode().IsRegular() {
		return "", errors.New("not a regular file")
	}
	if st.Size() > limit {
		return "", errTooLarge
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return "", err
	}
	if int64(len(data)) > limit {
		return "", errTooLarge
	}
	return strings.ToValidUTF8(string(data), "�"), nil
}

// safeHead keeps a block head on one line of path characters.
func safeHead(p string) string {
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '>' || r == '<' {
			return -1
		}
		return r
	}, p)
}

func oneLineText(s string) string { return Normalize(s) }

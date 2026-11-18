package automations_test

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

// output.inbox's blocks and key, the folder hook and output.remove (Inbox
// builder A, plan Task 5).

func livingCase() sdkCase { return sdkCase{outputs: []string{"inbox"}, living: true} }

func feedCase() sdkCase { return sdkCase{outputs: []string{"inbox"}} }

// try wraps statements in a script returning "ok" or the error's name and
// message.
func try(stmts string) string {
	return `try { ` + stmts + `; return "ok" } catch (e) { return e.name + ": " + e.message }`
}

// wantRefusal runs stmts and wants the error name and a message containing
// want, with nothing buffered.
func wantRefusal(t *testing.T, stmts string, c sdkCase, name, want string) sdkRun {
	t.Helper()
	r := runSDK(t, try(stmts), c)
	if r.err != nil {
		t.Fatalf("Run: %v", r.err)
	}
	got := fmt.Sprint(r.out)
	if !strings.HasPrefix(got, name+": ") || !strings.Contains(got, want) {
		t.Fatalf("%.160s = %q; want %s naming %q", stmts, got, name, want)
	}
	if n := len(r.env.Buffer.Outputs()); n != 0 {
		t.Fatalf("buffered %d outputs; want none", n)
	}
	if n := len(r.env.Buffer.Removals()); n != 0 {
		t.Fatalf("buffered %d removals; want none", n)
	}
	return r
}

const twoBlocks = `[{type: "heading", text: "Waiting for me"},
	{type: "list", rows: [{title: "colleague A asked about the release", badge: {text: "2h", tone: "warning"}}]}]`

func TestOutput_InboxBlocksFeed(t *testing.T) {
	r := mustReturn(t, try(`output.inbox({title: "Threads", blocks: `+twoBlocks+`, priority: "high", link: "https://example.com/t"})`), feedCase(), "ok")
	outs := r.env.Buffer.Outputs()
	if len(outs) != 1 {
		t.Fatalf("buffered %d outputs; want 1", len(outs))
	}
	o := outs[0]
	doc, err := blocks.Decode(o.BlocksJSON)
	if err != nil || len(doc.Blocks) != 2 {
		t.Fatalf("BlocksJSON = %s (%v); want the canonical two-block document", o.BlocksJSON, err)
	}
	canon, err := doc.Canonical()
	if err != nil || string(canon) != o.BlocksJSON {
		t.Fatalf("BlocksJSON %s is not canonical (%s, %v)", o.BlocksJSON, canon, err)
	}
	if !strings.Contains(o.BlocksJSON, `"empty":"Nothing here"`) {
		t.Fatalf("BlocksJSON = %s; want the list's default empty text written out", o.BlocksJSON)
	}
	if want := blocks.PlainText(*doc, automations.MaxOutputBodyBytes); o.Body != want || o.Body == "" {
		t.Fatalf("Body = %q; want the plain text %q", o.Body, want)
	}
	if o.OutputKey != "" {
		t.Fatalf("OutputKey = %q; want none in a feed recipe", o.OutputKey)
	}
	if want := blocks.ContentHash(o.Title, o.Body, doc, "high", o.Link, o.Actions); o.ContentHash != want {
		t.Fatalf("ContentHash = %q; want %q", o.ContentHash, want)
	}
}

func TestOutput_InboxContentHashOnEveryCard(t *testing.T) {
	r := mustReturn(t, try(`output.inbox({title: "t", body: "b"}); output.report({title: "r", body: "b"})`),
		sdkCase{outputs: []string{"inbox", "report"}}, "ok")
	outs := r.env.Buffer.Outputs()
	if outs[0].ContentHash != blocks.ContentHash("t", "b", nil, "medium", "", nil) || outs[0].BlocksJSON != "" {
		t.Fatalf("inbox card = %+v; want a content hash over the markdown card and no blocks", outs[0])
	}
	if outs[1].ContentHash != "" {
		t.Fatalf("report ContentHash = %q; want none (inbox only)", outs[1].ContentHash)
	}
}

// TestOutput_InboxPriorityDefaultHashesAsMedium: an omitted priority and the
// explicit default ("medium", what the row stores for ”) are one content.
func TestOutput_InboxPriorityDefaultHashesAsMedium(t *testing.T) {
	r := mustReturn(t, try(`output.inbox({title: "t", body: "b", key: "a"});
		output.inbox({title: "t", body: "b", key: "b", priority: "medium"});
		output.inbox({title: "t", body: "b", key: "c", priority: "low"})`), livingCase(), "ok")
	outs := r.env.Buffer.Outputs()
	if outs[0].ContentHash != outs[1].ContentHash || outs[0].ContentHash == outs[2].ContentHash {
		t.Fatalf("hashes = %s, %s, %s; want the default and medium equal, low different",
			outs[0].ContentHash, outs[1].ContentHash, outs[2].ContentHash)
	}
}

func TestOutput_InboxBodyOrBlocks(t *testing.T) {
	wantRefusal(t, `output.inbox({title: "t", body: "b", blocks: []})`, feedCase(),
		"ValidationError", "output.inbox(): pass body or blocks, not both")
	wantRefusal(t, `output.inbox({title: "t"})`, feedCase(), "ValidationError", "output.inbox(): body must be a string")
	wantRefusal(t, `output.inbox({title: "t", blocks: {type: "heading"}})`, feedCase(),
		"ValidationError", "output.inbox(): blocks must be an array of blocks")
	wantRefusal(t, `output.inbox({title: "t", blocks: [{type: "chart"}]})`, feedCase(),
		"ValidationError", `output.inbox(): blocks[0]: unknown block type "chart"`)
	// An empty document is valid: the card draws its title only.
	r := mustReturn(t, try(`output.inbox({title: "t", blocks: []})`), feedCase(), "ok")
	if o := r.env.Buffer.Outputs()[0]; o.BlocksJSON != `{"v":1,"blocks":[]}` || o.Body != "" {
		t.Fatalf("empty blocks = %q / %q", o.BlocksJSON, o.Body)
	}
	// output.report takes neither blocks nor key.
	for _, f := range []string{`blocks: []`, `key: "a"`} {
		got := mustReturnAny(t, try(`output.report({title: "t", body: "b", `+f+`})`), sdkCase{outputs: []string{"report"}, living: true})
		if !strings.Contains(got, "ValidationError") || !strings.Contains(got, "unknown field") {
			t.Fatalf("output.report with %s = %q; want unknown field", f, got)
		}
	}
}

func TestOutput_InboxKey(t *testing.T) {
	r := mustReturn(t, try(`output.inbox({title: "t", body: "b", key: "thread:42"})`), livingCase(), "ok")
	if k := r.env.Buffer.Outputs()[0].OutputKey; k != "thread:42" {
		t.Fatalf("OutputKey = %q", k)
	}
	wantRefusal(t, `output.inbox({title: "t", body: "b"})`, livingCase(),
		"ValidationError", "output.inbox(): key is required — this automation keeps living artifacts")
	wantRefusal(t, `output.inbox({title: "t", body: "b", key: "a"})`, feedCase(),
		"ValidationError", `output.inbox(): key is only for living artifacts; add "artifacts: living" to the recipe`)
	for name, key := range map[string]string{
		"empty": `""`, "number": `7`, "201 chars": `"` + strings.Repeat("é", 201) + `"`,
		"control": `"a\nb"`, "null": `null`,
	} {
		t.Run(name, func(t *testing.T) {
			wantRefusal(t, `output.inbox({title: "t", body: "b", key: `+key+`})`, livingCase(),
				"ValidationError", "output.inbox(): key must be a string of 1 to 200 characters without control characters")
		})
	}
	wantRefusal(t, `output.inbox({title: "t", body: "b", key: "  "})`, livingCase(),
		"ValidationError", "output.inbox(): key is blank; give it a non-space character")
	mustReturn(t, try(`output.inbox({title: "t", body: "b", key: "`+strings.Repeat("é", 200)+`"})`), livingCase(), "ok")
}

// folder is output.inbox's field (Inbox builder B's hook, inbox_folder_field.go):
// output.report still refuses it, and other unknown fields stay unknown.
func TestOutput_InboxFolderFieldRegistered(t *testing.T) {
	r := mustReturn(t, try(`output.inbox({title: "t", body: "b", folder: "work"})`), feedCase(), "ok")
	if got := r.env.Buffer.Outputs()[0].FolderSlug; got != "work" {
		t.Fatalf("FolderSlug = %q; want the buffered slug", got)
	}
	wantRefusal(t, `output.inbox({title: "t", body: "b", colour: "red"})`, feedCase(),
		"ValidationError", `output.inbox(): unknown field "colour"`)
	got := mustReturnAny(t, try(`output.report({title: "t", body: "b", folder: "work"})`), sdkCase{outputs: []string{"report"}})
	if !strings.Contains(got, `unknown field "folder"`) {
		t.Fatalf("output.report with folder = %q; want unknown field", got)
	}
}

// hookModules is DefaultModules with a folder hook registered on the output
// module; seen records each call's raw value.
func hookModules(seen *[]any, fail error) []automations.Module {
	b := automations.Backends{}
	mods := automations.DefaultModules(b)
	for _, m := range mods {
		if out, ok := m.(*automations.OutputMod); ok {
			out.RegisterInboxField("folder", func(env *automations.Env, fn string, v any, o *db.AutomationOutput) error {
				*seen = append(*seen, v)
				if fail != nil {
					return fail
				}
				o.Title += " [" + fn + "]"
				return nil
			})
		}
	}
	return mods
}

func TestOutput_InboxFieldHook(t *testing.T) {
	var seen []any
	c := feedCase()
	c.modules = hookModules(&seen, nil)
	r := mustReturn(t, try(`output.inbox({title: "t", body: "b", folder: "Work"}); output.inbox({title: "u", body: "b"})`), c, "ok")
	if len(seen) != 1 || seen[0] != "Work" {
		t.Fatalf("hook saw %v; want the one raw value \"Work\"", seen)
	}
	if outs := r.env.Buffer.Outputs(); outs[0].Title != "t [output.inbox]" || outs[1].Title != "u" {
		t.Fatalf("titles = %q, %q; want the hook's change on the first card only", outs[0].Title, outs[1].Title)
	}
	// An unknown field is still unknown with a hook registered.
	c.modules = hookModules(&seen, nil)
	wantRefusal(t, `output.inbox({title: "t", body: "b", colour: "red"})`, c, "ValidationError", `unknown field "colour"`)
	// A hook's refusal reaches the script; nothing is buffered.
	seen = nil
	c.modules = hookModules(&seen, &automations.SDKError{Name: automations.ErrNameValidation, Message: "output.inbox(): no folder \"Work\""})
	wantRefusal(t, `output.inbox({title: "t", body: "b", folder: "Work"})`, c, "ValidationError", `no folder "Work"`)
	// The hook is for output.inbox only.
	c = sdkCase{outputs: []string{"report"}, modules: hookModules(&seen, nil)}
	if got := mustReturnAny(t, try(`output.report({title: "t", body: "b", folder: "Work"})`), c); !strings.Contains(got, `unknown field "folder"`) {
		t.Fatalf("output.report with a hook = %q; want unknown field", got)
	}
}

func outputKeys(outs []db.AutomationOutput) []string {
	var keys []string
	for _, o := range outs {
		keys = append(keys, o.OutputKey+"="+o.Title)
	}
	return keys
}

func TestOutput_RemoveLaterWins(t *testing.T) {
	r := mustReturn(t, try(`output.inbox({title: "a1", body: "b", key: "a"});
		output.inbox({title: "b1", body: "b", key: "b"});
		output.remove({key: "a"});
		output.remove({key: "c"});
		output.remove({key: "b"});
		output.inbox({title: "b2", body: "b", key: "b"});
		output.inbox({title: "d1", body: "b", key: "d"});
		output.inbox({title: "d2", body: "b", key: "d"})`), livingCase(), "ok")
	if got := outputKeys(r.env.Buffer.Outputs()); fmt.Sprint(got) != "[b=b2 d=d2]" {
		t.Fatalf("outputs = %v; want b and d, each its last write", got)
	}
	if got := r.env.Buffer.Removals(); !slices.Equal(got, []string{"a", "c"}) {
		t.Fatalf("removals = %v; want [a c]", got)
	}
	c := r.env.Buffer.Commit()
	if !slices.Equal(c.Removals, []string{"a", "c"}) || len(c.Outputs) != 2 {
		t.Fatalf("commit = %+v", c)
	}
	// The commit is one the db layer accepts: no key both written and removed.
	for _, o := range c.Outputs {
		if slices.Contains(c.Removals, o.OutputKey) {
			t.Fatalf("key %q is both written and removed", o.OutputKey)
		}
	}
	steps := r.env.Journal.Steps()
	if len(steps) != 8 || steps[2].Kind != automations.StepKindOutput || steps[2].Name != "remove" || steps[2].Status != automations.StepOK {
		t.Fatalf("steps = %v; want eight output steps, remove journaled ok", stepStatuses(steps))
	}
}

// TestOutput_OutputsCapCountsKeptOutputs: rewriting one key does not use up
// MaxOutputsPerRun; distinct keys do.
func TestOutput_OutputsCapCountsKeptOutputs(t *testing.T) {
	r := mustReturn(t, try(fmt.Sprintf(`for (let i = 0; i < %d; i++) output.inbox({title: "t" + i, body: "b", key: "same"})`,
		automations.MaxOutputsPerRun+10)), livingCase(), "ok")
	if outs := r.env.Buffer.Outputs(); len(outs) != 1 || outs[0].Title != fmt.Sprintf("t%d", automations.MaxOutputsPerRun+9) {
		t.Fatalf("outputs = %v; want the last write of the one key", outputKeys(outs))
	}
	got := mustReturnAny(t, try(fmt.Sprintf(`for (let i = 0; i <= %d; i++) output.inbox({title: "t", body: "b", key: "k" + i})`,
		automations.MaxOutputsPerRun)), livingCase())
	if !strings.Contains(got, "ValidationError") || !strings.Contains(got, "the limit is 50 per run") {
		t.Fatalf("51 keys = %q; want the outputs cap", got)
	}
}

func TestOutput_RemoveGates(t *testing.T) {
	wantRefusal(t, `output.remove({key: "a"})`, feedCase(),
		"ValidationError", `output.remove(): only for living artifacts; add "artifacts: living" to the recipe`)
	r := wantRefusal(t, `output.remove({key: "a"})`, sdkCase{outputs: []string{"report"}, living: true},
		"PermissionDenied", "output:inbox")
	if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != automations.StepDenied {
		t.Fatalf("steps = %v; want one denied step", stepStatuses(steps))
	}
	for name, arg := range map[string]string{
		"no key": `{}`, "empty": `{key: ""}`, "number": `{key: 3}`, "not an object": `"a"`,
	} {
		t.Run(name, func(t *testing.T) {
			wantRefusal(t, `output.remove(`+arg+`)`, livingCase(), "ValidationError", "output.remove(")
		})
	}
	wantRefusal(t, `output.remove({key: "a", title: "x"})`, livingCase(), "ValidationError", `output.remove(): unknown field "title"`)
}

func TestOutput_RemoveDryRun(t *testing.T) {
	c := livingCase()
	c.dryRun = true
	r := mustReturn(t, `const v = output.remove({key: "a"}); return v.status`, c, automations.StepDryRun)
	steps := r.env.Journal.Steps()
	if len(steps) != 1 || steps[0].Name != "remove" || steps[0].Status != automations.StepDryRun {
		t.Fatalf("steps = %v; want one dry_run remove", stepStatuses(steps))
	}
}

func TestOutput_BlockActionRefs(t *testing.T) {
	row := `output.inbox({title: "t", blocks: [{type: "list", rows: [{title: "Send?", ref: {kind: "action", id: 7}}]}]})`
	wantRefusal(t, row, feedCase(), "ValidationError", "output.inbox(): blocks[0].rows[0].ref: an action ref is only for built-in automations")
	c := feedCase()
	c.builtin = true
	r := mustReturn(t, try(row), c, "ok")
	if !strings.Contains(r.env.Buffer.Outputs()[0].BlocksJSON, `"ref":{"kind":"action","id":7}`) {
		t.Fatalf("BlocksJSON = %s; want the ref", r.env.Buffer.Outputs()[0].BlocksJSON)
	}
	// A track ref is for every recipe.
	mustReturn(t, try(`output.inbox({title: "t", blocks: [{type: "list", rows: [{title: "x", ref: {kind: "track", id: 2}}]}]})`), feedCase(), "ok")
}

func TestOutput_BlockReplyActionNeedsInboxReply(t *testing.T) {
	call := `output.inbox({title: "t", blocks: [{type: "actions", actions: [{label: "Snooze", reply: "snooze"}]}]})`
	r := wantRefusal(t, call, feedCase(), "PermissionDenied", "inbox:reply")
	if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != automations.StepDenied {
		t.Fatalf("steps = %v; want one denied step", stepStatuses(steps))
	}
	mustReturn(t, try(call), sdkCase{perms: []string{"inbox:reply"}, outputs: []string{"inbox"}}, "ok")
}

// actionsBlocks returns n chat actions as actions blocks of at most four.
func actionsBlocks(n int) string {
	var bs []string
	for n > 0 {
		k := min(n, blocks.MaxBlockActions)
		var acts []string
		for range k {
			acts = append(acts, `{label: "Ask", chat: "x"}`)
		}
		bs = append(bs, `{type: "actions", actions: [`+strings.Join(acts, ",")+`]}`)
		n -= k
	}
	return "[" + strings.Join(bs, ",") + "]"
}

// TestOutput_CardActionsCountTowardTheActionCap: the card's own actions
// count with the block actions against blocks.MaxActions.
func TestOutput_CardActionsCountTowardTheActionCap(t *testing.T) {
	cardActions := `[{label: "A", chat: "x"}, {label: "B", chat: "x"}, {label: "C", chat: "x"}, {label: "D", chat: "x"}]`
	wantRefusal(t, `output.inbox({title: "t", actions: `+cardActions+`, blocks: `+actionsBlocks(47)+`})`, feedCase(),
		"ValidationError", "output.inbox(): the card has 51 actions; the limit is 50")
	mustReturn(t, try(`output.inbox({title: "t", actions: `+cardActions+`, blocks: `+actionsBlocks(46)+`})`), feedCase(), "ok")
}

// TestOutput_BlocksResultTooLarge: an argument past the SDK cap is refused
// before validation, with nothing buffered.
func TestOutput_BlocksArgumentTooLarge(t *testing.T) {
	wantRefusal(t, `output.inbox({title: "t", blocks: [{type: "text", markdown: "x".repeat(300000)}]})`, feedCase(),
		"ResultTooLarge", "output.inbox(): the argument is larger than")
}

// TestOutputMod_RegisterInboxFieldRefusesOwnedFields: a hook cannot take a
// field output.inbox owns.
func TestOutputMod_RegisterInboxFieldRefusesOwnedFields(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("RegisterInboxField(\"title\") did not panic")
		}
	}()
	automations.OutputModule().RegisterInboxField("title", func(*automations.Env, string, any, *db.AutomationOutput) error { return nil })
}

// livingRunScript writes keys a and b with blocks on its first run; on the
// second it rewrites a unchanged and removes b.
const livingRunScript = `const n = (state.get("n") || 0) + 1; state.set("n", n);
const card = (k) => output.inbox({title: "Card " + k, key: k, blocks: [{type: "heading", text: "Key " + k}]});
card("a");
if (n === 1) { card("b") } else { output.remove({key: "b"}) }
return n`

// TestAuto04_LivingRunCommitsUpsertAndRemoval: a living recipe's succeeded
// runs upsert by key (a same-content rewrite keeps the row) and apply
// output.remove through the executor's one commit.
func TestAuto04_LivingRunCommitsUpsertAndRemoval(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seedText(t, "living", exRecipeText(livingRunScript, "artifacts: living\nconcurrency: 1\n"), false)
	first := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")
	outs, err := f.d.ListAutomationOutputs("inbox", 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := outputKeys(outs); len(got) != 2 || !slices.Contains(got, "a=Card a") || !slices.Contains(got, "b=Card b") {
		t.Fatalf("after run 1 outputs = %v; want a and b", got)
	}
	var cardA db.AutomationOutput
	for _, o := range outs {
		if o.OutputKey == "a" {
			cardA = o
		}
		if o.BlocksJSON == "" || o.ContentHash == "" || o.Body == "" {
			t.Fatalf("card %q = %+v; want blocks, a content hash and the plain-text body", o.OutputKey, o)
		}
	}
	f.clock.Advance(time.Minute)
	second := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	if outs, err = f.d.ListAutomationOutputs("inbox", 0); err != nil {
		t.Fatal(err)
	}
	if len(outs) != 1 || outs[0].ID != cardA.ID || outs[0].RunID != second || outs[0].ContentHash != cardA.ContentHash ||
		!outs[0].ChangedAt.Equal(cardA.ChangedAt) {
		t.Fatalf("after run 2 outputs = %+v; want card a kept (same id and hash, unchanged changed_at, run 2) and b removed", outs)
	}
}

// TestAuto12_LivingDryRunWritesNothing: a living dry run journals its
// writes and removals dry_run and commits none of them.
func TestAuto12_LivingDryRunWritesNothing(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seedText(t, "living", exRecipeText(`output.inbox({title: "t", key: "a", blocks: []}); output.remove({key: "b"}); return 1`,
		"artifacts: living\nconcurrency: 1\n"), false)
	f.commitPrior(t, a)
	f.commitLivingPrior(t, a, "b", "h0")
	before := f.dump(t)
	id := f.enqueue(t, a, db.TriggerDryRun)
	r, err := f.e.ExecuteInline(context.Background(), id)
	if err != nil || r.Status != db.RunSucceeded {
		t.Fatalf("ExecuteInline = %+v, %v", r, err)
	}
	if after := f.dump(t); after != before {
		t.Fatalf("state/outputs changed:\nbefore %s\nafter  %s", before, after)
	}
	if got := stepStatusesOf(f.steps(t, id)); got != "output:dry_run,output:dry_run" {
		t.Fatalf("steps = %s", got)
	}
	var hash string
	if err := f.d.QueryRow(`SELECT content_hash FROM automation_outputs WHERE automation_id = ? AND output_key = 'b'`, a.ID).Scan(&hash); err != nil || hash != "h0" {
		t.Fatalf("living card b after the dry run = %q, %v; want it kept with hash h0", hash, err)
	}
}

// TestAuto08_ResumeRebuildsLivingBuffer: a resumed run's replay rebuilds
// the living buffer — the card's blocks and key, and the removal — so the
// commit carries them.
func TestAuto08_ResumeRebuildsLivingBuffer(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newWriteFixture(t)
		a := w.seedWorkbenchOutputWith(t, "living", []string{"ask:owner"}, "inbox", "artifacts: living\nconcurrency: 1\n",
			`output.inbox({title: "filed", key: "k", blocks: [{type: "heading", text: "h"}]}); output.remove({key: "gone"});
		const r = `+resumeAskCall+`; return 1`)
		w.commitLivingPrior(t, a, "gone", "h0")
		id := w.enqueue(t, a, db.TriggerManual)
		w.stopWhileWaiting(t, id)
		ask := w.onlyAsk(t, a.ProjectID)

		w.restart()
		stop := runExecutor(t, w.exFixture)
		defer stop()
		w.waitStatus(t, id, db.RunWaiting)
		w.answerAsk(t, ask.ID)
		w.e.Wake()
		if r := w.waitEnded(t, id); r.Status != db.RunSucceeded {
			t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
		}
		outs, err := w.d.ListAutomationOutputs("inbox", 0)
		if err != nil {
			t.Fatal(err)
		}
		if len(outs) != 1 || outs[0].OutputKey != "k" || !strings.Contains(outs[0].BlocksJSON, `"text":"h"`) || outs[0].ContentHash == "" {
			t.Fatalf("committed outputs = %+v; want the one living card with its blocks, gone removed", outs)
		}
	})
}

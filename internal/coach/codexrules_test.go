package coach

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestCodexSafeAllowTable_EqualsClaudeTable(t *testing.T) {
	claude := map[string]bool{}
	for v := range safeAllowVerbs {
		claude[strings.Join(strings.Fields(v), " ")] = true
	}
	codex := map[string]bool{}
	for _, p := range codexSafeAllowPatterns {
		codex[strings.Join(p, " ")] = true
	}
	assert.Equal(t, claude, codex)
	assert.Len(t, codexSafeAllowPatterns, len(codex), "no repeats")
}

func TestCodexRuleLine_Format(t *testing.T) {
	// Codex's own serialization (execpolicy amend.rs): JSON tokens joined by ", ".
	assert.Equal(t, `prefix_rule(pattern=["go", "test"], decision="allow")`, CodexRuleLine([]string{"go", "test"}))
	assert.Equal(t, `prefix_rule(pattern=["cat"], decision="allow")`, CodexRuleLine([]string{"cat"}))
}

func TestCodexSafeAllowRule(t *testing.T) {
	for _, p := range codexSafeAllowPatterns {
		assert.True(t, CodexSafeAllowRule(CodexRuleLine(p)), p)
	}
	for _, l := range []string{
		`prefix_rule(pattern=["rm"], decision="allow")`,
		`prefix_rule(pattern=["go", "test", "-exec"], decision="allow")`,
		`prefix_rule(pattern=["go", "test"], decision="prompt")`,
		`prefix_rule(pattern=["go",  "test"], decision="allow")`,
		` prefix_rule(pattern=["go", "test"], decision="allow")`,
		`prefix_rule(pattern=["make"], decision="allow")`,
		"",
	} {
		assert.False(t, CodexSafeAllowRule(l), l)
	}
}

var (
	ruleCat  = CodexRuleLine([]string{"cat"})
	ruleLs   = CodexRuleLine([]string{"ls"})
	ruleMake = `prefix_rule(pattern=["make"], decision="allow")`
)

func TestValidateAfter_CodexRulesOnlyGrow(t *testing.T) {
	before := "# mine\n" + ruleMake + "\n" + ruleLs + "\n"
	cur := CurrentText{Destination: DestCodexRulesAllow, Text: before}
	require.NoError(t, ValidateAfter(cur, before+ruleCat+"\n"))
	require.NoError(t, ValidateAfter(CurrentText{Destination: DestCodexRulesAllow}, ruleCat+"\n"))

	for name, tc := range map[string]struct{ after, want string }{
		"line removed":  {"# mine\n" + ruleLs + "\n" + ruleCat + "\n", "the Codex rules may only grow"},
		"line replaced": {"# mine\n" + ruleMake + "\n" + ruleCat + "\n", "the Codex rules may only grow"},
		"unsafe":        {before + `prefix_rule(pattern=["rm"], decision="allow")` + "\n", `rule "prefix_rule(pattern=[\"rm\"], decision=\"allow\")" is not a safe read, search, build or test command`},
		"already there": {before + ruleLs + "\n", "the Codex rules already have every rule"},
		"repeated":      {before + ruleCat + "\n" + ruleCat + "\n", "the Codex rules already have every rule"},
		"nothing added": {before + "\n", "the Codex rules already have every rule"},
		"comment added": {before + "# note\n", `rule "# note" is not a safe read, search, build or test command`},
		"indented":      {before + "  " + ruleCat + "\n", `rule "  prefix_rule(pattern=[\"cat\"], decision=\"allow\")" is not a safe read, search, build or test command`},
		"crlf":          {before + ruleCat + "\r\n", `rule "prefix_rule(pattern=[\"cat\"], decision=\"allow\")\r" is not a safe read, search, build or test command`},
	} {
		err := ValidateAfter(cur, tc.after)
		require.Error(t, err, name)
		assert.Equal(t, tc.want, err.Error(), name)
	}
	big := CurrentText{Destination: DestCodexRulesAllow, Text: "#" + strings.Repeat("x", claudeMDMaxBytes-len(ruleCat)) + "\n"}
	require.EqualError(t, ValidateAfter(big, big.Text+ruleCat+"\n"), "the Codex rules file would be over its size limit")
	// A line glued to an unterminated last line is not a new line.
	unterminated := CurrentText{Destination: DestCodexRulesAllow, Text: ruleMake}
	require.EqualError(t, ValidateAfter(unterminated, ruleMake+ruleCat), "the Codex rules may only grow")
	require.NoError(t, ValidateAfter(unterminated, ruleMake+"\n"+ruleCat+"\n"))
}

func TestApplyEdit_CodexRulesAppendOnly(t *testing.T) {
	cur := CurrentText{Destination: DestCodexRulesAllow, Text: "# mine\n" + ruleMake}
	got, ok := applyEdit(cur, "", ruleCat)
	require.True(t, ok)
	assert.Equal(t, "# mine\n"+ruleMake+"\n"+ruleCat+"\n", got, "file kept, line newline-terminated")
	_, ok = applyEdit(cur, ruleMake, ruleCat)
	assert.False(t, ok, "find must be empty")
}

func rulesProposal(before, add string) db.CoachProposal {
	return db.CoachProposal{Destination: DestCodexRulesAllow, BeforeText: before,
		AfterText: appendCodexRules(before, add)}
}

func TestAccept_CodexRulesAppendsAndRollbackRemovesOnlyItsLines(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	path := codexRulesPath(a.env())
	original := "# mine\n" + ruleMake + "\n"
	writeFile(t, path, original)
	id := propose(t, d, rulesProposal(original, ruleCat))
	require.NoError(t, a.acceptErr(id, ""))
	assert.Equal(t, original+ruleCat+"\n", readFile(t, path))
	fi, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o640), fi.Mode().Perm(), "mode kept")
	assert.Equal(t, "accepted", proposal(t, d, id).Status)

	// The owner (or Codex) appends a rule by hand.
	writeFile(t, path, original+ruleCat+"\n"+ruleLs+"\n")
	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	assert.Equal(t, original+ruleLs+"\n", readFile(t, path))
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
}

func TestAccept_CodexRulesUnsafeEditRefused(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	path := codexRulesPath(a.env())
	writeFile(t, path, ruleMake+"\n")
	id := propose(t, d, rulesProposal(ruleMake+"\n", `prefix_rule(pattern=["rm"], decision="allow")`))
	require.ErrorIs(t, a.acceptErr(id, ""), ErrInvalidEdit)
	assert.Equal(t, ruleMake+"\n", readFile(t, path))
}

func TestAccept_CodexRulesMissingFileRefused(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	id := propose(t, d, rulesProposal("", ruleCat))
	require.ErrorIs(t, a.acceptErr(id, ""), errCodexRulesMissing)
	_, err := os.Lstat(codexRulesPath(a.env()))
	assert.ErrorIs(t, err, os.ErrNotExist, "never created")
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

func TestCodexRules_RefusesSymlinkedRulesFolder(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	target := t.TempDir()
	writeFile(t, filepath.Join(target, "default.rules"), ruleMake+"\n")
	require.NoError(t, os.Symlink(target, filepath.Join(a.CodexHome, "rules")))
	_, err := a.readCurrent(rulesProposal(ruleMake+"\n", ruleCat))
	require.ErrorIs(t, err, errUnsafeFile)
}

func TestRollback_CodexRulesLineGone_ChangedSince(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	path := codexRulesPath(a.env())
	original := ruleMake + "\n"
	writeFile(t, path, original)
	id := propose(t, d, rulesProposal(original, ruleCat))
	require.NoError(t, a.acceptErr(id, ""))
	writeFile(t, path, original+ruleLs+"\n") // cat removed by hand, ls added

	diff, err := a.Rollback(id, false)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.Contains(t, diff, "-"+ruleCat)
	assert.Equal(t, original+ruleLs+"\n", readFile(t, path), "nothing written without force")
	assert.Equal(t, "accepted", proposal(t, d, id).Status)

	_, err = a.Rollback(id, true)
	require.NoError(t, err)
	assert.Equal(t, original+ruleLs+"\n", readFile(t, path), "forced: nothing of the owner's removed")
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
}

func TestAccept_CodexRulesStatusFailureRestoresBytes(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	path := codexRulesPath(a.env())
	original := "# mine\n" + ruleMake
	writeFile(t, path, original)
	id := propose(t, d, rulesProposal(original, ruleCat))
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	w, err := a.writeDestination(p, cur, p.AfterText, applyNow)
	require.NoError(t, err)
	assert.Equal(t, original+"\n"+ruleCat+"\n", readFile(t, path))
	require.NoError(t, w.undo())
	assert.Equal(t, original, readFile(t, path), "byte for byte")
}

func TestRemoveCodexRules(t *testing.T) {
	assert.Equal(t, "a\nb\n", removeCodexRules("a\n"+ruleCat+"\nb\n", []string{ruleCat}))
	assert.Equal(t, "a\n", removeCodexRules("a\n"+ruleCat, []string{ruleCat}))
	assert.Equal(t, ruleCat+"\n", removeCodexRules(ruleCat+"\n"+ruleCat+"\n", []string{ruleCat}), "one occurrence")
	assert.Equal(t, "a\n", removeCodexRules("a\n", []string{ruleCat}), "missing line skipped")
}

func TestCodexRules_SymlinkedCodexHomeWorks(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d) // default Codex home <Home>/.codex, a link (dotfiles)
	target := t.TempDir()
	require.NoError(t, os.Symlink(target, filepath.Join(a.Home, ".codex")))
	writeFile(t, filepath.Join(target, "rules", "default.rules"), ruleMake+"\n")
	id := propose(t, d, rulesProposal(ruleMake+"\n", ruleCat))
	require.NoError(t, a.acceptErr(id, ""))
	assert.Equal(t, ruleMake+"\n"+ruleCat+"\n", readFile(t, filepath.Join(target, "rules", "default.rules")))
}

func TestWriteCut_CodexRulesMissingIsNotCut(t *testing.T) {
	d := openDBs(t)
	t.Setenv("CODEX_HOME", t.TempDir())
	p := rulesProposal("", ruleCat)
	p.ID, p.Title, p.Metric = 1, "t", "corrections"
	wrote, err := writeCut(d.DB, d.al, t.TempDir(), p, applyNow)
	require.NoError(t, err, "a missing rules file is not an error for the judge")
	assert.False(t, wrote)
}

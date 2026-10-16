package devpack

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pelletier/go-toml/v2"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/codex"
	"watchtower/internal/config"
)

const codexTestBin = "/Users/example/Library/Application Support/Watchtower/bin/watchtower"

// fakeAppServer stands in for codex's app-server and for the hooks.state it
// keeps in ~/.codex/config.toml. Its launch-flag hooks come from parsing the
// -c hooks.<Event>=… flags it was started with, the way codex does, so a
// hashed string that differs from the launched one cannot be trusted.
type fakeAppServer struct {
	state    map[string]string // hooks.state key → trusted_hash
	extra    []codex.HookEntry // non-launch-flag hooks hooks/list also reports
	starts   int
	writes   [][]codex.HookEntry
	args     []string // the last start's extraArgs
	env      []string
	listErr  error
	trustErr error
	closeErr error
	bin      string // the codex binary the factory resolves
}

func newFakeAppServer(t *testing.T) *fakeAppServer {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "codex")
	writeTestFile(t, bin, "#!/bin/sh\n")
	return &fakeAppServer{state: map[string]string{}, bin: bin}
}

func (f *fakeAppServer) start(_ context.Context, bin string, extraArgs, env []string) (codex.AppServer, error) {
	if bin != f.bin {
		return nil, fmt.Errorf("unexpected codex binary %q", bin)
	}
	f.starts++
	f.args, f.env = extraArgs, env
	return &fakeAppServerConn{f: f, args: extraArgs}, nil
}

// factory is the srv InstallCodex takes, through the production
// CodexAppServer wiring.
func (f *fakeAppServer) factory() func() (codex.AppServer, error) {
	return CodexAppServer(context.Background(), &config.Config{}, codexTestBin,
		func() (string, error) { return f.bin, nil }, f.start)
}

type fakeAppServerConn struct {
	f    *fakeAppServer
	args []string
}

func (c *fakeAppServerConn) ListHooks(_ context.Context, _ string) ([]codex.HookEntry, error) {
	if c.f.listErr != nil {
		return nil, c.f.listErr
	}
	entries := append([]codex.HookEntry{}, c.f.extra...)
	for _, e := range sessionFlagHooks(c.args) {
		e.TrustStatus = "untrusted"
		if h, ok := c.f.state[e.Key]; ok {
			e.TrustStatus = "modified"
			if h == e.CurrentHash {
				e.TrustStatus = "trusted"
			}
		}
		entries = append(entries, e)
	}
	return entries, nil
}

func (c *fakeAppServerConn) TrustHooks(_ context.Context, entries []codex.HookEntry) error {
	if c.f.trustErr != nil {
		return c.f.trustErr
	}
	c.f.writes = append(c.f.writes, entries)
	for _, e := range entries {
		c.f.state[e.Key] = e.CurrentHash
	}
	return nil
}

func (c *fakeAppServerConn) Close() error { return c.f.closeErr }

// sessionFlagHooks parses codex launch flags into hooks/list entries.
func sessionFlagHooks(args []string) []codex.HookEntry {
	var out []codex.HookEntry
	for i := 0; i+1 < len(args); i++ {
		if args[i] != "-c" {
			continue
		}
		k, v, _ := strings.Cut(args[i+1], "=")
		event, ok := strings.CutPrefix(k, "hooks.")
		if !ok {
			continue
		}
		var doc struct {
			V []codexHookGroup `toml:"v"`
		}
		if err := toml.Unmarshal([]byte("v = "+v), &doc); err != nil {
			continue // codex would refuse the flag; nothing to list
		}
		for g, grp := range doc.V {
			for h, hk := range grp.Hooks {
				sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%d", grp.Matcher, hk.Command, hk.Timeout)))
				out = append(out, codex.HookEntry{
					Key:         fmt.Sprintf("/<session-flags>/config.toml:%s:%d:%d", snakeEvent(event), g, h),
					Command:     hk.Command,
					CurrentHash: "sha256:" + hex.EncodeToString(sum[:]),
					Source:      "sessionFlags",
					Event:       strings.ToLower(event[:1]) + event[1:],
				})
			}
		}
	}
	return out
}

func snakeEvent(event string) string {
	var b strings.Builder
	for i, r := range event {
		if r >= 'A' && r <= 'Z' {
			if i > 0 {
				b.WriteByte('_')
			}
			r += 'a' - 'A'
		}
		b.WriteRune(r)
	}
	return b.String()
}

func codexOpts(folder string) WorkbenchInstallOptions {
	return WorkbenchInstallOptions{WorkbenchID: 7, Folder: folder, Bin: codexTestBin}
}

func codexSkillFile(folder string) string {
	return filepath.Join(folder, ".agents", "skills", WorkbenchSkillName, "SKILL.md")
}

func codexNotFound() (codex.AppServer, error) { return nil, ErrCodexNotFound }

// StatusCodex's resolve: codex resolves, or there is none.
func codexResolves() error { return nil }
func codexMissing() error  { return ErrCodexNotFound }

func TestInstallCodex_Idempotent(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	st, err := InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	assert.Equal(t, CodexStatus{Found: true, Skill: true, HooksTrusted: ptrTrue(), SkillState: StateInstalled, FlowState: StateInstalled}, st)
	require.Len(t, f.writes, 1)
	assert.Len(t, f.writes[0], len(CodexHookSet(codexTestBin)))
	excludeBefore := readTestFile(t, filepath.Join(folder, ".git", "info", "exclude"))

	st, err = InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	assert.Equal(t, CodexStatus{Found: true, Skill: true, HooksTrusted: ptrTrue(), SkillState: StateUnchanged, FlowState: StateUnchanged}, st)
	assert.Len(t, f.writes, 1, "the second run must not write the trust again")
	exclude := readTestFile(t, filepath.Join(folder, ".git", "info", "exclude"))
	assert.Equal(t, excludeBefore, exclude)
	assert.Equal(t, 1, strings.Count(exclude, "/.agents/skills/watchtower-workbench/"))
	assert.Equal(t, 1, strings.Count(exclude, "/.agents/skills/"+FlowSkillName+"/"))
	entries, err := os.ReadDir(filepath.Join(folder, ".agents", "skills"))
	require.NoError(t, err)
	assert.Len(t, entries, 2, "one copy each of the core and the preset")
}

func ptrTrue() *bool  { v := true; return &v }
func ptrFalse() *bool { v := false; return &v }

func TestInstallCodex_SkillBytesEqualClaudeCopy(t *testing.T) {
	folder := fakeRepo(t)
	_, err := InstallCodex(context.Background(), codexOpts(folder), codexNotFound)
	require.NoError(t, err)
	_, err = installSkill(filepath.Join(folder, ".claude", "skills"), workbenchSkill())
	require.NoError(t, err)
	_, body := WorkbenchSkill()
	assert.Equal(t, string(body), readTestFile(t, codexSkillFile(folder)))
	assert.Equal(t, readTestFile(t, workbenchSkillFile(folder)), readTestFile(t, codexSkillFile(folder)), "I7")
}

func TestInstallCodex_MissingCodexStillInstallsSkillAndReportsNotFound(t *testing.T) {
	folder := fakeRepo(t)
	st, err := InstallCodex(context.Background(), codexOpts(folder), codexNotFound)
	require.NoError(t, err, "a missing codex is a status, not an error (D5)")
	assert.False(t, st.Found)
	assert.Nil(t, st.HooksTrusted)
	assert.True(t, st.Skill)
	assert.FileExists(t, codexSkillFile(folder))
	assert.Contains(t, readTestFile(t, filepath.Join(folder, ".git", "info", "exclude")), "/.agents/skills/watchtower-workbench/")
}

// The real lookup answers ErrCodexNotFound through the factory too.
func TestCodexAppServer_NotFoundAndPathPrepend(t *testing.T) {
	srv := CodexAppServer(context.Background(), &config.Config{}, codexTestBin,
		func() (string, error) { return "codex", nil }, newFakeAppServer(t).start)
	_, err := srv()
	assert.ErrorIs(t, err, ErrCodexNotFound)

	t.Setenv("PATH", "/usr/bin:/bin")
	f := newFakeAppServer(t)
	codexBin := filepath.Join(t.TempDir(), "codex")
	writeTestFile(t, codexBin, "#!/bin/sh\n")
	srv = CodexAppServer(context.Background(), &config.Config{CodexPath: codexBin}, codexTestBin, nil,
		func(ctx context.Context, bin string, args, env []string) (codex.AppServer, error) {
			assert.Equal(t, codexBin, bin)
			return f.start(ctx, f.bin, args, env)
		})
	_, err = srv()
	require.NoError(t, err)
	assert.Contains(t, f.env, "PATH="+filepath.Dir(codexBin)+":/usr/bin:/bin")
}

// Spec I5: the strings the trust step makes codex hash are the launch
// strings, byte for byte — the golden launch args' hook flags.
func TestCodexTrust_HashedStringsAreTheLaunchStrings(t *testing.T) {
	f := newFakeAppServer(t)
	_, err := InstallCodex(context.Background(), codexOpts(fakeRepo(t)), f.factory())
	require.NoError(t, err)

	golden := strings.Split(strings.TrimSpace(readTestFile(t, filepath.Join("testdata", "codex_launch_args.golden"))), "\n")
	var goldenHooks []string
	for i := 2; i < len(golden); i += 2 {
		if golden[i-1] == "-c" && strings.HasPrefix(golden[i], "hooks.") {
			goldenHooks = append(goldenHooks, golden[i-1], golden[i])
		}
	}
	require.NotEmpty(t, goldenHooks)
	assert.Equal(t, append([]string{"-c", codexNoUpdateCheck}, goldenHooks...), f.args)

	la, err := CodexLaunchArgs(&config.Config{}, codexTestBin, 7, func() (string, error) { return f.bin, nil })
	require.NoError(t, err)
	launched := sessionFlagHooks(la.Args)
	require.Len(t, f.writes, 1)
	require.Len(t, launched, len(f.writes[0]))
	for i, e := range launched {
		assert.Equal(t, e.Key, f.writes[0][i].Key)
		assert.Equal(t, e.CurrentHash, f.writes[0][i].CurrentHash, "trusted hash of %s must be the launched one", e.Key)
		assert.Equal(t, CodexHookSet(codexTestBin)[i].Command, f.writes[0][i].Command)
	}
}

func TestProj04_CodexTrustNeverTouchesOtherConfigKeys(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	ours := CodexHookSet(codexTestBin)[0].Command
	f.extra = []codex.HookEntry{
		{Key: folder + "/.codex/hooks.json:session_start:0:0", Command: ours, CurrentHash: "sha256:p", TrustStatus: "untrusted", Source: "project", Event: "sessionStart"},
		{Key: "/Users/example/.codex/hooks.json:stop:0:0", Command: "/usr/bin/true", CurrentHash: "sha256:u", TrustStatus: "untrusted", Source: "user", Event: "stop"},
	}
	_, err := InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	refs := map[string]bool{}
	for _, h := range CodexHookSet(codexTestBin) {
		refs[h.Command] = true
	}
	require.Len(t, f.writes, 1)
	for _, e := range f.writes[0] {
		assert.Equal(t, "sessionFlags", e.Source)
		assert.True(t, strings.HasPrefix(e.Key, "/<session-flags>/config.toml:"), e.Key)
		assert.True(t, refs[e.Command], "foreign command %q trusted", e.Command)
	}
	assert.Len(t, f.state, len(CodexHookSet(codexTestBin)), "hooks.state holds our keys only")
}

func TestInstallCodex_RetrustsAModifiedHook(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	_, err := InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	for k := range f.state {
		f.state[k] = "sha256:stale" // another build trusted other strings
		break
	}
	st, err := StatusCodex(context.Background(), codexOpts(folder), codexResolves, f.factory())
	require.NoError(t, err)
	assert.Equal(t, ptrFalse(), st.HooksTrusted)

	st, err = InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	assert.Equal(t, ptrTrue(), st.HooksTrusted)
	require.Len(t, f.writes, 2)
	assert.Len(t, f.writes[1], 1, "only the modified hook is written")
}

func TestInstallCodex_HookCodexDoesNotListIsAnError(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	srv := func() (codex.AppServer, error) {
		s, err := f.factory()()
		if err != nil {
			return nil, err
		}
		c := s.(*fakeAppServerConn)
		c.args = c.args[:len(c.args)-2] // codex ignores the Stop hooks
		return c, nil
	}
	st, err := InstallCodex(context.Background(), codexOpts(folder), srv)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "did not list 2 of the 9 workbench hooks")
	assert.Equal(t, ptrFalse(), st.HooksTrusted)
	assert.True(t, st.Skill)
}

func TestStatusCodex_NullTrustWhenAppServerUnavailable(t *testing.T) {
	folder := fakeRepo(t)
	_, err := InstallCodex(context.Background(), codexOpts(folder), codexNotFound) // the skill copy
	require.NoError(t, err)
	unavailable := func() (codex.AppServer, error) {
		return nil, fmt.Errorf("%w: no answer within 10s", codex.ErrCodexTrustUnavailable)
	}
	st, err := StatusCodex(context.Background(), codexOpts(folder), codexResolves, unavailable)
	require.NoError(t, err)
	assert.Equal(t, CodexStatus{Found: true, Skill: true, SkillState: StateUnchanged, GroupPrompt: true,
		TrustError: "codex hook trust unavailable: no answer within 10s"}, st)

	f := newFakeAppServer(t)
	f.listErr = fmt.Errorf("%w: hooks/list: error -32601", codex.ErrCodexTrustUnavailable)
	st, err = StatusCodex(context.Background(), codexOpts(folder), codexResolves, f.factory())
	require.NoError(t, err)
	assert.Nil(t, st.HooksTrusted)
	assert.True(t, st.Found)
	assert.Contains(t, st.TrustError, "hooks/list: error -32601")

	st, err = StatusCodex(context.Background(), codexOpts(folder), codexMissing, codexNotFound)
	require.NoError(t, err)
	assert.False(t, st.Found)
	assert.Nil(t, st.HooksTrusted)
	assert.Empty(t, st.TrustError, "no codex is no error (D5)")

	_, err = InstallCodex(context.Background(), codexOpts(folder), unavailable)
	assert.ErrorIs(t, err, codex.ErrCodexTrustUnavailable, "an install that could not trust says so")
}

func TestStatusCodex_ReportsEachPartAndWritesNothing(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	st, err := StatusCodex(context.Background(), codexOpts(folder), codexResolves, f.factory())
	require.NoError(t, err)
	assert.Equal(t, CodexStatus{Found: true, SkillState: StateMissing}, st)
	assert.Zero(t, f.starts, "never set up for codex: no app-server starts (its answer is unused)")
	assert.Empty(t, f.writes)
	assert.NoDirExists(t, filepath.Join(folder, ".agents"))

	st, err = StatusCodex(context.Background(), codexOpts(folder), codexMissing, f.factory())
	require.NoError(t, err)
	assert.Equal(t, CodexStatus{SkillState: StateMissing}, st, "no codex, no error (D5)")
	st, err = StatusCodex(context.Background(), codexOpts(folder),
		func() error { return fmt.Errorf("%w: loading config: bad", ErrCodexUnresolved) }, f.factory())
	require.NoError(t, err)
	assert.False(t, st.Found)
	assert.Contains(t, st.TrustError, "loading config: bad")
	assert.Zero(t, f.starts)

	_, err = InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	st, err = StatusCodex(context.Background(), codexOpts(folder), codexResolves, f.factory())
	require.NoError(t, err)
	assert.Equal(t, CodexStatus{Found: true, Skill: true, HooksTrusted: ptrTrue(), SkillState: StateUnchanged, GroupPrompt: true}, st)

	// An owner-edited skill is theirs and counts as installed (PROJ-04).
	writeTestFile(t, codexSkillFile(folder), readTestFile(t, codexSkillFile(folder))+"\nmy note\n")
	st, err = StatusCodex(context.Background(), codexOpts(folder), codexResolves, f.factory())
	require.NoError(t, err)
	assert.Equal(t, StateDrifted, st.SkillState)
	assert.True(t, st.Skill)
}

func TestRemoveCodex_RemovesSkillExcludeAndNeverTrust(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	_, err := InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	stateBefore := fmt.Sprint(f.state)
	sk, err := RemoveCodex(context.Background(), codexOpts(folder))
	require.NoError(t, err)
	assert.Equal(t, StateRemoved, sk.State)
	assert.NoDirExists(t, filepath.Join(folder, ".agents"), "an empty .agents goes")
	assert.NotContains(t, readTestFile(t, filepath.Join(folder, ".git", "info", "exclude")), ".agents")
	assert.Equal(t, stateBefore, fmt.Sprint(f.state), "removal never touches the shared hook trust (C4)")
	assert.Equal(t, 1, f.starts, "removal never asks codex")

	// A non-empty .agents (the owner's own skill) stays.
	_, err = InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	writeTestFile(t, filepath.Join(folder, ".agents", "skills", "mine", "SKILL.md"), "mine")
	_, err = RemoveCodex(context.Background(), codexOpts(folder))
	require.NoError(t, err)
	assert.NoDirExists(t, filepath.Join(folder, ".agents", "skills", WorkbenchSkillName))
	assert.FileExists(t, filepath.Join(folder, ".agents", "skills", "mine", "SKILL.md"))
}

func TestRemoveCodex_KeepsAnEditedSkillAndItsExcludeLine(t *testing.T) {
	folder := fakeRepo(t)
	_, err := InstallCodex(context.Background(), codexOpts(folder), codexNotFound)
	require.NoError(t, err)
	writeTestFile(t, codexSkillFile(folder), readTestFile(t, codexSkillFile(folder))+"\nmine\n")
	sk, err := RemoveCodex(context.Background(), codexOpts(folder))
	require.NoError(t, err)
	assert.Equal(t, StateDrifted, sk.State)
	assert.FileExists(t, codexSkillFile(folder))
	assert.Contains(t, readTestFile(t, filepath.Join(folder, ".git", "info", "exclude")), "/.agents/skills/watchtower-workbench/")
}

func TestCodex_FolderGoneAndBadOptions(t *testing.T) {
	gone := filepath.Join(t.TempDir(), "gone")
	_, err := InstallCodex(context.Background(), codexOpts(gone), codexNotFound)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no longer exists")
	_, err = StatusCodex(context.Background(), codexOpts(gone), codexMissing, codexNotFound)
	require.Error(t, err)
	_, err = RemoveCodex(context.Background(), codexOpts(gone))
	require.Error(t, err)
	assert.NoDirExists(t, gone)

	for _, o := range []WorkbenchInstallOptions{
		{WorkbenchID: 0, Folder: "/x", Bin: "b"}, {WorkbenchID: 1, Folder: "rel", Bin: "b"}, {WorkbenchID: 1, Folder: "/x"},
	} {
		_, err := InstallCodex(context.Background(), o, codexNotFound)
		assert.Error(t, err, "%+v", o)
	}
}

// --- imported duplicates ---

const ourClaudeStart = `'/Users/example/Library/Application Support/Watchtower/bin/watchtower' workbench brief --workbench 7`

const importedHooksJSON = `{
  "hooks": {
    "PreToolUse": [
      {"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": "'/Users/example/Library/Application Support/Watchtower/bin/watchtower' workbench ask-guard --workbench 7 --pre-tool-use", "timeout": 5}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo foreign", "timeout": 5}]}
    ],
    "SessionStart": [{"hooks": [{"type": "command", "command": "'/Users/example/Library/Application Support/Watchtower/bin/watchtower' workbench brief --workbench 7", "timeout": 10}]}],
    "Stop": [{"hooks": [
      {"type": "command", "command": "/usr/local/bin/watchtower workbench check --workbench 7 --stop-hook", "timeout": 15},
      {"type": "command", "command": "watchtower workbench check --workbench 8 --stop-hook"},
      {"type": "command", "command": "/opt/watchtower workbench ask-guard --agent codex --stop"}
    ]}]
  },
  "owner": {"keep": 1.50}
}
`

func TestProj04_DedupeKeepsForeignHooks(t *testing.T) {
	folder := t.TempDir()
	file := filepath.Join(folder, ".codex", "hooks.json")
	writeTestFile(t, file, importedHooksJSON)
	changed, err := dedupeImportedHooks(folder, 7)
	require.NoError(t, err)
	assert.True(t, changed)
	assert.JSONEq(t, `{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo foreign", "timeout": 5}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "watchtower workbench check --workbench 8 --stop-hook"}]}]
  },
  "owner": {"keep": 1.50}
}`, readTestFile(t, file))
	assert.Contains(t, readTestFile(t, file), "1.50", "the owner's number literal survives")
	assert.False(t, hasImportedDuplicates(folder, 7))

	changed, err = dedupeImportedHooks(folder, 7)
	require.NoError(t, err)
	assert.False(t, changed, "a second run changes nothing")
}

func TestProj04_DedupeDeletesAFileThatWasOursAlone(t *testing.T) {
	folder := t.TempDir()
	writeTestFile(t, filepath.Join(folder, ".codex", "hooks.json"),
		`{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"`+strings.ReplaceAll(ourClaudeStart, `'`, `'`)+`"}]}]}}`)
	writeTestFile(t, filepath.Join(folder, ".codex", "config.toml"), "[hooks]\n\n[[hooks.SessionStart]]\n[[hooks.SessionStart.hooks]]\ntype = \"command\"\ncommand = \""+ourClaudeStart+"\"\n")
	assert.True(t, hasImportedDuplicates(folder, 7))
	changed, err := dedupeImportedHooks(folder, 7)
	require.NoError(t, err)
	assert.True(t, changed)
	assert.NoDirExists(t, filepath.Join(folder, ".codex"), "emptied files and then .codex go")

	// A file whose hooks were ours but which holds another key stays.
	writeTestFile(t, filepath.Join(folder, ".codex", "hooks.json"),
		`{"x":true,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"`+ourClaudeStart+`"}]}]}}`)
	_, err = dedupeImportedHooks(folder, 7)
	require.NoError(t, err)
	assert.JSONEq(t, `{"x":true}`, readTestFile(t, filepath.Join(folder, ".codex", "hooks.json")))
}

// An imported .codex hook file that is a symlink leaving the folder is never
// written or removed through (PROJ-04, ask #109): the dedupe refuses it and
// both the target and the link stay as they were. One inside the folder is
// still written through.
func TestProj04_DedupeRefusesASymlinkOutsideTheFolder(t *testing.T) {
	ours := `{"x":true,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"` + ourClaudeStart + `"}]}]}}`
	oursTOML := "[hooks]\n\n[[hooks.SessionStart]]\n[[hooks.SessionStart.hooks]]\ntype = \"command\"\ncommand = \"" + ourClaudeStart + "\"\n"
	for name, content := range map[string]string{"hooks.json": ours, "config.toml": oursTOML} {
		folder := t.TempDir()
		outside := filepath.Join(t.TempDir(), name)
		writeTestFile(t, outside, content)
		link := filepath.Join(folder, ".codex", name)
		require.NoError(t, os.MkdirAll(filepath.Dir(link), 0o755))
		require.NoError(t, os.Symlink(outside, link))

		changed, err := dedupeImportedHooks(folder, 7)
		require.ErrorIs(t, err, ErrSymlinkOutsideFolder, name)
		assert.False(t, changed, name)
		assert.Equal(t, content, readTestFile(t, outside), "%s: the outside target stays byte-identical", name)
		got, err := os.Readlink(link)
		require.NoError(t, err, name)
		assert.Equal(t, outside, got, "%s: the link is untouched", name)
	}

	folder := t.TempDir()
	inside := filepath.Join(folder, "dotfiles", "hooks.json")
	writeTestFile(t, inside, ours)
	link := filepath.Join(folder, ".codex", "hooks.json")
	require.NoError(t, os.MkdirAll(filepath.Dir(link), 0o755))
	require.NoError(t, os.Symlink(inside, link))
	changed, err := dedupeImportedHooks(folder, 7)
	require.NoError(t, err)
	assert.True(t, changed)
	assert.JSONEq(t, `{"x":true}`, readTestFile(t, inside))
	info, err := os.Lstat(link)
	require.NoError(t, err)
	assert.NotZero(t, info.Mode()&os.ModeSymlink, "a link inside the folder is kept")
	t.Run("directory link", testProj04DedupeRefusesACodexDirectoryLink)
}

// A .codex directory that is a symlink leaving the folder is refused the
// same way: neither file under it is written or removed. Part of
// TestProj04_DedupeRefusesASymlinkOutsideTheFolder.
func testProj04DedupeRefusesACodexDirectoryLink(t *testing.T) {
	ours := `{"x":true,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"` + ourClaudeStart + `"}]}]}}`
	folder := t.TempDir()
	outsideDir := t.TempDir()
	outside := filepath.Join(outsideDir, "hooks.json")
	writeTestFile(t, outside, ours)
	require.NoError(t, os.Symlink(outsideDir, filepath.Join(folder, ".codex")))

	changed, err := dedupeImportedHooks(folder, 7)
	require.ErrorIs(t, err, ErrSymlinkOutsideFolder)
	assert.False(t, changed)
	assert.Equal(t, ours, readTestFile(t, outside), "the outside file stays byte-identical")
	got, err := os.Readlink(filepath.Join(folder, ".codex"))
	require.NoError(t, err)
	assert.Equal(t, outsideDir, got, "the directory link is untouched")
}

const importedConfigTOML = `# owner's codex settings
model = "gpt-5" # keep this comment

[hooks]

# my own hook
[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "echo mine"

[[hooks.Stop.hooks]]
type = "command"
command = "'/Users/example/Library/Application Support/Watchtower/bin/watchtower' workbench check --workbench 7 --stop-hook"
timeout = 15

[[hooks.SessionStart]]
matcher = "startup"
[[hooks.SessionStart.hooks]]
type = "command"
command = "'/Users/example/Library/Application Support/Watchtower/bin/watchtower' workbench brief --workbench 7"

[mcp_servers.other]
command = "x"
`

const dedupedConfigTOML = `# owner's codex settings
model = "gpt-5" # keep this comment

[hooks]

# my own hook
[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "echo mine"

[mcp_servers.other]
command = "x"
`

func TestProj04_DedupeEditsConfigTOMLInPlace(t *testing.T) {
	folder := t.TempDir()
	file := filepath.Join(folder, ".codex", "config.toml")
	writeTestFile(t, file, importedConfigTOML)
	changed, err := dedupeImportedHooks(folder, 7)
	require.NoError(t, err)
	assert.True(t, changed)
	assert.Equal(t, dedupedConfigTOML, readTestFile(t, file), "comments and layout survive; only our tables go")

	changed, err = dedupeImportedHooks(folder, 7)
	require.NoError(t, err)
	assert.False(t, changed)
}

func TestProj04_DedupeRefusesATOMLShapeItCannotEdit(t *testing.T) {
	folder := t.TempDir()
	file := filepath.Join(folder, ".codex", "config.toml")
	inline := "[hooks]\nSessionStart = [{hooks = [{type = \"command\", command = \"" + ourClaudeStart + "\"}]}]\n"
	writeTestFile(t, file, inline)
	_, err := dedupeImportedHooks(folder, 7)
	assert.ErrorIs(t, err, ErrCodexHooksNotEditable)
	assert.Equal(t, inline, readTestFile(t, file))
	assert.True(t, hasImportedDuplicates(folder, 7))

	// A line edit that would cut a value in half is caught by the re-decode
	// and nothing is written: here a multi-line array line opens with "[".
	split := "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"" + ourClaudeStart + "\"\nx = [\n[1]]\n"
	writeTestFile(t, file, split)
	_, err = dedupeImportedHooks(folder, 7)
	assert.ErrorIs(t, err, ErrCodexHooksNotEditable)
	assert.Equal(t, split, readTestFile(t, file))

	// A [[…]] header inside a multi-line string is not a table.
	tricky := "note = \"\"\"\n[[hooks.Stop]]\n\"\"\"\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"" + ourClaudeStart + "\"\n"
	writeTestFile(t, file, tricky)
	changed, err := dedupeImportedHooks(folder, 7)
	require.NoError(t, err)
	assert.True(t, changed)
	assert.Equal(t, "note = \"\"\"\n[[hooks.Stop]]\n\"\"\"\n", readTestFile(t, file))
}

func TestProj04_MalformedImportedHooksNeverWritten(t *testing.T) {
	for name, tc := range map[string]struct{ file, body string }{
		"json":              {"hooks.json", `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"` + ourClaudeStart + `"}]}]}`},
		"toml":              {"config.toml", "[hooks\n[[hooks.SessionStart.hooks]]\ncommand = \"" + ourClaudeStart + "\"\n"},
		"hooks not a table": {"hooks.json", `{"hooks":"` + strings.ReplaceAll(ourClaudeStart, `'`, ``) + `"}`},
	} {
		t.Run(name, func(t *testing.T) {
			folder := fakeRepo(t)
			file := filepath.Join(folder, ".codex", tc.file)
			writeTestFile(t, file, tc.body)
			_, err := dedupeImportedHooks(folder, 7)
			assert.ErrorIs(t, err, ErrMalformedSettings)
			assert.Contains(t, err.Error(), file)
			assert.Equal(t, tc.body, readTestFile(t, file), "never written")

			st, err := InstallCodex(context.Background(), codexOpts(folder), newFakeAppServer(t).factory())
			assert.ErrorIs(t, err, ErrMalformedSettings)
			assert.True(t, st.Skill, "the other steps still ran")
			st, err = StatusCodex(context.Background(), codexOpts(folder), codexMissing, codexNotFound)
			require.NoError(t, err)
			assert.True(t, st.ImportedDuplicates)
		})
	}
}

func TestProj04_MalformedForeignFileIsNoDuplicate(t *testing.T) {
	folder := fakeRepo(t)
	writeTestFile(t, filepath.Join(folder, ".codex", "hooks.json"), `{"hooks":`)
	st, err := StatusCodex(context.Background(), codexOpts(folder), codexMissing, codexNotFound)
	require.NoError(t, err)
	assert.False(t, st.ImportedDuplicates)
}

func TestDedupe_DegenerateFiles(t *testing.T) {
	for name, files := range map[string]map[string]string{
		"none":             {},
		"empty json":       {"hooks.json": ""},
		"empty toml":       {"config.toml": ""},
		"no hooks":         {"hooks.json": `{"a":1}`, "config.toml": "model = \"x\"\n"},
		"hooks not arrays": {"config.toml": "[hooks.state]\nx = 1\n"},
	} {
		t.Run(name, func(t *testing.T) {
			folder := t.TempDir()
			for f, body := range files {
				writeTestFile(t, filepath.Join(folder, ".codex", f), body)
			}
			changed, err := dedupeImportedHooks(folder, 7)
			require.NoError(t, err)
			assert.False(t, changed)
			assert.False(t, hasImportedDuplicates(folder, 7))
			for f, body := range files {
				assert.Equal(t, body, readTestFile(t, filepath.Join(folder, ".codex", f)))
			}
		})
	}
}

func TestEnvWithPathPrepend(t *testing.T) {
	assert.Equal(t, []string{"A=1", "PATH=/d:/usr/bin"}, envWithPathPrepend([]string{"PATH=/usr/bin", "A=1"}, "/d"))
	assert.Equal(t, []string{"A=1", "PATH=/d"}, envWithPathPrepend([]string{"A=1"}, "/d"))
	assert.Equal(t, []string{"PATH=/d"}, envWithPathPrepend([]string{"PATH="}, "/d"))
}

func TestMultilineStringState(t *testing.T) {
	for _, tc := range []struct{ line, open, want string }{
		{`a = """x`, "", `"""`},
		{`a = """x"""`, "", ""},
		{`x"""`, `"""`, ""},
		{`b = '''`, "", `'''`},
		{`plain`, `'''`, `'''`},
		{`a = "x"`, "", ""},
	} {
		assert.Equal(t, tc.want, multilineStringState(tc.line, tc.open), "%q from %q", tc.line, tc.open)
	}
}

func TestStatusCodex_ReportsEveryTrustFailure(t *testing.T) {
	folder := fakeRepo(t)
	_, err := InstallCodex(context.Background(), codexOpts(folder), codexNotFound) // the skill copy
	require.NoError(t, err)
	f := newFakeAppServer(t)
	srv := func() (codex.AppServer, error) {
		s, err := f.factory()()
		if err != nil {
			return nil, err
		}
		c := s.(*fakeAppServerConn)
		c.args = c.args[:len(c.args)-2] // codex ignores the Stop hooks
		return c, nil
	}
	st, err := StatusCodex(context.Background(), codexOpts(folder), codexResolves, srv)
	require.NoError(t, err)
	assert.Equal(t, ptrFalse(), st.HooksTrusted)
	assert.Contains(t, st.TrustError, "did not list 2 of the 9 workbench hooks")

	unresolved := func() (codex.AppServer, error) {
		return nil, fmt.Errorf("%w: loading config: bad toml", ErrCodexUnresolved)
	}
	st, err = StatusCodex(context.Background(), codexOpts(folder), func() error { _, err := unresolved(); return err }, unresolved)
	require.NoError(t, err)
	assert.False(t, st.Found, "a config that did not load is no resolved codex")
	assert.Nil(t, st.HooksTrusted)
	assert.Contains(t, st.TrustError, "loading config: bad toml")

	f.closeErr = errors.New("kill: no such process")
	st, err = StatusCodex(context.Background(), codexOpts(folder), codexResolves, f.factory())
	require.NoError(t, err)
	assert.Nil(t, st.HooksTrusted)
	assert.Contains(t, st.TrustError, "no such process")
}

func TestInstallCodex_TrustWriteAndCloseErrors(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	f.trustErr = fmt.Errorf("%w: config/batchWrite: error -32000", codex.ErrCodexTrustUnavailable)
	st, err := InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.ErrorIs(t, err, codex.ErrCodexTrustUnavailable)
	assert.Nil(t, st.HooksTrusted)
	assert.True(t, st.Found)
	assert.True(t, st.Skill, "the skill copy is in despite the trust failure")
	assert.Empty(t, f.state, "nothing was trusted")

	f.trustErr = nil
	f.closeErr = errors.New("kill: no such process")
	st, err = InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no such process")
	assert.Nil(t, st.HooksTrusted, "a close failure leaves the trust unconfirmed")

	_, err = InstallCodex(context.Background(), codexOpts(folder), func() (codex.AppServer, error) {
		return nil, fmt.Errorf("%w: loading config: bad toml", ErrCodexUnresolved)
	})
	require.ErrorIs(t, err, ErrCodexUnresolved)
}

// Spec I4 against the real codex: a live capture (codex 0.159.2, a scratch
// CODEX_HOME, 2026-10-12) of InstallCodex's config/batchWrite upsert at
// keyPath hooks.state, run with Bin /Users/example/bin/watchtower, over a
// config.toml holding a comment, unrelated keys and two foreign hooks.state
// entries. codex merges: everything that was there stays byte for byte, and
// the only new entries are our hook set's session-flags keys.
func TestProj04_LiveUpsertKeepsForeignHooksState(t *testing.T) {
	const bin = "/Users/example/bin/watchtower"
	beforeRaw := readTestFile(t, filepath.Join("testdata", "codex_hooks_state_upsert.before.toml"))
	afterRaw := readTestFile(t, filepath.Join("testdata", "codex_hooks_state_upsert.after.toml"))
	var before, after map[string]any
	require.NoError(t, toml.Unmarshal([]byte(beforeRaw), &before))
	require.NoError(t, toml.Unmarshal([]byte(afterRaw), &after))

	assert.Contains(t, afterRaw, "# Owner's own note: this comment must survive.\n")
	assert.Equal(t, before["model"], after["model"])
	assert.Equal(t, before["tui"], after["tui"])

	stateOf := func(doc map[string]any) map[string]any {
		hooks, _ := doc["hooks"].(map[string]any)
		state, _ := hooks["state"].(map[string]any)
		return state
	}
	beforeState, afterState := stateOf(before), stateOf(after)
	require.Len(t, beforeState, 2)
	added := map[string]bool{}
	for k := range afterState {
		if prior, ok := beforeState[k]; ok {
			assert.Equal(t, prior, afterState[k], "foreign entry %s changed", k)
			continue
		}
		added[k] = true
	}
	for k := range beforeState {
		assert.Contains(t, afterState, k, "foreign entry %s dropped", k)
	}
	ours := map[string]bool{}
	for _, e := range sessionFlagHooks(codexAppServerArgs(bin)) {
		ours[e.Key] = true
	}
	assert.Equal(t, ours, added, "the upsert adds exactly our hook set's keys")
}

// An outdated skill copy (a previously shipped version, never edited) is
// set up: Skill true, SkillState "updated" (the Desktop's Repair), and the
// trust is still asked so an untrusted hook is not hidden (#399 m2).
func TestStatusCodex_OutdatedSkillIsSetUpAndAsked(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	_, err := InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	prev := readTestFile(t, filepath.Join("testdata", "watchtower-workbench-v6.md"))
	writeTestFile(t, codexSkillFile(folder), prev)
	sum := sha256.Sum256([]byte(prev)) // the copy is the version we wrote last
	writeTestFile(t, filepath.Join(filepath.Dir(codexSkillFile(folder)), shippedDigestFile), hex.EncodeToString(sum[:]))
	for k := range f.state {
		f.state[k] = "sha256:stale"
		break
	}
	st, err := StatusCodex(context.Background(), codexOpts(folder), codexResolves, f.factory())
	require.NoError(t, err)
	assert.Equal(t, StateUpdated, st.SkillState)
	assert.True(t, st.Skill)
	assert.Equal(t, ptrFalse(), st.HooksTrusted)
}

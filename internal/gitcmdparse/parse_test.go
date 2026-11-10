package gitcmdparse

import (
	"path"
	"reflect"
	"testing"
)

func wt(p, branch, dir string) Created {
	return Created{Kind: KindWorktree, Path: p, Branch: branch, Dir: dir}
}

func br(name, dir string) Created {
	return Created{Kind: KindBranch, Branch: name, Dir: dir}
}

var parseCases = []struct {
	name    string
	command string
	cwd     string
	want    []Created
}{
	// Plan table.
	{"worktree add with -b", "git worktree add /tmp/a -b feat/x", "/tmp/r", []Created{wt("/tmp/a", "feat/x", "/tmp/r")}},
	{"cd then relative worktree with -B", "cd /tmp/r && git worktree add ../wt -B y", "/tmp/s", []Created{wt("/tmp/wt", "y", "/tmp/r")}},
	{"git -C and a quoted path with spaces", `git -C /tmp/r worktree add "dir with space"`, "/tmp/s", []Created{wt("/tmp/r/dir with space", "", "/tmp/r")}},
	{"branch create", "git branch topic", "/tmp/r", []Created{br("topic", "/tmp/r")}},
	{"branch delete", "git branch -D topic", "/tmp/r", nil},
	{"branch show-current", "git branch --show-current", "/tmp/r", nil},
	{"checkout -b", "git checkout -b b1", "/tmp/r", []Created{br("b1", "/tmp/r")}},
	{"switch -c", "git switch -c b2", "/tmp/r", []Created{br("b2", "/tmp/r")}},
	{"echo holding git", "echo git branch x", "/tmp/r", nil},
	{"variable in a word", "git worktree add $WT -b z", "/tmp/r", nil},
	{"backtick in a word", "git branch `x`", "/tmp/r", nil},
	{"chain of four segments", "a && git branch b ; git switch -C c | cat", "/tmp/r", []Created{br("b", "/tmp/r"), br("c", "/tmp/r")}},
	{"unterminated quote", `git branch "x`, "/tmp/r", nil},

	// Review Focus shapes.
	{"cd to a variable leaves the directory unknown", `cd "$WT" && git worktree add ../x -b y`, "/tmp/r", nil},
	{"git -C relative", "git -C sub worktree add ../x -b y", "/tmp/r", []Created{wt("/tmp/r/x", "y", "/tmp/r/sub")}},
	{"echo in a chain", `echo "git branch x" && git branch y`, "/tmp/r", []Created{br("y", "/tmp/r")}},
	{"quoted chain inside a commit message", `git commit -m "a && git branch q"`, "/tmp/r", nil},

	// worktree add options.
	{"worktree add -f", "git worktree add -f /tmp/a", "/tmp/r", []Created{wt("/tmp/a", "", "/tmp/r")}},
	{"worktree add --detach with commit", "git worktree add --detach /tmp/a HEAD~1", "/tmp/r", []Created{wt("/tmp/a", "", "/tmp/r")}},
	{"worktree add attached -bname", "git worktree add -bfeat /tmp/a main", "/tmp/r", []Created{wt("/tmp/a", "feat", "/tmp/r")}},
	{"worktree add --lock --reason", `git worktree add --lock --reason "why not" -b n /tmp/a`, "/tmp/r", []Created{wt("/tmp/a", "n", "/tmp/r")}},
	{"worktree add backslash space", `git worktree add dir\ x`, "/tmp/r", []Created{wt("/tmp/r/dir x", "", "/tmp/r")}},
	{"worktree add single quotes", `git worktree add '/tmp/a b' -b 'n'`, "/tmp/r", []Created{wt("/tmp/a b", "n", "/tmp/r")}},
	{"worktree add without a path", "git worktree add -b x", "/tmp/r", nil},
	{"worktree add with too many positionals", "git worktree add /tmp/a b c", "/tmp/r", nil},
	{"worktree add command substitution", "git worktree add /tmp/a $(git rev-parse HEAD)", "/tmp/r", nil},
	{"worktree list", "git worktree list", "/tmp/r", nil},
	{"worktree remove", "git worktree remove /tmp/a", "/tmp/r", nil},
	{"worktree add tilde path", "git worktree add ~/a", "/tmp/r", nil},

	// branch modes.
	{"branch with start point", "git branch x main", "/tmp/r", []Created{br("x", "/tmp/r")}},
	{"branch --track", "git branch --track x origin/x", "/tmp/r", []Created{br("x", "/tmp/r")}},
	{"branch -f moves an existing branch", "git branch -f x main", "/tmp/r", nil},
	{"branch --force", "git branch --force x", "/tmp/r", nil},
	{"branch -c copies", "git branch -c old new", "/tmp/r", []Created{br("new", "/tmp/r")}},
	{"branch -C copies the current branch", "git branch -C new", "/tmp/r", []Created{br("new", "/tmp/r")}},
	{"branch --copy", "git branch --copy old new", "/tmp/r", []Created{br("new", "/tmp/r")}},
	{"branch -m renames", "git branch -m a b", "/tmp/r", nil},
	{"branch list", "git branch", "/tmp/r", nil},
	{"branch --list pattern", "git branch --list feat", "/tmp/r", nil},
	{"branch -u", "git branch -u origin/x", "/tmp/r", nil},
	{"branch named HEAD", "git branch HEAD", "/tmp/r", nil},
	{"branch with too many positionals", "git branch a b c", "/tmp/r", nil},
	{"branch with a glob", "git branch feat*", "/tmp/r", nil},

	// checkout and switch.
	{"checkout without -b", "git checkout main", "/tmp/r", nil},
	{"checkout attached -bname", "git checkout -bfoo", "/tmp/r", []Created{br("foo", "/tmp/r")}},
	{"checkout -B with start", "git checkout -B foo origin/foo", "/tmp/r", []Created{br("foo", "/tmp/r")}},
	{"checkout --orphan", "git checkout --orphan pages", "/tmp/r", []Created{br("pages", "/tmp/r")}},
	{"switch --create=", "git switch --create=n", "/tmp/r", []Created{br("n", "/tmp/r")}},
	{"switch --force-create", "git switch --force-create n main", "/tmp/r", []Created{br("n", "/tmp/r")}},
	{"switch plain", "git switch main", "/tmp/r", nil},
	{"switch -c without a name", "git switch -c", "/tmp/r", nil},

	// Directories.
	{"cd relative", "cd sub && git branch y", "/tmp/r", []Created{br("y", "/tmp/r/sub")}},
	{"cd home", "cd && git branch y", "/tmp/r", nil},
	{"cd tilde", "cd ~/x && git branch y", "/tmp/r", nil},
	{"cd dash", "cd - && git branch y", "/tmp/r", nil},
	{"cd -P", "cd -P /tmp/a && git branch y", "/tmp/r", []Created{br("y", "/tmp/a")}},
	{"cd back to a known dir", `cd "$X"; cd /tmp/a; git branch y`, "/tmp/r", []Created{br("y", "/tmp/a")}},
	{"pushd makes it unknown", "pushd /tmp/a && git branch y", "/tmp/r", nil},
	{"subshell cd does not leak", "(cd /tmp/a && git branch x) && git branch y", "/tmp/r", []Created{br("x", "/tmp/a"), br("y", "/tmp/r")}},
	{"relative cwd", "git branch y", "r", nil},
	{"empty cwd", "git branch y", "", nil},
	{"cwd is cleaned", "git branch y", "/tmp/r/../s/", []Created{br("y", "/tmp/s")}},

	// git global options and command forms.
	{"global -c and --no-pager", "git -c core.x=y --no-pager branch z", "/tmp/r", []Created{br("z", "/tmp/r")}},
	{"--git-dir", "git --git-dir=/tmp/x branch y", "/tmp/r", nil},
	{"--work-tree separate", "git --work-tree /tmp/x branch y", "/tmp/r", nil},
	{"unknown short global", "git -Z branch y", "/tmp/r", nil},
	{"absolute git binary", "/usr/bin/git branch y", "/tmp/r", []Created{br("y", "/tmp/r")}},
	{"env assignment", "FOO=1 git branch y", "/tmp/r", []Created{br("y", "/tmp/r")}},
	{"GIT_ env assignment", "GIT_DIR=/tmp/x git branch y", "/tmp/r", nil},
	{"git as an argument", "xargs git branch y", "/tmp/r", nil},
	{"variable git binary", "$GIT branch y", "/tmp/r", nil},
	{"if keyword", "if git checkout -b y; then echo ok; fi", "/tmp/r", []Created{br("y", "/tmp/r")}},

	// Lexing.
	{"redirections", "git branch x 2>&1 >/dev/null", "/tmp/r", []Created{br("x", "/tmp/r")}},
	{"&> redirection", "git branch x &>/dev/null", "/tmp/r", []Created{br("x", "/tmp/r")}},
	{"redirection without target", "git branch x >", "/tmp/r", nil},
	{"background operator", "git branch x & git branch y", "/tmp/r", []Created{br("x", "/tmp/r"), br("y", "/tmp/r")}},
	{"||", "git branch x || git branch y", "/tmp/r", []Created{br("x", "/tmp/r"), br("y", "/tmp/r")}},
	{"newlines", "git branch x\ngit branch y", "/tmp/r", []Created{br("x", "/tmp/r"), br("y", "/tmp/r")}},
	{"line continuation", "git branch \\\n x", "/tmp/r", []Created{br("x", "/tmp/r")}},
	{"comment", "# git branch x\ngit branch y # git branch z", "/tmp/r", []Created{br("y", "/tmp/r")}},
	{"heredoc body is not a command", "git commit -F - <<'EOF'\ngit branch x\nEOF\ngit branch y", "/tmp/r", []Created{br("y", "/tmp/r")}},
	{"heredoc with tabs", "cat <<-EOF\n\tgit branch x\n\tEOF\ngit branch y", "/tmp/r", []Created{br("y", "/tmp/r")}},
	{"unterminated heredoc", "cat <<EOF\ngit branch x", "/tmp/r", nil},
	{"here-string", "git branch y <<< 'git branch x'", "/tmp/r", []Created{br("y", "/tmp/r")}},
	{"unterminated substitution", "git branch $(x", "/tmp/r", nil},
	{"nested substitution is skipped", `echo "$(git branch x)" && git branch y`, "/tmp/r", []Created{br("y", "/tmp/r")}},
	{"single-quoted dollar is still skipped", `git branch 'a$b'`, "/tmp/r", nil},
	{"escaped quote in double quotes", `git worktree add "a\"b"`, "/tmp/r", []Created{wt(`/tmp/r/a"b`, "", "/tmp/r")}},
	{"empty", "", "/tmp/r", nil},

	// Subshells: pipelines and background.
	{"cd in a pipeline does not leak", "cd /tmp/other | cat; git branch topic", "/tmp/r", []Created{br("topic", "/tmp/r")}},
	{"cd after a pipe does not leak", "cat | cd /tmp/other; git branch topic", "/tmp/r", []Created{br("topic", "/tmp/r")}},
	{"cd |& does not leak", "cd /tmp/other |& cat; git branch topic", "/tmp/r", []Created{br("topic", "/tmp/r")}},
	{"backgrounded cd does not leak", "cd /tmp/other & git branch topic", "/tmp/r", []Created{br("topic", "/tmp/r")}},
	{"backgrounded chain keeps its own cd", "cd /tmp/a && git branch x & git branch y", "/tmp/r", []Created{br("x", "/tmp/a"), br("y", "/tmp/r")}},
	{"cd before a pipeline still applies", "cd /tmp/a && git branch x | cat", "/tmp/r", []Created{br("x", "/tmp/a")}},

	// Conditional cd.
	{"cd || git", "cd /tmp/x || git branch t", "/tmp/r", nil},
	{"cd after ||", "false || cd /tmp/x && git branch t", "/tmp/r", nil},
	{"cd then || later", "cd /tmp/x && a || git branch t", "/tmp/r", nil},
	{"cd not first in its chain is unknown after it", "false && cd /tmp/x; git branch t", "/tmp/r", nil},
	{"cd not first still applies inside its chain", "a && cd /tmp/x && git branch t", "/tmp/r", []Created{br("t", "/tmp/x")}},
	{"first cd persists across ;", "cd /tmp/x; git branch t", "/tmp/r", []Created{br("t", "/tmp/x")}},
	{"first cd persists across newline", "cd /tmp/x && a\ngit branch t", "/tmp/r", []Created{br("t", "/tmp/x")}},
	{"cd in an if condition", "if cd /tmp/x; then git branch t; fi", "/tmp/r", nil},
	{"cd in an if body", "if a; then cd /tmp/x; fi; git branch t", "/tmp/r", nil},
	{"cd in a while condition", "while cd /tmp/x; do git branch t; done", "/tmp/r", nil},
	{"negated cd", "! cd /tmp/x && git branch t", "/tmp/r", nil},
	{"git after a closed if keeps the dir", "if a; then b; fi; git branch t", "/tmp/r", []Created{br("t", "/tmp/r")}},

	// Functions and case.
	{"function definition", "f() { cd /tmp/x; }; git branch t", "/tmp/r", nil},
	{"function keyword", "function f { cd /tmp/x; }; git branch t", "/tmp/r", nil},
	{"case pattern does not pop a subshell", "(case a in a) cd /tmp/x;; esac; git branch t)", "/tmp/r", nil},
	{"case then git", "case a in a) b;; esac; git branch t", "/tmp/r", nil},

	// Help.
	{"worktree add -h", "git worktree add -h /tmp/a", "/tmp/r", nil},
	{"worktree add --help", "git worktree add --help", "/tmp/r", nil},
	{"switch -h", "git switch -h -c x", "/tmp/r", nil},
	{"checkout --help", "git checkout --help -b x", "/tmp/r", nil},
	{"branch -h", "git branch -h x", "/tmp/r", nil},
}

func TestParse(t *testing.T) {
	for _, tc := range parseCases {
		t.Run(tc.name, func(t *testing.T) {
			got := Parse(tc.command, tc.cwd)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("Parse(%q, %q)\n got: %#v\nwant: %#v", tc.command, tc.cwd, got, tc.want)
			}
		})
	}
}

func FuzzParse(f *testing.F) {
	for _, tc := range parseCases {
		f.Add(tc.command, tc.cwd)
	}
	f.Fuzz(func(t *testing.T, command, cwd string) {
		for _, c := range Parse(command, cwd) {
			if c.Kind != KindWorktree && c.Kind != KindBranch {
				t.Fatalf("unknown kind %q", c.Kind)
			}
			if !path.IsAbs(c.Dir) || path.Clean(c.Dir) != c.Dir {
				t.Fatalf("Dir %q is not absolute and clean", c.Dir)
			}
			if c.Kind == KindWorktree && (!path.IsAbs(c.Path) || path.Clean(c.Path) != c.Path) {
				t.Fatalf("Path %q is not absolute and clean", c.Path)
			}
			if c.Kind == KindBranch && (c.Branch == "" || c.Path != "") {
				t.Fatalf("branch record %#v", c)
			}
		}
	})
}

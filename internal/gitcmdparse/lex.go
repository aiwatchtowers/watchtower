package gitcmdparse

import "strings"

type tokKind int

const (
	tokWord tokKind = iota
	tokOp           // a separator: && || ; | |& & ;; newline ( )
)

type token struct {
	kind    tokKind
	text    string // a word with its quotes removed, or the operator
	tainted bool   // the word would be expanded by the shell
}

type heredoc struct {
	delim     string
	stripTabs bool
}

type lexer struct {
	s        string
	i        int
	toks     []token
	heredocs []heredoc
	wordEnd  int // index just past the last word, -1 after anything else

	lastTainted bool // set by doubleQuoted
}

// redirOps are the redirection operators, longest first.
var redirOps = []string{"&>>", "<<<", "<<-", ">>", "<<", ">&", "<&", "<>", ">|", "&>", "<", ">"}

// lex splits s into words and separators. Redirections and their targets are
// dropped, here-doc bodies and comments skipped. ok is false when s does not
// lex as a complete command.
func lex(s string) ([]token, bool) {
	l := &lexer{s: s, wordEnd: -1}
	for l.i < len(s) {
		c := s[l.i]
		switch {
		case c == ' ' || c == '\t' || c == '\r':
			l.i++
		case c == '\n':
			l.i++
			l.op("\n")
			if !l.heredocBodies() {
				return nil, false
			}
		case c == '\\' && l.i+1 < len(s) && s[l.i+1] == '\n':
			l.i += 2
		case c == '#':
			for l.i < len(s) && s[l.i] != '\n' {
				l.i++
			}
		case c == '<' || c == '>' || (c == '&' && l.i+1 < len(s) && s[l.i+1] == '>'):
			if !l.redirect() {
				return nil, false
			}
		case c == ';' || c == '&' || c == '|' || c == '(' || c == ')':
			l.operator()
		default:
			text, tainted, ok := l.word()
			if !ok {
				return nil, false
			}
			l.toks = append(l.toks, token{kind: tokWord, text: text, tainted: tainted})
			l.wordEnd = l.i
		}
	}
	if len(l.heredocs) > 0 {
		return nil, false
	}
	return l.toks, true
}

func (l *lexer) op(text string) {
	l.toks = append(l.toks, token{kind: tokOp, text: text})
	l.wordEnd = -1
}

func (l *lexer) operator() {
	if l.i+1 < len(l.s) {
		switch two := l.s[l.i : l.i+2]; two {
		case "&&", "||", ";;", "|&":
			l.i += 2
			l.op(two)
			return
		}
	}
	l.i++
	l.op(l.s[l.i-1 : l.i])
}

// redirect consumes a redirection operator and its target. An all-digit word
// right before it is its file descriptor and is dropped too.
func (l *lexer) redirect() bool {
	if n := len(l.toks); n > 0 && l.wordEnd == l.i && isDigits(l.toks[n-1].text) {
		l.toks = l.toks[:n-1]
	}
	op := ""
	for _, o := range redirOps {
		if strings.HasPrefix(l.s[l.i:], o) {
			op = o
			break
		}
	}
	l.i += len(op)
	for l.i < len(l.s) && (l.s[l.i] == ' ' || l.s[l.i] == '\t') {
		l.i++
	}
	if l.i >= len(l.s) || strings.IndexByte("\n;&|()<>#", l.s[l.i]) >= 0 {
		return false
	}
	target, _, ok := l.word()
	if !ok {
		return false
	}
	if op == "<<" || op == "<<-" {
		l.heredocs = append(l.heredocs, heredoc{delim: target, stripTabs: op == "<<-"})
	}
	l.wordEnd = -1
	return true
}

// heredocBodies skips the bodies of the here-docs opened on the line just
// ended.
func (l *lexer) heredocBodies() bool {
	for _, h := range l.heredocs {
		for {
			if l.i >= len(l.s) {
				return false
			}
			line := l.s[l.i:]
			if end := strings.IndexByte(line, '\n'); end >= 0 {
				line = line[:end]
				l.i += end + 1
			} else {
				l.i = len(l.s)
			}
			if h.stripTabs {
				line = strings.TrimLeft(line, "\t")
			}
			if line == h.delim {
				break
			}
		}
	}
	l.heredocs = nil
	return true
}

// word reads one word, removing quotes and backslashes.
func (l *lexer) word() (string, bool, bool) {
	var b strings.Builder
	tainted := false
	start := l.i
	for l.i < len(l.s) {
		c := l.s[l.i]
		switch c {
		case ' ', '\t', '\r', '\n', ';', '&', '|', '(', ')', '<', '>':
			return b.String(), tainted, true
		case '\\':
			if l.i+1 >= len(l.s) {
				l.i++
				continue
			}
			if l.s[l.i+1] != '\n' {
				b.WriteByte(l.s[l.i+1])
			}
			l.i += 2
		case '\'':
			end := strings.IndexByte(l.s[l.i+1:], '\'')
			if end < 0 {
				return "", false, false
			}
			part := l.s[l.i+1 : l.i+1+end]
			tainted = tainted || strings.ContainsAny(part, "$`")
			b.WriteString(part)
			l.i += end + 2
		case '"':
			if !l.doubleQuoted(&b) {
				return "", false, false
			}
			tainted = tainted || l.lastTainted
		case '$', '`':
			tainted = true
			if !l.expansion() {
				return "", false, false
			}
		case '*', '?', '[':
			tainted = true
			b.WriteByte(c)
			l.i++
		case '~':
			tainted = tainted || l.i == start
			b.WriteByte(c)
			l.i++
		default:
			b.WriteByte(c)
			l.i++
		}
	}
	return b.String(), tainted, true
}

// doubleQuoted reads a "…" part into b; it sets l.lastTainted when the part
// holds an expansion.
func (l *lexer) doubleQuoted(b *strings.Builder) bool {
	l.lastTainted = false
	l.i++
	for l.i < len(l.s) {
		c := l.s[l.i]
		switch c {
		case '"':
			l.i++
			return true
		case '\\':
			if l.i+1 < len(l.s) && strings.IndexByte("$`\"\\\n", l.s[l.i+1]) >= 0 {
				if l.s[l.i+1] != '\n' {
					b.WriteByte(l.s[l.i+1])
				}
				l.i += 2
				continue
			}
			b.WriteByte(c)
			l.i++
		case '$', '`':
			l.lastTainted = true
			if !l.expansion() {
				return false
			}
		default:
			b.WriteByte(c)
			l.i++
		}
	}
	return false
}

// expansion skips a `$…` or backtick expansion starting at l.i, contents
// unread: $(…), $((…)), ${…}, `…`, or a bare $ (the variable name that follows
// stays in the word, which is tainted anyway).
func (l *lexer) expansion() bool {
	end := -1
	switch {
	case l.s[l.i] == '`':
		end = closing(l.s, l.i, '`', '`')
	case l.i+1 < len(l.s) && l.s[l.i+1] == '(':
		end = closing(l.s, l.i+1, '(', ')')
	case l.i+1 < len(l.s) && l.s[l.i+1] == '{':
		end = closing(l.s, l.i+1, '{', '}')
	default:
		l.i++
		return true
	}
	if end < 0 {
		return false
	}
	l.i = end
	return true
}

// closing returns the index just past the close that matches s[open], or -1.
// Backslashes and, outside backticks, quotes inside are honoured.
func closing(s string, open int, openCh, closeCh byte) int {
	depth := 1
	for j := open + 1; j < len(s); j++ {
		c := s[j]
		switch {
		case c == '\\':
			j++
		case c == closeCh:
			depth--
			if depth == 0 {
				return j + 1
			}
		case c == openCh:
			depth++
		case openCh != '`' && c == '\'':
			end := strings.IndexByte(s[j+1:], '\'')
			if end < 0 {
				return -1
			}
			j += end + 1
		case openCh != '`' && c == '"':
			for j++; j < len(s) && s[j] != '"'; j++ {
				if s[j] == '\\' {
					j++
				}
			}
			if j >= len(s) {
				return -1
			}
		}
	}
	return -1
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

package reviewdiff

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// AppendLessonRule adds "- <text>" under the "## <lensName>" section of
// <workbenchFolder>/.watchtower/review.md (the section is created when it is
// missing, the file too). It is the only writer of that file and the only
// thing Accept does: .watchtower must be a real directory and review.md a
// regular file read under LoadLenses' rules; a question already in the lens
// writes nothing. The result goes to a temp file in .watchtower and is
// renamed over review.md.
func AppendLessonRule(workbenchFolder, lensName, text string) error {
	lensName = strings.TrimSpace(lensName)
	text = strings.TrimSpace(text)
	if text == "" || strings.ContainsAny(text, "\r\n") {
		return errors.New("a lesson rule is one non-empty line")
	}
	target := LensID(lensName)
	if target == "" || strings.ContainsAny(lensName, "\r\n") {
		return fmt.Errorf("lens name %q has no latin letters or digits", lensName)
	}

	dir := filepath.Join(workbenchFolder, ".watchtower")
	di, err := os.Lstat(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if err := os.Mkdir(dir, 0o755); err != nil {
			return fmt.Errorf("creating .watchtower: %w", err)
		}
	case err != nil:
		return fmt.Errorf("reading .watchtower: %w", err)
	case !di.IsDir():
		return errors.New(".watchtower is not a real directory")
	}

	data, note := readLensFile(workbenchFolder)
	if note != "" {
		return errors.New(lensFileNotePrefix + note)
	}
	path := filepath.Join(dir, "review.md")
	if data == nil {
		out := "## " + lensName + "\n- " + text + "\n"
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o644)
		if err != nil {
			return fmt.Errorf("creating review.md: %w", err)
		}
		if _, err := f.WriteString(out); err != nil {
			_ = f.Close()
			_ = os.Remove(path)
			return fmt.Errorf("writing review.md: %w", err)
		}
		return f.Close()
	}

	out, changed := insertRule(string(data), lensName, target, text)
	if !changed {
		return nil
	}
	if len(out) > MaxLensFileBytes {
		return errors.New(lensFileNotePrefix + "the rule would make the file larger than 64 KB")
	}
	tmp, err := os.CreateTemp(dir, ".review-*.tmp")
	if err != nil {
		return fmt.Errorf("writing review.md: %w", err)
	}
	tmpName := tmp.Name()
	_, werr := tmp.WriteString(out)
	cerr := tmp.Close()
	if err := errors.Join(werr, cerr, os.Chmod(tmpName, 0o644)); err != nil {
		_ = os.Remove(tmpName)
		return fmt.Errorf("writing review.md: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return fmt.Errorf("replacing review.md: %w", err)
	}
	return nil
}

// insertRule returns the file text with the rule added and whether it changed.
func insertRule(content, lensName, target, text string) (string, bool) {
	key := ItemKey(text)
	lines := strings.Split(strings.TrimSuffix(content, "\n"), "\n")
	cur := ""   // lens id of the section we are in
	first := -1 // index of the first "## " heading of the target lens
	last := -1  // last non-blank line of that section
	inFirst := false
	for i, raw := range lines {
		line := strings.TrimSpace(raw)
		if i == 0 {
			line = strings.TrimSpace(strings.TrimPrefix(raw, "\xef\xbb\xbf"))
		}
		switch {
		case strings.HasPrefix(line, "## "):
			cur = LensID(strings.TrimSpace(line[3:]))
			if cur == target && first < 0 {
				first, last, inFirst = i, i, true
			} else {
				inFirst = false
			}
		case cur == target && (line == "-" || strings.HasPrefix(line, "- ")):
			if ItemKey(strings.TrimPrefix(line, "-")) == key {
				return content, false
			}
			fallthrough
		default:
			if inFirst && line != "" {
				last = i
			}
		}
	}
	if first >= 0 {
		out := append(append(append([]string{}, lines[:last+1]...), "- "+text), lines[last+1:]...)
		return strings.Join(out, "\n") + "\n", true
	}
	if strings.TrimSpace(content) == "" {
		return "## " + lensName + "\n- " + text + "\n", true
	}
	return strings.TrimSuffix(content, "\n") + "\n\n## " + lensName + "\n- " + text + "\n", true
}

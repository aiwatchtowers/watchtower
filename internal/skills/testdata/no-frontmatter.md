# No frontmatter

This file has no YAML frontmatter block at all, so it is skipped by both
parsers.

---

The `---` above is a markdown rule inside the body, not a frontmatter
delimiter: a parser that scans for a closing delimiter it never opened would
wrongly accept this file.

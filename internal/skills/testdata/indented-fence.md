 ---
description: Opens its frontmatter with an indented fence, which opens nothing.
persona: secretary
---

# Indented fence

Body. The Go parser matches the literal prefix `---\n`, so a leading space
means this file has no frontmatter block at all — both parsers skip it.

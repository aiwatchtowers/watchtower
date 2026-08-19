---
description: Carries a frontmatter line that is not a key/value pair.
persona: secretary
this line has no colon
---

# Bare line

Body. Skipped by both parsers: yaml.v3 cannot read the bare line as a mapping
entry, so the Swift line parser must refuse it too rather than skipping past it.

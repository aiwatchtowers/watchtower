---
- foo: bar
description: A skill whose frontmatter opens with a sequence entry.
persona: secretary
---

# Structural key

Body. `- foo:` is a sequence entry, not a mapping key, so yaml.v3 refuses the
document. Keys get the same scrutiny as values on the Swift side, which is what
lands both parsers on the same verdict here.

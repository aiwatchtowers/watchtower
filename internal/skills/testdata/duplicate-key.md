---
description: Names the same frontmatter key twice.
persona: secretary
author: first
author: second
---

# Duplicate key

Body. yaml.v3 refuses a repeated mapping key even on a field it never reads, so
a line parser that simply lets the last value win would list a skill the Go
side cannot load.

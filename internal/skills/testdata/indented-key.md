---
description: A key line indented under the one before it.
  persona: secretary
---

# Indented key

Body. yaml.v3 reads the indented line as a continuation of the previous entry
and then refuses the mapping value inside it; the Swift parser refuses every
indented line outright, which lands on the same verdict here.

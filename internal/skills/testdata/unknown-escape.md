---
description: "a\qb"
persona: secretary
---

# Unknown escape

Body. `\q` is not a YAML escape (nor is `\/`, legal though it is in JSON), so
yaml.v3 refuses the scalar instead of passing the backslash through as text.

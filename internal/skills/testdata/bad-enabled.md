---
description: Gives the enable toggle a value that is not a YAML bool.
persona: secretary
enabled: maybe
---

# Bad enabled

Body. `maybe` is a string, and yaml.v3 refuses to unmarshal a string into the
`*bool` field — so this is a rejected file on both sides, not a skill that
quietly defaults to enabled.

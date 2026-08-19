---
description: Switched off with YAML 1.1's `no` rather than `false`.
persona: assistant
enabled: no
---

# Enabled no

Body. `no` is one of the words yaml.v3 accepts for a typed bool, so this file
is listable and disabled — a parser that only understands the literal `false`
would list it as enabled.

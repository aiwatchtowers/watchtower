---
description: "never closed
persona: secretary
---

# Unterminated quote

Body. The opening quote is never closed, which breaks the whole YAML document
on the Go side — the Swift parser must refuse it instead of treating the quote
as an ordinary character.

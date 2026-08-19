---
description: "Use when it\'s the owner's own wording that matters."
persona: assistant
---

# Escaped apostrophe

Body. `\'` is a legal escape inside a double-quoted YAML scalar even though it
needs no escaping there, so both parsers must read this description with a
plain apostrophe rather than refusing the file.

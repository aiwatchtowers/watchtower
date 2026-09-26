---
description: The first spelling of the key.
"description": The second spelling of the same key.
persona: secretary
---

# Quoted duplicate key

Body. Quoting does not make a new key: yaml.v3 unquotes first and then refuses
the duplicate, so a parser comparing raw line text would list this file with
one of the two descriptions picked at random.

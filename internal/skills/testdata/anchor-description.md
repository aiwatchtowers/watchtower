---
description: &a hey
persona: secretary
---

# Anchor description

Body. The ONE fixture the two parsers deliberately disagree on. `&a` is a YAML
anchor, so yaml.v3 hands Go the description `hey` — a listing whose text is not
what the line says. The Swift parser refuses the file instead of guessing, which
is the safe direction: a skill that is not advertised, rather than one
advertised under text the file does not contain.

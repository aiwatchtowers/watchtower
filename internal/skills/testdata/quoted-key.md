---
"description": Written with a quoted key, which yaml.v3 unquotes.
'persona': secretary
"x-watchtower-shipped": v1
---

# Quoted key

Body. A listable file, not a rejected one: yaml.v3 unquotes a key before
matching it to a field, so all three keys here land exactly where their plain
spellings would — including the shipped marker.

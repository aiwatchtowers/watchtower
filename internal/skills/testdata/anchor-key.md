---
&a note: anchored
description: Carries an anchor on one of its keys.
persona: secretary
---

# Anchor key

Body. The second fixture the two parsers deliberately disagree on, and the key
half of `anchor-description`: `&a` anchors the key, so yaml.v3 reads the key as
`note` and lists the file. The Swift parser refuses an anchored key for the
same reason it refuses an anchored value — the bytes on the line are not the
key yaml.v3 reports — and skipping is the safe direction.

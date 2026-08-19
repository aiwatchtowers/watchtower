---
!t note: tagged
description: Carries a tag on one of its keys.
persona: secretary
---

# Tagged key

Body. The tag sibling of `anchor-key`, and the third fixture the two parsers
deliberately disagree on: `!t` tags the key, so yaml.v3 reads the key as `note`
and lists the file. The Swift parser refuses a tagged key for the same reason it
refuses an anchored one — the bytes on the line are not the key yaml.v3 reports
— and skipping is the safe direction.

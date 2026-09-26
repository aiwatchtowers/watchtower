---
	description: Indented with a tab, which yaml.v3 cannot scan.
persona: secretary
---

# Tab indent

Body. A tab in the indentation is a hard scanner error on the Go side, so this
file is skipped by both parsers.

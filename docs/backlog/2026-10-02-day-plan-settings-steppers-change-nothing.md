---
type: bug
title: "Day Plan Settings steppers (max timeblocks, backlog min/max) change nothing"
status: open
priority: low
tags: [day-plan, config, desktop, settings, dead-knob]
context: split out of the 2026-09-26 architecture low-priority bundle (config keys with no reader)
created: 2026-10-02
---

Settings → Features → Day Plan shows "Max timeblocks", "Backlog min" and
"Backlog max" steppers (`FeaturesSettings.swift`), and `ConfigService` reads
and writes `day_plan.max_timeblocks`/`min_backlog`/`max_backlog` into
config.yaml. Go loads them into `config.DayPlanConfig`, but `internal/dayplan`
never reads them, so moving a stepper saves cleanly and the plan ignores it.
Flagged as dead knobs by the 2026-09-13 feature audit
(`desktop-shell-gates.md`).

Owner call: either wire the three caps into the day-plan prompt/validation,
or retire them. Retiring means removing the steppers and the `ConfigService`
fields (plus `ConfigServiceTests` and `docs/app-guide.md`), dropping the Go
fields and defaults, and adding the keys to `retiredConfigKeys` in
`cmd/config.go`. They were left out of the Go-only retirement pass on
purpose, so the CLI and the app do not disagree.

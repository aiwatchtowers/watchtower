---
type: chore
title: "Swift tests run against a hand-maintained schema copy with no drift guard"
status: open
priority: med
tags: [swift, tests, schema, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift (1,073 lines), internal/db/schema.sql
**Confidence:** high

Swift query tests build their DB from a hand-written copy of the schema: 65 `CREATE TABLE` statements against 92 in `schema.sql`, and 53 `CHECK` clauses against 61. Neither the Go nor the Swift side checks the two against each other (nothing under `internal/`, `cmd/`, `scripts/` or CI references the file). The tables that were sampled are in sync today (targets, ideas, inbox_items, slack_accounts), but `workspace` has 9 columns in the copy against 20 in production, and any CHECK or column change must be hand-copied. With about 37 Swift-written tables (previous finding), a Swift writer can pass its tests against a schema that production would reject. Direction: generate the Swift test schema from `schema.sql`. Either copy it as a test resource at build time, or have a Go test emit the Swift file and fail when it differs (the `TestSchemaGolden -update` pattern). As a cheaper first step, add a Go test that parses the Swift file's table/column sets and compares them to `schema.sql`.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

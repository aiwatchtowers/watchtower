---
type: bug
title: "list_messages / list_digests / get_person cannot filter by id since Slack ids were namespaced"
status: open
priority: high
tags: [tools, mcp, multi-account, slack-ids, silent-empty, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/tools/messages.go:93-108, internal/tools/messages.go:112-126, internal/tools/messages.go:132-142, internal/tools/digests.go:16, internal/tools/digests.go:83-85, internal/tools/people_read.go:27, internal/tools/people_read.go:77-84
**Confidence:** high

Since migration 00048 `messages.user_id`, `messages.channel_id`, `channels.id`, `users.id`, `digests.channel_id` and `people_cards.user_id` all hold `"<acct>:<raw>"`. The read tools still assume bare ids. `resolvePerson` takes a value shaped like `<raw-user-id>` verbatim (`looksLikeUserID`) and filters `m.user_id IN ('<raw-user-id>')`, so it matches nothing and returns an empty list with no error. The model reads that as "this person said nothing". A namespaced id (`1:<raw-user-id>`, the shape `find_experts` returns in `user_id`) fails `looksLikeUserID` (it starts with `1`), falls through to the name `LIKE` and comes back "no person matches". `resolveChannel` has the same problem: a bare `C…` misses `GetChannelByID`, then misses `GetChannelByName`, and a namespaced id never takes the id branch at all. `list_digests.channel` is passed straight to `digests.channel_id =` (silently empty unless the model guesses the namespaced form). `get_person` advertises "Slack user id (U…)", but a raw id never matches `people_cards.user_id`. The fixtures in `messages_test.go` seed bare `U001`/`C1`, which hides all of this. Fix: add one resolver that accepts a raw or namespaced id (`slack.SplitAccountID`/`Namespace`, the `resolveText` `id = ? OR id LIKE '%:' || ?` pattern), use it for person, channel and people-card lookups, and re-seed the tests with namespaced ids.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

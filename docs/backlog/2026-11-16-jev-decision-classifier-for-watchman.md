---
type: idea
title: JEV decision classifier for Watchman as a premium tier
status: open
priority: low
tags: [watchman, premium, classifier, privacy]
context: brainstorming the Watchman spec (docs/superpowers/specs/2026-11-16-watchman-design.md, board #1823)
created: 2026-11-16
---

Add JEV to Watchman as a paid premium tier. JEV is one shared account for all
customers, and its only job is decisions: it classifies the twin's decision
(category, confidence, importance, or the choice itself). No sensitive content
reaches it: no code, no ask texts, no workbench data. It only sees features
that cannot identify the customer. Customers get it as a premium subscription
tier.

Not for now. First measure how much it improves the twin's quality: run
Watchman's phase-1 backtest with and without JEV and compare per category.
Open points:
- What exactly JEV is (to confirm with the owner).
- Which de-identified features a decision can be classified from.
- How "nothing sensitive leaves" is enforced in Go and not left to a prompt.

> Original note: «слых что я подумал. Есть еще тема. Можно сюда вкинуть JEV? Идея чтоб ему ничего пиздатого не уходило, но он мог классифицировать. Для JEV один акк на всех. Люди покупают это как премиум тир подписки. Он тока решениями занимается. Наверное не сразу но такое надо в беклог чтоб проверить на сколько это модет улучшить качество дозорного»

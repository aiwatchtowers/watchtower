# Managed by your organization

When your company manages your Mac, it can decide a few Watchtower settings for you. Those controls show a lock and **Managed by your organization**, and you cannot change them.

## What the lock means

Your company's configuration profile sets the value, and the app follows it until the profile changes. Your own setting is not lost: it is kept as you left it and comes back when the company removes the rule.

## What your company can decide

- Which sources you can connect (Slack, Google, mail, calendars, Jira, Linear).
- Whether the iPhone syncs, syncs only the Workbench, or does not sync.
- Which Quick Connections the chat and automations may use.
- Whether automations may run shell commands.
- Which AI provider Watchtower uses (and so which coding agent a workbench session can start), and whether the chat may use claude.ai tools.
- Whether a revoked account's data is deleted.

## What happens to your data

Nothing is deleted because of a rule. A source your company does not allow shows **Blocked by your organization**: it stops syncing, and what was already synced stays. An automation that needs something not allowed shows **Blocked by your organization's policy** and does not run that step. If the iPhone is turned off by the rule, the phone's copy is removed and you pair it again once sync is allowed.

## Where to see the rules
<!-- learn
id: managed-see-rules
title: See your company's rules
text: A locked control follows your company's profile; **Settings → System → Privacy** lists every rule in plain words.
area: setup
level: power
kind: feature
since: 0.25.0
-->

Open **Settings → System → Privacy**. The **Organization policy** section lists every rule in plain words, and any problem with the profile. The command `watchtower policy show` prints the same list.

## Related

- [Privacy](privacy.md)
- [Organization policy for admins](../reference/organization-policy.md)

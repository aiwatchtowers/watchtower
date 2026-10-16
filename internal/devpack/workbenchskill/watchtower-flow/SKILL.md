---
name: watchtower-flow
description: Use in a folder bound to a Watchtower workbench (the watchtower-workbench MCP server is connected) whenever a feature is agreed, a spec or plan is written or revised, a plan is executed task by task, or a group of targets is worked. Watchtower's default methodology, on top of the watchtower-workbench skill.
x-watchtower-pack: v10
---

# Watchtower Flow

This is the workbench's methodology preset: how features, specs and plans land on the board, how a group and a plan are worked, what `in_review` means and what goes into comments. It builds on the `watchtower-workbench` skill — its tools, asks, finishing a session, the board-and-git rules and its Rules always apply. When the session brief carries a `Folder rules:` block, those rules are the owner's for this folder and win over this skill where the two disagree.

## Features, specs and plans

- **A feature is agreed** with the owner → `create_targets` with one target for it: text = the feature's name, intent = one or two sentences on what done means. If a target on the board already covers it, use that one instead.
- **Group related targets — before every `create_targets`.** Read the board (`workbench_board`) and look for targets on the same topic as the new one: the same feature, screen, component or kind of fix. If they already sit under a common group target, create the new one under that group (`parent_id`). If they are loose at the top level, first create a group target for them (text = the shared topic, intent = what the group covers), move the related targets under it (`update_target` with `parent_id`), then create the new one under it too. Only a target with no topical neighbour goes to the top level. Do not regroup targets the owner placed on purpose; if a grouping is unclear, ask the owner (`ask_owner`, `kind: question`) instead of guessing.
- **A spec, plan or design is written** → ask the owner to review it, every time, as the `watchtower-workbench` skill's "Asking the owner" says. The review happens in Watchtower — not in a chat artifact, not in the terminal, anywhere else.
- **A plan is written** → also `create_targets` in one call, one sub-target per plan task, under the feature target (`parent_id` = the feature target's id). Text = the task's title; intent = the plan path plus the task number, e.g. `docs/plans/feature-x.md — Task 3`, so any later session can find the task's steps. Nest deeper with `parent_key` only where the plan itself nests.

## Working a group

The first prompt `Work on group #<id>` hands you a target with sub-targets.

1. Read the subtree: `workbench_board`, then `get_target` and `list_comments` on the group. The group's intent is the brief.
2. Whichever way you pick the work below, skip a leaf that is `blocked`, waits on an open ask, or was already `in_progress` or `in_review` when you started — another session is on it.
3. If the intent names a plan, run that plan as "Running a plan" says, in the order its dependencies allow.
4. Otherwise take the open leaves in board order — priority, then status, then id. Leaves that do not depend on each other may run in parallel only where the folder's own rules allow parallel work.
5. Set each leaf `in_progress` with its `branch` in one `update_target` when you start it. Set the leaves' statuses, never the group's: it follows its children.
6. When the group's work is done or handed to the owner, call `finish_session` once with `target_id` = the group and a summary of the whole group.

## Running a plan (subagent-driven development)

When you are the controller executing a plan whose tasks are on the board:

- **Before dispatching a task:** `update_target` its sub-target to `in_progress`, then `list_comments` with its `target_id`. Put every owner comment verbatim into the implementer's brief, marked as the owner's words.
- **When the task's review starts:** `update_target` it to `in_review` — the review is run by reviewer agents, not the owner; the owner's board shows what is being reviewed, and every status change is recorded with its time (`get_target`'s `status_history`).
- **After the task's review passes:** `update_target` to `done` (status alone moves a leaf target's progress to 1.0), then one `add_comment` on the sub-target: a summary of one to three lines — what landed, the commit, anything the owner should know.
- A task the review sends back goes back to `in_progress`; post no interim comments.
- Never set the feature target's status yourself: it moves to `in_progress` with its first started sub-target and to `done` when every sub-target is done or dismissed (at least one done).

## Comment discipline

Comments are what the owner gets notified about. Post only two kinds:

- a **blocker** — something outside the owner's answer that stops the work,
- a **done summary**.

Questions and decisions are asks, not comments. No progress chatter, no "starting now", no restating the plan. One comment per event.

## What `in_review` means

`in_review` means agents are reviewing the work — a code review, a document review by reviewer agents. It never means waiting for the owner: work that waits for the owner has an open ask, and is `blocked` only when nothing on it can proceed.

---
name: backlog-capture
description: Use when the owner drops a rough thought, idea, bug, or chore to save for later while working on something else — triggers like «в бэклог», «закинь находку», «запиши в беклог», «backlog this», "capture this finding". Captures it as a finding file committed and pushed to origin/main, never onto the current feature branch.
---

# Backlog Capture (Watchtower)

Turn a raw, half-formed thought (usually Russian, dropped mid-task) into one clean **English finding file** that lands on `main` and is pushed to `origin/main` — so it survives the feature branch/worktree it was thought up in.

The owner dumps; you shape. You classify the finding, write it in English, pull context from the current session, and commit it to `main` — WITHOUT touching the current feature branch and WITHOUT grabbing the shared main checkout.

## The load-bearing rule

**The finding goes to `origin/main` through a DEDICATED detached worktree — never the main checkout, never the current feature branch.**

Why not the main checkout: another session may be working there right now. A finding capture must never switch its branch or touch its working tree. Why not the current branch: feature branches get deleted; the finding would die with them.

`main` is already checked out in the main repo, and git allows a branch in only one worktree at a time — so the dedicated worktree runs in **detached HEAD on `origin/main`**, not on the `main` branch itself. The push (`HEAD:main`) advances `origin/main`; the local `main` in the main checkout catches up on its next `git pull`.

## Steps

### 1. Shape the finding (no git yet)

From the raw thought + current session, produce:

- `type` — one of `idea` / `bug` / `chore` / `question`.
- `title` — a short English one-liner (this becomes the slug).
- `body` — the finding in clear English prose.
- `context` — where it surfaced: branch / file / task you were on when it came up.
- `priority` — `low` / `med` / `high` (rough).
- `tags` — a few free-form keywords.

Keep the owner's original words: quote the raw thought verbatim at the end so nothing is lost in translation.

**File format** (`docs/backlog/YYYY-MM-DD-<slug>.md`, slug = kebab-case ASCII of the title):

```markdown
---
type: bug
title: Inbox retry does not fire on an empty channel
status: open
priority: med
tags: [inbox, retry]
context: feature/persona-skills — noticed while reading internal/inbox/pipeline.go
created: 2026-09-09
---

Inbox retry never fires when the channel has no messages: the retry guard
short-circuits on an empty message set instead of re-arming. Worth checking.

> Original note: «блин, ретрай в инбоксе не срабатывает когда канал пустой — надо проверить»
```

`status` is always `open` at capture time.

### 2. Ensure the dedicated worktree exists

The worktree lives OUTSIDE `.claude/worktrees/` (which gets pruned) — a sibling of the main repo:

```bash
MAIN=$(git worktree list --porcelain | grep -m1 '^worktree ' | cut -d' ' -f2)
BACKLOG_WT="$(dirname "$MAIN")/watchtower-backlog"

git fetch origin main
if ! git worktree list --porcelain | grep -qx "worktree $BACKLOG_WT"; then
  git worktree add --detach "$BACKLOG_WT" origin/main
fi
```

`--detach` is what sidesteps "branch 'main' is already checked out".

### 3. Write, commit, push

```bash
cd "$BACKLOG_WT"
git fetch origin main
git checkout --detach origin/main          # refresh HEAD onto the latest origin/main

# write docs/backlog/YYYY-MM-DD-<slug>.md here (create docs/backlog/ if absent)

git add docs/backlog/YYYY-MM-DD-<slug>.md  # ONLY this file — never `git add -A`
git commit -m "backlog: <title>"
git push origin HEAD:main
```

### 4. Handle a rejected push (race)

Another commit landed on `origin/main` between your fetch and push:

```bash
git fetch origin main
git rebase origin/main       # the finding is one new file — no conflicts in practice
git push origin HEAD:main
```

### 5. Report

One line to the owner: type + title + the finding file path + confirmation that `origin/main` advanced. Do not switch back or touch the feature worktree — you never left it (the git work happened in `$BACKLOG_WT`).

## Gotchas

- **Never `git -C main-checkout ...` or `cd` into the main checkout.** That is the trap the naive path falls into — it works only when the main checkout happens to be free, and it usually is not. Always the dedicated detached worktree.
- **Never `git add -A` / `git add .`** — the backlog worktree should only ever stage the one finding file. A wide add in a shared worktree is a project-wide banned pattern.
- **`git push` 403?** Push must run under the `vadimtrunov` GitHub account (the `vadym-trunov_wbt` account 403s on this repo). This is a machine-auth issue, not a skill bug — surface it to the owner.
- **Detached HEAD is expected**, not an error. Do not "fix" it by checking out the `main` branch — that would collide with the main checkout.
- **English only in the file.** Repo content (docs, comments, commits) is English by house convention; the Russian original is preserved only inside the quote block.

## Scope (v1)

Capture only. No listing, triage, dedup, or status transitions here; no sync to the Ideas Registry or Jira. Those are separate skills if they ever earn their place.

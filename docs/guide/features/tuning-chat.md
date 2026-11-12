# Tuning chat

The tuning chat sits beside a workbench's **Analytics** and talks about your LLM setup with the numbers in front of it: Watchtower's prompts, your Claude Code and Codex skills, instruction files and allow rules. It is for the person who wants to know why something costs or fails and get the edit that fixes it. Nothing changes until you press **Accept** on the edit it proposes.

## Why use it
<!-- learn
id: tuning-chat-open
title: Tune your prompts and skills in a chat
text: Press **Tune** in a workbench's Analytics to ask why something costs or fails and get an edit you accept.
area: development
level: power
kind: feature
since: next
action: nav:projects
-->

The Analytics numbers tell you that cost per task grew or that a skill never runs, but not what to change. The tuning chat reads the report, the sessions and the files behind them, and answers with one concrete edit. You keep it only if it works: an accepted edit gets the [agent coach](agent-coach.md)'s 14-day verdict and can be rolled back.

## How it works

The chat reads, it never writes. With Claude or Codex as your AI provider it can read this workbench's agent report and sessions (Claude Code and Codex), Watchtower's own AI spending, Watchtower's prompts, your skills (Claude Code, Codex and the Watchtower skills), your instruction files and allow rules, and the coach's open and past proposals. It reads no Slack, mail, Jira, Linear or meeting text.

When it suggests a change, it files a proposal: the coach's card appears in the chat and in the pane's **Proposed edits**. A proposal edits one place:

- extra lines for a Watchtower prompt, or for a Watchtower skill (added under **Owner additions (approved by the owner)**, so skill updates still reach you);
- one of your skills in `~/.claude/skills` or, for Codex, `~/.agents/skills` or `~/.codex/skills`. The skill must already exist;
- `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, your instructions and target procedure, or the allow rules of Claude Code or Codex (`~/.codex/rules/default.rules`, read-only commands and tests only);
- a file in the workbench folder itself (next section).

Chat proposals do not count toward the weekly pass's three open suggestions, and one text has only one open proposal at a time.

### Edits to the workbench folder's own files

The chat can also edit five files in the workbench's own folder, never in a session's worktree: `CLAUDE.md`, `AGENTS.md`, `.claude/skills/<name>/SKILL.md`, `.agents/skills/<name>/SKILL.md` and `.watchtower/workflow.md`. Only `CLAUDE.md` and `AGENTS.md` may be created; the others must exist.

**Accept** writes the file and nothing else: Watchtower runs no git command that changes anything, so you review the change and commit it yourself. The card names the branch the edit lands on. The 14-day verdict starts once the commit is seen, because new sessions start from the folder's last commit.

## Using it

1. Open a workbench's **Analytics** (analytics must be on) and press **Tune** in the header. The panel opens on the right; drag its edge to resize it, and press **Esc** or **Tune** again to close it.
2. Pick a starter, such as **Why did cost per task grow?** or **Which prompt costs the most?**, or type your question. The line above them shows the period's sessions, tasks and cost; the chat reads the period the pane shows.
3. Quiet lines such as **Read the 7-day report** show what it looked at.
4. On a proposal card, **Accept** applies it, **Edit…** lets you change the text first (not for Claude Code allow rules), and **Decline** closes it for good. An accepted card folds to **Accepted · measuring for 14 days** with **Show in Accepted edits**, where **Roll Back** lives.
5. **New** starts another tuning chat; the title menu switches between this workbench's recent ones. Tuning chats are not listed in **Chats**.

For a workbench file the folded line reads **Accepted · wrote CLAUDE.md on main — commit it yourself** until you commit, then **Accepted · committed · measuring for 14 days**. Rolling one back restores the file, and you commit that too.

## When it's empty or wrong

- **Tuning tools need Claude or Codex — pick one in Settings → System → AI.** Your AI provider is neither Claude nor Codex. The chat still talks but cannot read the report or propose an edit; **Open Settings** takes you there.
- **No Tune button.** Analytics is off for this workbench; turn it on first.
- **"… has uncommitted changes — commit or discard them, then press Accept again."** The file has changes git has not committed, maybe from a running session. Commit or discard them, then press **Accept** again.
- **This workbench folder is not a git repository: …** Workbench files are edited only where you can review and commit the change, so the chat cannot propose them for this folder.
- **The text changed since — this proposal is closed**. The file or text changed after the proposal was made; ask again.
- **"Codex sees this skill in two folders …"** The skill is in both `~/.agents/skills` and `~/.codex/skills`. Remove one copy.
- **It gives the text instead of a proposal.** New skills and a new `.watchtower/workflow.md` are not created; save the text yourself.
- **Accepted · waiting for your commit** in **Accepted edits**. Commit the file; after 30 days without a commit the row reads **Not committed in 30 days — not measured**.

## Related

- [Agent analytics](agent-analytics.md)
- [Agent coach](agent-coach.md)
- [Methodology](workbench/methodology.md)

For developers: [docs/features/tuning-chat.md](../../features/tuning-chat.md)

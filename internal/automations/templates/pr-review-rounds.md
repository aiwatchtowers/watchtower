---
name: PR review rounds
trigger:
  schedule: "0 10,16 * * 1-5"
permissions:
  - 'shell:"gh pr list --state open --limit 200 --json number,title,url,author,updatedAt"'
  - session:start
  - llm:light
outputs: [report]
---
Twice a day on weekdays (10:00 and 16:00), lists the open pull requests of
this folder's repository with `gh` and opens one review session for each pull
request updated since the last round. The first round reviews every open pull
request. A round starts at most 10 sessions (the limit per run); the pull
requests left over are reviewed in the next round.

Each session reviews its pull request and files every finding as an ask in
**Waiting for you**. It posts on the pull request only the comments you
approve in your answers, and only after you answered, from its own terminal
with `gh pr review` / `gh pr comment`. It then finishes with a summary.

The report lists the pull requests of the round and how each session ended.
Needs the GitHub CLI (`gh`) signed in for this repository.

```js
const roundStart = new Date().toISOString();
const list = shell("gh pr list --state open --limit 200 --json number,title,url,author,updatedAt");
// A dry run starts no process: shell() returns {status: "dry_run"}.
const dryRun = list.status === "dry_run";
if (!dryRun && list.exit_code !== 0) {
  throw new Error("gh pr list exited " + list.exit_code + ": " + list.stderr.slice(-2000));
}

// last_round: when the last round that left no pull request for the next
// one started. reviewed: pull request number -> when its review session
// ended, kept until a later round's start passes it, so a review's own
// comments never bring the pull request back.
const MAX_SESSIONS = 10; // session() starts at most 10 sessions per run
const since = state.get("last_round");
const reviewed = state.get("reviewed") || {};
const prs = dryRun ? [] : JSON.parse(list.stdout);
const changed = prs
  .filter((pr) => {
    const mark = reviewed[pr.number] || since;
    return !mark || Date.parse(pr.updatedAt) > Date.parse(mark);
  })
  .sort((a, b) => a.number - b.number);

function reviewPrompt(pr) {
  return [
    "Review pull request #" + pr.number + " (" + pr.url + ") of this repository.",
    "",
    "1. Read it with `gh pr view " + pr.number + "` and `gh pr diff " + pr.number + "`. Change no code and push nothing.",
    "2. File every finding as its own ask_owner ask (kind question): the file and line, what is wrong, and the exact comment you would post, with the options \"Post it\" and \"Drop it\". Post nothing yet.",
    "3. Wait for the owner's answers. Only after the answers, post on the pull request exactly the comments the owner approved, as the owner worded them in the answer, from this terminal with `gh pr review " + pr.number + "` or `gh pr comment " + pr.number + "`. Post nothing the owner dropped or did not answer.",
    "4. Call finish_session with a short summary: findings filed, comments posted, comments dropped.",
  ].join("\n");
}

const lines = [];
let started = 0;
let left = 0;
for (const pr of changed) {
  if (started >= MAX_SESSIONS) {
    left++;
    continue;
  }
  let s;
  try {
    s = session({ prompt: reviewPrompt(pr), title: "PR #" + pr.number + " review" });
    started++;
  } catch (e) {
    s = { status: "not started", summary: e.message };
  }
  if (s.status === "not started" || s.status === "error") {
    left++; // tried again next round
  } else {
    reviewed[pr.number] = new Date().toISOString();
  }
  let line = "- #" + pr.number + " " + pr.title + " (" + pr.url + "): " + s.status;
  if (s.summary) line += " — " + s.summary;
  if (s.error) line += " — " + s.error;
  lines.push(line);
}
if (left > 0) {
  // last_round stays, so the next round still sees the rest.
  lines.push("- " + left + " pull request" + (left === 1 ? "" : "s") + " left for the next round.");
} else {
  state.set("last_round", roundStart);
}
// Keep the marks of open pull requests that are newer than last_round; the
// others say nothing last_round does not.
const mark = left > 0 ? since : roundStart;
const kept = {};
for (const pr of prs) {
  const at = reviewed[pr.number];
  if (at && (!mark || Date.parse(at) > Date.parse(mark))) kept[pr.number] = at;
}
state.set("reviewed", kept);
output.report({
  title: "PR review round: " + started + " pull request" + (started === 1 ? "" : "s"),
  body: lines.length ? lines.join("\n") : "No open pull request changed since the last round.",
});
return started + " reviewed";
```

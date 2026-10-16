---
name: PR review rounds
trigger:
  schedule: "0 10,16 * * 1-5"
permissions:
  - 'shell:"gh pr list --state open --json number,title,url,author,updatedAt"'
  - session:start
  - llm:light
outputs: [report]
---
Twice a day on weekdays (10:00 and 16:00), lists the open pull requests of
this folder's repository with `gh` and opens one review session for each pull
request updated since the last round. The first round reviews every open pull
request.

Each session reviews its pull request and files every finding as an ask in
**Waiting for you**. It posts on the pull request only the comments you
approve in your answers, and only after you answered, from its own terminal
with `gh pr review` / `gh pr comment`. It then finishes with a summary.

The report lists the pull requests of the round and how each session ended.
Needs the GitHub CLI (`gh`) signed in for this repository.

```js
const list = shell("gh pr list --state open --json number,title,url,author,updatedAt");
// A dry run starts no process: shell() returns {status: "dry_run"}.
const dryRun = list.status === "dry_run";
if (!dryRun && list.exit_code !== 0) {
  throw new Error("gh pr list exited " + list.exit_code + ": " + list.stderr.slice(-2000));
}

const since = state.get("last_round");
const prs = dryRun ? [] : JSON.parse(list.stdout);
const changed = prs
  .filter((pr) => !since || Date.parse(pr.updatedAt) > Date.parse(since))
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
for (const pr of changed) {
  let s;
  try {
    s = session({ prompt: reviewPrompt(pr), title: "PR #" + pr.number + " review" });
  } catch (e) {
    s = { status: "not started", summary: e.message };
  }
  let line = "- #" + pr.number + " " + pr.title + " (" + pr.url + "): " + s.status;
  if (s.summary) line += " — " + s.summary;
  if (s.error) line += " — " + s.error;
  lines.push(line);
}

state.set("last_round", new Date().toISOString());
output.report({
  title: "PR review round: " + changed.length + " pull request" + (changed.length === 1 ? "" : "s"),
  body: lines.length ? lines.join("\n") : "No open pull request changed since the last round.",
});
return changed.length + " reviewed";
```

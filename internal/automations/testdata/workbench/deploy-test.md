---
name: Deploy to test
trigger:
  button: {label: "Deploy to test", confirm: true}
permissions:
  - 'shell:"make deploy-test"'
  - session:start
outputs: [report]
---
Runs `make deploy-test` in this workbench folder when you press **Deploy to
test** in the workbench header and confirm. `make deploy-test` is a
placeholder: change it to your own command, here in the permission and in
the script — the two must match exactly.

When the command fails, the run fails and shows the end of its output. When
it succeeds, a session checks that the test environment is healthy, and the
report holds the end of the command's output and the session's summary.

```js
const cmd = "make deploy-test";
const r = shell(cmd);
const tail = (text) => (text || "").slice(-4000);

// A dry run starts no process: shell() returns {status: "dry_run"}.
if (r.status !== "dry_run" && r.exit_code !== 0) {
  const out = tail(r.stderr) || tail(r.stdout);
  output.report({
    title: "Deploy to test failed",
    body: "`" + cmd + "` exited " + r.exit_code + ".\n\n```\n" + out + "\n```",
  });
  throw new Error(cmd + " exited " + r.exit_code + ":\n" + out);
}

const check = session({
  prompt: "`" + cmd + "` just finished in this folder. Check that the test environment is healthy: " +
    "find out from this repository (its Makefile, scripts and docs) where it runs and how to check it, " +
    "then check it from this terminal. Change nothing and deploy nothing. " +
    "If something is wrong, say what and how you found it. " +
    "Then call finish_session with a short summary: healthy or not, and why.",
  title: "Deploy to test check",
  wait: "finish",
});

output.report({
  title: "Deploy to test: " + check.status,
  body: "`" + cmd + "` succeeded.\n\n```\n" + tail(r.stdout) + "\n```\n\n" +
    "Check (" + check.status + "): " + (check.summary || check.error || "no summary"),
});
return check.status;
```

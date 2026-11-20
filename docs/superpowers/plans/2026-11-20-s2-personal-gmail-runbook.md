# S2 runbook — does an own Google project's Gmail token outlive 7 days?

Spike S2 of the company-setup plan (`2026-11-18-company-setup.md`, Task 1; spec `2026-11-17-company-setup-design.md` §4 "Unverified so far"). Question: a Google Cloud project **published to production without verification** — does its owner's `gmail.readonly` refresh token still refresh after 7 days? The answer decides whether personal Gmail on an own project ships with a weekly Re-login (Task 18 flag, Task 26 frame).

Decided for 0.29.0 (asks #1645, #1649): the release does not wait; S2 starts on release day and its result lands in 0.29.1 if needed.

## What you need

- A throwaway Google account made for this test (`<throwaway-gmail>`), not anyone's real mailbox — the project is deleted afterwards.
- A Mac with Watchtower installed. Step 6's browser sign-in must happen **on that same Mac** (the OAuth callback goes to a loopback port of the machine running the CLI), and day 8 runs there too.
- The Cloud Console steps (1–5) can be done from any computer.

## Day 1 — set up (≈15 min)

Signed in to the console as `<throwaway-gmail>`:

1. https://console.cloud.google.com/projectcreate — create a project, e.g. `wt-s2-spike`.
2. https://console.cloud.google.com/apis/library/gmail.googleapis.com — with that project selected at the top, **Enable**.
3. https://console.cloud.google.com/auth/overview — **Get started**: app name `wt-s2-spike`, user support email = the throwaway account, Audience **External**, contact email = the throwaway account, accept, **Create**.
4. **Audience** (left menu):
   - **Test users → Add users** → the throwaway account.
   - **Publish app → Confirm** — status must read **In production**. In *Testing* a refresh token dies after 7 days by design, which would make the spike meaningless.
5. **Clients → Create client** → type **Desktop app** → **Create**. Copy the client id and secret (the secret never goes into a file or chat; it is typed into stdin in step 6).

On the Mac with Watchtower, in an isolated home so the live database is never touched (repo rule: no dev CLI on the live DB):

6. ```sh
   WT="$HOME/Library/Application Support/Watchtower/bin/watchtower"
   mkdir -p ~/wt-s2-spike
   HOME=~/wt-s2-spike "$WT" workspace init --name s2
   HOME=~/wt-s2-spike "$WT" google add --client-id <client-id> --client-secret-stdin --gmail
   ```
   Paste the secret, Enter, Ctrl-D. The browser opens: sign in as the throwaway account; on "Google hasn't verified this app" choose **Advanced → Go to wt-s2-spike (unsafe)** and allow.
7. Record the sign-in date and time (UTC) in the "Result" section below.

(`$WT` is expanded by the outer shell before `HOME` is overridden, so the installed binary is found while its data goes to `~/wt-s2-spike`.)

## Day 8 or later — the check

On the same Mac:

```sh
WT="$HOME/Library/Application Support/Watchtower/bin/watchtower"
HOME=~/wt-s2-spike "$WT" gmail sync
```

- Sync runs (no auth error) → **Outcome A**: the token outlives 7 days. Task 18 ships `ownProjectWeeklyRelogin = false`; the weekly frame is not wired.
- `invalid_grant` → **Outcome B**: Task 18 sets the flag and stamps `relogin_due_at = issued + 7d`; Task 26 wires the weekly frame and "Re-login due in <n> days" from day 5; the guide says so (Task 30).

Record only the outcome and the error key — never tokens, ids or the account address.

## Clean up

- `rm -rf ~/wt-s2-spike` on the Mac.
- Delete the Cloud project (console → IAM & Admin → Settings → Shut down).

## Result

| Field | Value |
|---|---|
| Signed in (UTC) | _pending_ |
| Checked (UTC) | _pending_ |
| Outcome | _pending_ (A: refresh works / B: `invalid_grant`) |

# Connect with an agent

**Connect with Claude** (or **Connect with Codex**) lets your own Claude or Codex set up a connection for you: Slack, Google, mail, a calendar, Jira, Confluence, Linear, a Quick Connection, or your company's apps. It is for anyone who would rather talk than read setup screens. Today's forms stay where they were; this is a second way in.

## Why use it

Some setups are long: your company's Slack app, a Google Cloud project, an Atlassian developer app. The assistant knows each vendor's pages and walks through them with you, or clicks through them itself.

Say you want Slack. You press **Connect with Claude** on the Slack card, press **Start**, and the assistant opens Slack's pages, tells you when to sign in and press **Allow**, and checks that the workspace arrived. You never read a word about tokens or apps.

## How it works
<!-- learn
id: connect-agent-start
title: Let Claude or Codex connect a source
text: Press **Connect with Claude** on a Connections card and the assistant sets the source up with you, step by step.
area: setup
level: basics
kind: feature
since: next
action: nav:connections
-->

**It presses Watchtower's own buttons.** The assistant starts the same sign-ins the forms start, so nothing new is stored and one connect runs at a time. It follows a written playbook per connector; you can read each one under [Connect with an agent](../README.md#connect-with-an-agent) in this guide.

**You do the parts that are yours.** Passwords, two-step codes and the final **Allow** on a vendor's page are always your clicks. So is any click that shows a secret, such as Slack's **Generate Token** or Google's **Create** on a client form.

**What you paste never reaches the assistant.** When a step needs a token, password, API key or client secret, the panel shows a card. You paste the value there and press **Send**; it goes straight to Watchtower and the assistant only hears whether it worked. In browser mode the assistant could read a vendor page that shows a secret while it is open, so close that page or dialog before you press **Send**; the card reminds you.

**The card shows where the value goes.** When the place comes from the assistant (your mail server, a calendar address, a Quick Connection), the card names it, for example "Sends it to imap.example.com:993 (ssl) as you@example.com". Check it before you press **Send**: while the card is open the assistant can't change it.

**Some steps need your confirm.** Steps that can't be undone or that add trust show a card only you can press: turning on PKCE for a Slack app, updating your company's Slack app, using your own Google project, turning on a Quick Connection, publishing or replacing your company's setup. The card shows exactly what it applies to, such as the command or address a Quick Connection runs, the Client ID or the services you publish, and nothing runs if that changes before your press. It says "Only you can press this — Claude can't."

**Browser or words.** With Claude and the Claude in Chrome extension connected, the panel says **Using Claude in Chrome**: the assistant opens and fills the vendor's pages in your own Chrome. Otherwise it says **I'll tell you each step**: you click, it tells you what to click and checks the result. Codex always works in words today. If the extension drops out mid-setup, the assistant goes on in words.

**It stays on the vendor's pages.** The assistant may open only the sites its playbook names, and page text is never an instruction to it. A link, a form or a redirect to another site can't be blocked, so the assistant is told to leave such a page and stop.

**Who gets the button.** The button appears when Claude or Codex is installed on your Mac and your organization allows that provider and that source. Ollama does not get it. A source your organization blocks shows its lock and no agent button.

## Using it

1. Open **Connections**. A card with no account shows **Connect with Claude** next to **Connect**. You also find it in a source's add-account row, in the **Connect…** menu, beside **Set up for my company**, on the **Use my own Google project** page, and on the setup Connect step.
2. The assistant opens on the right. To switch between Claude and Codex, use the menu in its header.
3. Press **Start**. In browser mode, press **Guide me in words** instead if you would rather click yourself.
4. Do what it asks: sign in, press **Allow**, paste a secret into the card and press **Send**, or press **Confirm** on a confirm card. You can type a question at any point.
5. When it says the source is connected, close the panel. Pick boards, teams or spaces as usual if it hasn't already.

**Set up by hand** opens today's screen for that connector. It shows before you press **Start** and after a failure; while the assistant works, press **Cancel** first. Closing the panel stops the assistant but not a sign-in already running: finish it in the browser, and a Slack sign-in carries on under **Connections → Slack**. Open the panel again and the assistant picks up from what is already done.

## When it's empty or wrong

**No Connect with Claude button.** Claude and Codex are not installed or not found, only Ollama is set up, or your organization blocks the source or the provider. See [The Claude or Codex tool is not found or not signed in](../troubleshooting/ai-tool-not-found-or-not-signed-in.md) and [Managed by your organization](../concepts/managed-by-your-organization.md).

**The first step fails right away.** The tool is installed but not signed in. Sign in to Claude or Codex, then press **Retry**.

**"Claude isn't installed on this Mac."** Switch the assistant in the header, or press **Set up by hand**.

**"Claude has reached its usage limit."** Retry later, switch to Codex, or set up by hand. The assistant never switches provider on its own mid-setup.

**"I stopped waiting after 15 minutes."** A step waited too long for you, so the sign-in was cancelled. Press **Retry** when you're ready.

**"Slack is already connecting in another window."** Another connect is running. Press **Open it** to finish or cancel that one first.

**It stays on Working on it… and nothing happens.** Claude may be stuck checking for your browser. Press **Cancel**, check that the Claude in Chrome extension is connected, then press **Start** again, or choose **Guide me in words**.

**An account needs attention.** The assistant doesn't reconnect existing accounts; use **Reconnect** or **Re-login** as in [An account needs attention](../troubleshooting/account-needs-attention.md).

## Related

- [Set up Watchtower](../start/setup.md)
- [Set up Watchtower for your company](../start/company-setup.md)
- [Sources and accounts](../concepts/sources-and-accounts.md)

For developers: docs/features/agent-connect.md

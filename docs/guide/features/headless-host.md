# Headless host

A headless host runs your workbenches on a Linux box or on a Mac without the Watchtower app, and you drive them from your iPhone. It is for a small always-on machine, like a Raspberry Pi on a shelf, that has no screen and no Watchtower window.

## Why use it
<!-- learn
id: headless-host-run
title: Run workbenches on a Linux box
text: On a Linux box run `watchtower service install`, then `watchtower hub pair` to drive its sessions from your phone.
area: iphone
level: power
kind: feature
since: next
-->

You start a Claude Code session on the Pi's workbench from your phone before you leave. The agent works while you are out; its asks, permission prompts and chat reach the phone, and you answer them there. Your laptop can stay shut.

## How it works
<!-- learn: none -->

The host runs the Watchtower daemon as a user service. The daemon holds the workbenches and the phone hub, and starts each session inside `watchtower session-host`, so restarting the daemon (an update) keeps every agent running.

The host talks to your phone only through the relay. It makes outbound connections only and listens on no port. Everything it sends is end-to-end encrypted, as on the Mac. There is no iCloud path, so the phone needs **Relay**: a phone without it shows **A free phone can't link this hub**. Your phone's subscription admits the host to the relay when you link it, and it takes one of your relay slots.

A headless host does less than the Mac app:

- **No recordings.** It cannot transcribe, so the phone does not offer to record for it and your audio stays on the phone.
- **No clipboard fallback.** A line the session cannot take right now fails with a message instead of going to a clipboard.
- **Only the workbenches.** Slack, Gmail, Jira and the other sources, digests and briefings are off.
- **Always away on Linux.** Work alerts always go to the phone. A Mac without the app sends them only while you are away from it.

## Using it
<!-- learn: none -->

### Set up a Linux box

You need a 64-bit Linux with glibc 2.35 or newer (Ubuntu 22.04+, Debian 12+, Raspberry Pi OS bookworm), `libssl3` and `git`. Ubuntu 20.04, Debian 11 and 32-bit systems do not work.

1. Download `watchtower-<version>-linux-arm64.tar.gz` (or `-linux-amd64`) and its `.sha256` file from the release. Run `sha256sum -c watchtower-<version>-linux-arm64.tar.gz.sha256`, unpack it and put `watchtower` on your `PATH`, for example `install -m 0755 watchtower ~/.local/bin/`.
2. Install Claude Code or Codex and sign in. With no browser on the box, `claude` prints a URL: open it on another device and finish the login there.
3. Run `watchtower service install`. It creates the workspace with only the core features on, turns the hub on, and starts `watchtower.service` as a systemd user unit.
4. If it prints **Run `sudo loginctl enable-linger <user>`…**, run that once, so Watchtower starts at boot and keeps running after you log out. Watchtower never runs `sudo` itself.
5. Only if you were told to use another relay: `watchtower config set hub.relay_origin <origin>`, then `systemctl --user restart watchtower.service`.
6. Make a workbench: `watchtower workbench create --folder ~/code/acme`, then `watchtower integrate claude-code` (or `codex`).

### Link your phone

1. In a terminal on the host, run `watchtower hub pair`. It prints a QR code, a link and when the code expires.
2. Scan the code with the Watchtower app on your iPhone, or open the link on the phone.
3. The terminal shows **"<phone>" wants to link.** and **Confirm code 1234 on your phone? [y/N]**. Check the phone shows the same four digits and type `y`.
4. **Linked "<phone>".** means you are done. Anything but `y`, or **Ctrl-C**, refuses the link.
5. To let the phone type into sessions or start them, run `watchtower hub allow <device> typing` and `watchtower hub allow <device> start_sessions`. `watchtower hub phones` lists the device ids.

`hub pair`, `hub allow`, `hub unlink` and `service install` are yours alone: a coding agent's shell is refused, and `hub pair` needs a real terminal.

### On a Mac without the app

Download `Watchtower-CLI-<version>-arm64.zip` (Apple silicon only), put `watchtower` on your `PATH` and follow the same steps. `service install` writes a LaunchAgent instead of a systemd unit. The daemon starts only when you log in: a Mac that restarts to the login window runs no hub until you log in. On a Mac that has the Watchtower app, `service install` refuses with **This Mac has the Watchtower app, which runs the daemon itself.**

### Remove it

`watchtower hub unlink <device>` unlinks a phone. `watchtower service uninstall` removes the service and keeps your data and running sessions.

## When it's empty or wrong
<!-- learn: none -->

`watchtower hub status` names the reason in parentheses, like **hub: paused (needs_relay)**.

- **`needs_relay`.** No linked phone has an active Relay subscription. The host keeps its sessions and work and publishes nothing, and the phone shows **This hub needs Relay**. It resumes within 5 minutes of a subscription coming back. Linking a phone still works.
- **`not_vouched`.** The relay has not admitted the host yet: link a phone with Relay (`watchtower hub pair`).
- **`vouch_revoked`.** The host left every relay slot. Link it again with `watchtower hub pair`.
- **`no_relay_origin`.** This build names no relay. Run the line `hub status` prints: `watchtower config set hub.relay_origin <origin>`.
- **`disabled`.** The hub is off: run `watchtower service install` again, or `watchtower hub enable`.
- **`desktop_host`.** This Mac has the Watchtower app, which runs the phone link itself. Use **Settings → Mobile** in the app.
- **`run_dir_unusable`.** The session host cannot use its socket folder (`/run/user/<uid>`, else `~/.local/share/watchtower/.run`). Check that the folder belongs to you.
- **A session fails with "the session host is not running: no systemd user manager".** The daemon cannot reach your systemd user manager. Log in through a console or SSH (not `su` or `sudo -u`), or turn on linger as above.
- **`service install` says it needs a systemd user manager.** The same cause: log in through a real session, or run `sudo loginctl enable-linger <user>`, then try again.
- **The QR code is cut off or missing.** Widen the terminal window to the width the hint names, or open the printed link on the phone.
- **This code expired or was already used.** Run `watchtower hub pair` again for a new code.

## Related

- [iPhone](iphone.md)
- [Workbench](workbench/README.md)
- [Command line](../reference/cli.md)
- [Privacy](../concepts/privacy.md#on-a-linux-host-or-a-mac-without-the-app)

For developers: [docs/features/go-hub.md](../../features/go-hub.md)

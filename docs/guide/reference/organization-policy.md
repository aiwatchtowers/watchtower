# Organization policy for admins

If you deploy Watchtower through an MDM (Jamf, Kandji, Intune and the like), you can force a few settings with a configuration profile, as you do for other apps. The person on the Mac sees each one as **Managed by your organization** and cannot change it in the app, in `config.yaml` or with `defaults write`.

## How the profile reaches Watchtower

Deploy a Custom Settings payload for the preference domain `com.watchtower.desktop`. Watchtower reads only **forced** (managed) values of that domain, so a value someone writes with `defaults write` is ignored. Without a profile nothing is restricted, whatever the build.

The app re-reads the policy at launch, when it comes to the front and every minute; the command line and the sync daemon read it at least every 30 seconds. Tightening a key never deletes data and never rewrites anyone's settings: they come back when you remove the key.

A full example with every key and placeholder values is in the repository at `docs/examples/watchtower-policy.mobileconfig`.

## The keys

| Key | Type | Effect |
|---|---|---|
| `AllowedSources` | array of `slack`, `google`, `imap`, `caldav`, `jira`, `linear` | Only these can be connected and synced. `google` covers Gmail and Google Calendar, `imap` covers Outlook, `jira` covers Confluence. An empty array allows none. A source already connected stops syncing and keeps its data. |
| `MobileSync` | `allowed`, `workbench_only` or `off` | `off` turns iPhone sync off and removes what the phone held. `workbench_only` keeps workbenches, board targets and comments, sessions with their reports and timelines, asks and ask alerts, session chat and permission prompts, and removes briefings, inbox, digests, people, calendar, transcripts, recordings, day plan and accounts from the phone. |
| `AllowedQuickConnections` | array of `https://` URL prefixes or absolute command paths | A Quick Connection that matches none is never started, added, enabled or called. An empty array allows none. |
| `AllowAutomationShell` | boolean | `false` refuses automation recipes that run shell commands. |
| `AllowedAIProviders` | array of `claude`, `codex`, `ollama` | The only providers any part of Watchtower may use. A configured provider outside the list fails each AI call with the policy error; it never switches to another provider by itself. |
| `AllowClaudeAITools` | boolean | `false` turns off claude.ai publishing and connectors in the chat. |
| `PurgeRevokedData` | boolean | Forces [deleting a revoked account's data](../concepts/revoked-access.md) on or off. |

A key with the wrong type counts as its most restrictive value (for example an integer `1` where a boolean belongs counts as `false`), and the problem is listed in the policy.

`RequireDatabaseEncryption`, `RetentionDays` and `BulkReadLimits` are reserved: Watchtower reads and shows them but does not enforce them in this version.

## What happens to existing data

- A forbidden source's accounts stay listed under **Blocked by your organization** and keep their synced data. Its data is never deleted for being unreached while the rule holds; an account whose access is revoked still follows [revoked access](../concepts/revoked-access.md).
- After `MobileSync` was `off`, a phone has to be paired again once you allow sync.

## Pinning the AI account

Watchtower restricts the provider; the account the provider's own tool signs in with is forced by that tool's managed settings, which you deploy next to Watchtower's.

- **Claude Code:** set `forceLoginMethod` to `claudeai` and `forceLoginOrgUUID` to your organization's id (domain `com.anthropic.claudecode`, or `/Library/Application Support/ClaudeCode/managed-settings.json`). Claude Code then refuses a login from another organization. See [Restrict login to your organization](https://code.claude.com/docs/en/authentication#restrict-login-to-your-organization).
- **Codex:** set the requirements `allowed_login_methods` and `allowed_chatgpt_workspaces` (domain `com.openai.codex`, key `requirements_toml_base64`, or the system `requirements.toml`). See [Managed configuration](https://developers.openai.com/codex/enterprise/managed-configuration).

## Checking a Mac

Run `watchtower policy show` for the effective policy in plain words, or `watchtower policy show --json` for scripts (keys `managed`, `domain`, `keys`, `reserved_not_enforced`, `errors`). In the app, the same list is under **Settings → System → Privacy → Organization policy**.

## Related

- [Managed by your organization](../concepts/managed-by-your-organization.md)
- [Privacy](../concepts/privacy.md)
- [Command line](cli.md)

For developers: [docs/features/mdm-policy.md](../../features/mdm-policy.md)

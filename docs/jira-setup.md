# Jira Integration Setup

## Prerequisites

1. Atlassian OAuth 2.0 (3LO) app created at https://developer.atlassian.com/console/myapps/
2. App configured with:
   - **Authorization**: OAuth 2.0 (3LO), callback URL: `http://localhost:18511/callback`
   - **Permissions**: Jira API (`read:jira-work`, `read:jira-user`), User identity API
   - **Distribution**: Sharing enabled (required for non-owner access)
3. Client ID and Secret from app Settings

## Build Configuration

Add credentials to `.env` in project root (gitignored):

```
WATCHTOWER_JIRA_CLIENT_ID=<your-client-id>
WATCHTOWER_JIRA_CLIENT_SECRET=<your-client-secret>
```

Build:

```bash
make build          # CLI only
make app-dev        # Desktop app (dev, no signing)
make app            # Desktop app (signed + notarized)
```

Both `Makefile` and `scripts/build-app.sh` read `.env` (or an alternative profile selected with `ENV_FILE=<file>`) and inject credentials via ldflags. A non-default profile must set `BUILD_FLAVOR` — see the build-profiles section in `README.md`.

## First-Time Connect

```bash
watchtower jira add               # Opens browser for OAuth, creates the site's account row
watchtower jira accounts          # List connected sites and their ids
watchtower jira status            # Verify connection
watchtower jira boards            # List available boards
watchtower jira boards select 1 2 # Select boards for sync
watchtower jira users             # Show Jira-to-Slack user mapping
watchtower jira sync              # Manual sync
```

Or via Desktop App: Settings → Jira Sites → Add Jira Site.

`jira add` is the command for every site, including the first — run it again for
each additional site, and each one gets its own account row, its own token, and
its own sync watermarks. Two optional flags: `--label` names the site in the UI,
and `--site https://<site>.atlassian.net` picks one non-interactively when your
Atlassian account can reach several. `jira login` is kept as a legacy alias that
operates on account #1 (creating it on first use); to re-consent a specific site
later, use `jira login --account <id>` with an id from `jira accounts`.

With more than one site connected, add `--account <id>` to the board, sync, and
fields commands (they default to your single connected site). The cross-site
dashboards — `workload`, `blockers`, `project-map`, `releases` — aggregate every
connected site and reject `--account`.

## Token Details

- **Access token**: 1 hour TTL, auto-refreshed
- **Refresh token**: 90 days TTL, rotating (each refresh gives new refresh token)
- Token file: `~/.local/share/watchtower/<workspace>/jira_token_<account-id>.json`
  — one per connected site (`jira_token_1.json`, `jira_token_2.json`, …). A
  pre-multi-account install's `jira_token.json` is renamed to
  `jira_token_1.json` automatically on the first run after upgrading.
- As long as daemon runs regularly, tokens refresh indefinitely

## Transfer to Another Machine

The simplest path is to re-connect: run `watchtower jira add` on the target
machine for each site. Nothing is lost — issues re-sync from Jira.

To move an existing connection instead, remember that a token is only usable
alongside its account row: the site identity (`cloud_id`, `site_url`) lives in
the `jira_accounts` table in `watchtower.db`, **not** in `config.yaml` any more
(the `jira.cloud_id` / `site_url` keys are a frozen legacy snapshot that nothing
reads). So copy the token files **and** the database, or nothing at all.

### 1. Jira tokens and the database

```bash
# Source (one token file per connected site):
~/.local/share/watchtower/<workspace>/jira_token_1.json
~/.local/share/watchtower/<workspace>/jira_token_2.json
~/.local/share/watchtower/<workspace>/watchtower.db

# Copy to the same paths on the target machine
mkdir -p ~/.local/share/watchtower/<workspace>
# paste the jira_token_<id>.json files and watchtower.db there
```

Copy the token file for every id listed by `watchtower jira accounts` — an
account whose token is missing is reported as needing a re-login and skipped by
sync, without affecting the other sites.

### 2. Config (if not already set up)

Ensure `~/.config/watchtower/config.yaml` enables the integration:

```yaml
jira:
  enabled: true
```

### 3. Verify

```bash
watchtower jira accounts               # Should list the transferred sites
watchtower jira status                 # Per-site status: each should read "ok"
watchtower jira boards --account <id>  # Should list that site's boards
```

The access token may be expired — that's fine. On first API call, the refresh token will automatically obtain a new access token.

## Troubleshooting

### "We couldn't identify the app" / "authorise request was incomplete"
- Ensure callback URL in Atlassian Console matches exactly: `http://localhost:18511/callback`
- Atlassian requires `localhost`, not `127.0.0.1`
- Check that Distribution is set to "Sharing"

### "only the owner of this application may grant it access"
- Enable Sharing in Distribution settings
- Or log in with the Atlassian account that created the app

### Token expired, no refresh
- Re-consent the affected site: `watchtower jira login --account <id>` (ids from
  `watchtower jira accounts`), or the **Re-login** button on its row in
  Settings → Jira Sites
- Sign in with the Atlassian identity that can reach that site: re-login refuses
  to continue when the site is not among the ones the new grant covers, rather
  than re-pointing the account at a different site
- Ensure `offline_access` scope is in the authorization request

### Port 18511 busy
- Kill stale watchtower processes: `pkill -f "watchtower.*jira"`
- Or the code will auto-increment to 18512 (add this to callback URLs in Console)

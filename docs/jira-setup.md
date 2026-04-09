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

Both `Makefile` and `scripts/build-app.sh` read `.env` and inject credentials via ldflags.

## First-Time Login

```bash
watchtower jira login       # Opens browser for OAuth
watchtower jira status      # Verify connection
watchtower jira boards      # List available boards
watchtower jira select 1 2  # Select boards for sync
watchtower jira users       # Show Jira-to-Slack user mapping
watchtower jira sync        # Manual sync
```

Or via Desktop App: Settings → Jira → Connect.

## Token Details

- **Access token**: 1 hour TTL, auto-refreshed
- **Refresh token**: 90 days TTL, rotating (each refresh gives new refresh token)
- Token file: `~/.local/share/watchtower/<workspace>/jira_token.json`
- As long as daemon runs regularly, tokens refresh indefinitely

## Transfer to Another Machine

Copy these files to the target machine:

### 1. Jira token

```bash
# Source:
~/.local/share/watchtower/<workspace>/jira_token.json

# Copy to same path on target machine
mkdir -p ~/.local/share/watchtower/<workspace>
# paste jira_token.json there
```

### 2. Config (if not already set up)

Ensure `~/.config/watchtower/config.yaml` contains:

```yaml
jira:
  enabled: true
  cloud_id: "<your-cloud-id>"
  site_url: "https://<your-site>.atlassian.net"
```

### 3. Verify

```bash
watchtower jira status    # Should show "connected"
watchtower jira boards    # Should list boards
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
- Re-run `watchtower jira login`
- Ensure `offline_access` scope is in the authorization request

### Port 18511 busy
- Kill stale watchtower processes: `pkill -f "watchtower.*jira"`
- Or the code will auto-increment to 18512 (add this to callback URLs in Console)

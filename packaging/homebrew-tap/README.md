# Homebrew tap for Watchtower

[Watchtower](https://github.com/aiwatchtowers/watchtower) is a local Mac app that reads your Slack, mail, calendar and Jira, tells you what needs you, and gives your Claude Code or Codex sessions a board to work from.

## Install

```bash
brew install --cask aiwatchtowers/tap/watchtower
```

This puts **Watchtower.app** in `/Applications` and links the `watchtower` CLI into Homebrew's `bin`. It needs a Mac with Apple Silicon on macOS 14 (Sonoma) or later.

The app updates itself, so `brew upgrade` skips it (the cask sets `auto_updates true`); `brew upgrade --greedy` forces a Homebrew upgrade. `brew uninstall --zap --cask watchtower` also removes Watchtower's data and settings.

## How this tap is updated

On every public release, the main repository's release workflow rewrites `version` and `sha256` in `Casks/watchtower.rb` and pushes the change here. Any other change to the cask starts in [`packaging/homebrew-tap/`](https://github.com/aiwatchtowers/watchtower/tree/main/packaging/homebrew-tap) in the main repository, so open issues and pull requests in [aiwatchtowers/watchtower](https://github.com/aiwatchtowers/watchtower).

## License

MIT, see [LICENSE](LICENSE).

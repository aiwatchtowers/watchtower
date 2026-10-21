# Stage 2 keychain gate probe (spike, never merged)

The probe for G1–G5 in `docs/superpowers/plans/2026-10-21-db-encryption-stage1.md`
§ Stage 2 gate (spec §5.1, §5.3). It uses only the data protection keychain
(`kSecUseDataProtectionKeychain = true` on every call) and its own items:
service `com.watchtower.dbkey.probe`, account `probe`, SE tag
`com.watchtower.dbkey.se.probe`.

Each command prints one JSON line: `op`, `osstatus` (first failing step, or 0),
`elapsed_ms`, `console_locked` (`ioreg -n Root -d1 -a` `IOConsoleLocked`),
`prompt_suspected` (a Security call took more than 10 s), `sha256` (of the
plaintext DB key, `wrap` and `get`), `steps` (each Security call),
`version`, `pid`, `ts`.

Commands: `se-create`, `wrap [--add-only]`, `get`,
`loop --every 5s --for 3m --log FILE [--detach]`, `cleanup`, `version`.
`wrap --add-only` stores 32 raw random bytes without the SE key, so G5 also
exercises `SecItemAdd`.

`Probe.app` writes to stdout, which `open` drops, so the commands below use
`open -n -W --stdout FILE`.

## Checklist commands

```sh
B=${TMPDIR%/}/watchtower-probe-build            # or --out DIR
W="$HOME/Library/Application Support/WatchtowerProbe/bin/watchtower"
```

**Prep (owner, Mac unlocked).** Reads `CODESIGN_IDENTITY`,
`WATCHTOWER_PROVISION_PROFILE`, `NOTARIZE_PROFILE` from the environment or the
main checkout's `.env` (`ENV_FILE=` to pick another).

```sh
probe/make-bundles.sh --sign developer-id --notarize
codesign -dv --verbose=4 "$B/Probe.app" 2>&1 | grep -E 'Authority|TeamIdentifier|CDHash'
codesign -dv --verbose=4 "$B/Probe.app/Contents/Helpers/Watchtower CLI.app" 2>&1 | grep -E 'Authority|TeamIdentifier|CDHash'
codesign -d --entitlements - "$W"
spctl -a -vv "$B/Probe.app"
```

**G3 part 1 (the app creates both items).**

```sh
open -n -W --stdout "$B/g3.jsonl" "$B/Probe.app" --args se-create
open -n -W --stdout "$B/g3.jsonl" "$B/Probe.app" --args wrap
cat "$B/g3.jsonl"     # osstatus 0 twice; note wrap's sha256
```

**G1 + G3 part 2 (helper through the symlink, five times).**

```sh
for i in 1 2 3 4 5; do "$W" get; done   # osstatus 0, same sha256, elapsed_ms < 50
```

**G1 via a non-Terminal parent.**

```sh
launchctl asuser "$(id -u)" "$W" get
# hook-like: a Claude Code hook stub whose command is "$W" get >> FILE
```

**G2 (owner locks the screen at once with ⌃⌘Q, waits ≥ 2 min, unlocks).**

```sh
"$W" loop --every 5s --for 3m --log /tmp/g2.jsonl --detach
# afterwards: every line with "console_locked":true has "osstatus":0
grep '"console_locked":true' /tmp/g2.jsonl | grep -vc '"osstatus":0,'   # expect 0
```

**G4 (re-signed update keeps access).**

```sh
probe/make-bundles.sh --sign developer-id --notarize --version 0.1.1
codesign -dv --verbose=4 "$W" 2>&1 | grep CDHash   # differs from Prep
"$W" get
open -n -W --stdout "$B/g4.jsonl" "$B/Probe.app" --args get; cat "$B/g4.jsonl"
```

**G5 (ad-hoc, agent, separate dir, never installed).**

```sh
A=${TMPDIR%/}/watchtower-probe-adhoc
probe/make-bundles.sh --sign adhoc --out "$A"
H="$A/Probe.app/Contents/Helpers/Watchtower CLI.app/Contents/MacOS/watchtower"
"$H" get; "$H" wrap; "$H" wrap --add-only; "$H" se-create
security find-generic-password -s com.watchtower.dbkey.probe ~/Library/Keychains/login.keychain-db  # not found
```

Re-run `"$H" get` after G3, when the signed items exist: it must still fail
fast with no dialog.

**Cleanup.**

```sh
"$W" cleanup; "$W" get      # second get: -25300
rm -rf "$HOME/Library/Application Support/WatchtowerProbe" "$B" "$A"
```

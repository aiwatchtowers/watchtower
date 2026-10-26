#!/usr/bin/env bash
# Regenerate WatchtowerDesktop/.swiftlint-baseline.json with repo-relative paths.
# swiftlint --write-baseline stores absolute file:// URLs; strip them so the
# baseline works from any checkout (CI included). The file is pretty-printed
# so its diffs are reviewable.
#
# The baseline only absorbs legacy code, so by default the new one must be a
# subset of the old: any (rule, file, line text) entry it has more often than
# the old one fails the run, is listed, and leaves the file untouched.
# `--allow-new <rule-id>` (repeatable) lets one rule's new entries through,
# for a new or widened rule that deliberately absorbs legacy hits.
set -euo pipefail

allow='[]'
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-new)
            [ $# -ge 2 ] || { echo "swiftlint-baseline: --allow-new needs a rule id" >&2; exit 64; }
            allow=$(jq -c --arg r "$2" '. + [$r]' <<<"$allow"); shift 2 ;;
        *) echo "usage: $0 [--allow-new <rule-id>]..." >&2; exit 64 ;;
    esac
done

cd "$(dirname "$0")/../WatchtowerDesktop"
baseline=.swiftlint-baseline.json
raw=$(mktemp); new=$(mktemp)
trap 'rm -f "$raw" "$new"' EXIT

# 0 = no violations, 2 = violations (strict); anything else is a broken run.
rc=0
swiftlint lint --strict --quiet --write-baseline "$raw" >/dev/null || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    echo "swiftlint-baseline: swiftlint exited $rc; $baseline left unchanged" >&2
    exit 1
fi

jq 'map(.violation.location.file |= (sub("^file://.*/WatchtowerDesktop/"; "")))' "$raw" > "$new"

old='[]'
[ -f "$baseline" ] && old="$baseline"
# Entries the new baseline has more often than the old one, by
# (rule, file, line text), minus the allowed rules.
added=$(jq -rn --slurpfile new "$new" --argjson allow "$allow" \
    --slurpfile old <(if [ "$old" = '[]' ]; then echo '[]'; else cat "$old"; fi) '
    def key: [.violation.ruleIdentifier, .violation.location.file, .text];
    def counts: reduce (.[] | key | tojson) as $k ({}; .[$k] += 1);
    ($old[0] | counts) as $o
    | $new[0] | counts | to_entries
    | map(select(.value > ($o[.key] // 0)))
    | map(.key | fromjson | select(.[0] as $r | $allow | index($r) | not))
    | .[] | "\(.[0])  \(.[1])  \(.[2])"')
if [ -n "$added" ]; then
    echo "swiftlint-baseline: the new baseline would absorb violations the old one does not have; $baseline left unchanged." >&2
    echo "Fix them, or pass --allow-new <rule-id> for a rule that deliberately absorbs legacy code:" >&2
    echo "$added" >&2
    exit 1
fi

# cat, not mv: keep the file's mode (mktemp files are 0600).
cat "$new" > "$baseline"
echo "swiftlint-baseline: wrote $baseline ($(jq length "$baseline") entries)"

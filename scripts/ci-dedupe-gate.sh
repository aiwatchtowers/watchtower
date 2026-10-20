#!/bin/bash
# CI dedupe gate (.github/workflows/ci.yml, job `gate`): decides whether this
# run does the work and writes run=true|false to $GITHUB_OUTPUT.
#
# A push run on a branch other than main is skipped only when the
# pull_request run of the same commit on the same branch exists (a cancelled
# one does not count). A conflicting PR gets no pull_request run at all and
# one sometimes never fires, so the push run waits up to DEDUPE_POLLS x
# DEDUPE_POLL_SECONDS (12 x 10 s) for it and then goes ahead. Any gh/API
# error also lets the run go ahead (fail-open).
#
# Env: EVENT (github.event_name), GITHUB_REF_NAME, GITHUB_SHA,
# GITHUB_REPOSITORY, GITHUB_OUTPUT, GH_TOKEN.
set -uo pipefail

polls=${DEDUPE_POLLS:-12}
pause=${DEDUPE_POLL_SECONDS:-10}

decide() {
    if [ "$EVENT" != "push" ] || [ "$GITHUB_REF_NAME" = "main" ]; then
        echo "$EVENT on $GITHUB_REF_NAME — running"
        return 0
    fi
    local mergeable n i
    if ! mergeable=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$GITHUB_REF_NAME" --state open \
        --json mergeable --jq '.[0].mergeable // ""'); then
        echo "gh pr list failed — running (fail-open)"
        return 0
    fi
    if [ -z "$mergeable" ]; then
        echo "no open PR for $GITHUB_REF_NAME — running"
        return 0
    fi
    if [ "$mergeable" = "CONFLICTING" ]; then
        echo "the PR is conflicting, so no pull_request run comes — running"
        return 0
    fi
    for ((i = 1; i <= polls; i++)); do
        if ! n=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow ci.yml --event pull_request \
            --branch "$GITHUB_REF_NAME" --commit "$GITHUB_SHA" --json conclusion \
            --jq '[.[] | select(.conclusion != "cancelled")] | length'); then
            echo "gh run list failed — running (fail-open)"
            return 0
        fi
        if ! [[ "$n" =~ ^[0-9]+$ ]]; then
            echo "gh run list returned '$n', not a count — running (fail-open)"
            return 0
        fi
        if [ "$n" -gt 0 ]; then
            echo "the pull_request run covers $GITHUB_SHA — skipping"
            return 1
        fi
        if [ "$i" -lt "$polls" ]; then
            sleep "$pause"
        fi
    done
    echo "no pull_request run for $GITHUB_SHA after $((polls * pause)) s — running"
    return 0
}

if decide; then
    echo "run=true" >> "$GITHUB_OUTPUT"
else
    echo "run=false" >> "$GITHUB_OUTPUT"
fi

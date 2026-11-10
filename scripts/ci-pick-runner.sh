#!/bin/bash
# CI runner picker (.github/workflows/ci.yml, job `gate`, step `pick`): says
# where each class of job runs and writes its `runs-on` value as JSON to
# $GITHUB_OUTPUT:
#
#   linux — the jobs that run on ubuntu-24.04 in the cloud
#   macos — Swift Lint + Kit Test (macos-26 in the cloud)
#
# Swift Test and Mobile App are not classes: they always run in the cloud,
# since the Mac's runners have no window server (scripts/ci-runner/README.md).
#
# Both classes go to the owner's Mac (self-hosted runners set up by
# scripts/ci-runner/setup-mac-runner.sh) only when ALL hold:
#   - the event is a push or workflow_dispatch, or a pull_request whose head
#     branch lives in this repository (never a fork);
#   - RUNNER_STATUS_TOKEN is set (GITHUB_TOKEN cannot list runners);
#   - the repository's runner list shows a wt-general runner online.
# Anything else — a fork, no token, an API error or timeout, output that is
# not the runner list — keeps the class in the cloud (fail-safe). The script
# always exits 0, so the gate job never fails because of it.
#
# Env: EVENT (github.event_name), HEAD_REPO (the pull request's
# head.repo.full_name, empty otherwise), GITHUB_REPOSITORY, GITHUB_OUTPUT,
# RUNNER_STATUS_TOKEN (may be empty), PICK_TIMEOUT (seconds, default 20).
set -uo pipefail

CLOUD_LINUX='"ubuntu-24.04"'
CLOUD_MACOS='"macos-26"'
MAC_GENERAL='["self-hosted","wt-general"]'

linux=$CLOUD_LINUX
macos=$CLOUD_MACOS

write() {
    {
        echo "linux=$linux"
        echo "macos=$macos"
    } >> "$GITHUB_OUTPUT"
    echo "runs-on: linux=$linux macos=$macos"
}

eligible() {
    case "$EVENT" in
    push | workflow_dispatch) return 0 ;;
    pull_request)
        if [ -n "${HEAD_REPO:-}" ] && [ "$HEAD_REPO" = "$GITHUB_REPOSITORY" ]; then
            return 0
        fi
        echo "pull request from ${HEAD_REPO:-an unknown repository} — cloud"
        return 1
        ;;
    esac
    echo "event $EVENT — cloud"
    return 1
}

# Lists the labels of the online runners, one per line.
online_labels() {
    local body
    local -a limit=()
    if command -v timeout >/dev/null; then
        limit=(timeout "${PICK_TIMEOUT:-20}")
    fi
    if ! body=$(GH_TOKEN=$RUNNER_STATUS_TOKEN ${limit[@]+"${limit[@]}"} gh api \
        "repos/$GITHUB_REPOSITORY/actions/runners?per_page=100" 2>/dev/null); then
        echo "listing the runners failed — cloud" >&2
        return 1
    fi
    if ! jq -er '.runners | if type == "array" then . else error("no runner list") end
        | .[] | select(.status == "online") | .labels[].name' <<< "$body" 2>/dev/null; then
        # jq -e also fails on an empty result: no runner online at all.
        if jq -e '.runners | type == "array"' <<< "$body" >/dev/null 2>&1; then
            echo "no runner online — cloud" >&2
        else
            echo "the runner list did not parse — cloud" >&2
        fi
        return 1
    fi
}

main() {
    eligible || return 0
    if [ -z "${RUNNER_STATUS_TOKEN:-}" ]; then
        echo "RUNNER_STATUS_TOKEN is not set — cloud"
        return 0
    fi
    local labels
    labels=$(online_labels) || return 0
    if grep -qxF wt-general <<< "$labels"; then
        linux=$MAC_GENERAL
        macos=$MAC_GENERAL
    fi
}

main
write
exit 0

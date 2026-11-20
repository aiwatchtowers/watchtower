#!/bin/bash
# Tests for the build-profile selection block of scripts/build-app.sh.
#
# Extracts the block verbatim (BEGIN/END markers) and runs it in a child bash
# process against a synthetic PROJECT_ROOT — no real build.
#
# Covers:
#   - no ENV_FILE, .env present                       → sourced, flavor picked up
#   - no ENV_FILE, .env absent (valid, degenerate)    → continues, empty flavor
#   - explicit ENV_FILE=.env with .env absent         → continues (resolved-path
#     rule: naming the default profile explicitly behaves like not setting it)
#   - explicit relative profile, present              → sourced from PROJECT_ROOT
#   - explicit absolute profile, present              → sourced
#   - explicit profile missing                        → exit 1
#   - non-default profile without BUILD_FLAVOR        → exit 1 (mislabeled-
#     artifact guard: partner credentials must never wear the default name)
#   - BUILD_FLAVOR with a space / slash               → exit 1 (ldflags + path)
#   - FLAVOR_SUFFIX derivation, empty vs non-empty
#   - ambient BUILD_FLAVOR without any profile        → still honored (default
#     profile path applies no flavor requirement)
#   - WATCHTOWER_LINK_FETCH_DENY_HOSTS is optional for every build (the
#     owner's company domains are derived from the accounts, ask #598)
#   - the shared-jira-check block: a public release that bakes
#     WATCHTOWER_JIRA_CLIENT_ID/SECRET → exit 1 (#1887 D4); --dev, a
#     non-release version and a flavoured build keep them
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"

FAILURES=0

note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SNIPPET="$WORK_DIR/snippet.sh"
END_MARKER="# END profile-selection"
sed -n "/# BEGIN profile-selection/,/$END_MARKER/p" "$BUILD_APP" > "$SNIPPET"
if ! grep -q 'FLAVOR_SUFFIX' "$SNIPPET"; then
    echo "FAIL: snippet extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi
if [ "$(tail -n 1 "$SNIPPET")" != "$END_MARKER" ]; then
    echo "FAIL: extracted block does not end at '$END_MARKER' — END marker lost, extraction ran to EOF"
    exit 1
fi

# run_profile <project_root> [ENV_FILE value] [extra env assignments...]
# Runs the block in a fresh bash process (build-app.sh's own set -euo pipefail)
# and prints RESULT lines on success. Exit code is the block's exit code.
RUNNER="$WORK_DIR/runner.sh"
cat > "$RUNNER" <<EOF
set -euo pipefail
PROJECT_ROOT="\$1"
. "$SNIPPET"
echo "RESULT_FLAVOR=\$FLAVOR"
echo "RESULT_SUFFIX=\$FLAVOR_SUFFIX"
echo "RESULT_MARKER=\${PROFILE_MARKER:-}"
EOF

# 1. No ENV_FILE, .env present → sourced, flavor + suffix derived.
ROOT1="$WORK_DIR/root1"
mkdir -p "$ROOT1"
printf 'BUILD_FLAVOR=b2\nPROFILE_MARKER=default-env\n' > "$ROOT1/.env"
OUT=$(env -u ENV_FILE -u BUILD_FLAVOR bash "$RUNNER" "$ROOT1")
if grep -q "RESULT_FLAVOR=b2" <<< "$OUT" && grep -q "RESULT_SUFFIX=-b2" <<< "$OUT" && grep -q "RESULT_MARKER=default-env" <<< "$OUT"; then
    echo "ok: default .env sourced, flavor and suffix derived"
else
    note_fail "default .env sourced (got: $OUT)"
fi

# 2. No ENV_FILE, .env absent → continues with empty flavor and suffix.
ROOT2="$WORK_DIR/root2"
mkdir -p "$ROOT2"
OUT=$(env -u ENV_FILE -u BUILD_FLAVOR bash "$RUNNER" "$ROOT2")
if grep -q "RESULT_FLAVOR=$" <<< "$OUT" && grep -q "RESULT_SUFFIX=$" <<< "$OUT"; then
    echo "ok: absent default .env is a silent no-op"
else
    note_fail "absent default .env no-op (got: $OUT)"
fi

# 3. Explicit ENV_FILE=.env with .env absent → still continues (resolved-path rule).
if OUT=$(env -u BUILD_FLAVOR ENV_FILE=.env bash "$RUNNER" "$ROOT2"); then
    echo "ok: explicit ENV_FILE=.env with no .env behaves like the default"
else
    note_fail "explicit ENV_FILE=.env with no .env must not hard-fail"
fi

# 4. Explicit relative profile resolves against PROJECT_ROOT, not CWD.
ROOT4="$WORK_DIR/root4"
mkdir -p "$ROOT4"
printf 'BUILD_FLAVOR=rel\nPROFILE_MARKER=relative\n' > "$ROOT4/.env.rel"
OUT=$(cd "$WORK_DIR" && env -u BUILD_FLAVOR ENV_FILE=.env.rel bash "$RUNNER" "$ROOT4")
if grep -q "RESULT_MARKER=relative" <<< "$OUT" && grep -q "RESULT_SUFFIX=-rel" <<< "$OUT"; then
    echo "ok: relative ENV_FILE resolves against PROJECT_ROOT"
else
    note_fail "relative ENV_FILE resolution (got: $OUT)"
fi

# 5. Explicit absolute profile is used as-is.
OUT=$(env -u BUILD_FLAVOR ENV_FILE="$ROOT4/.env.rel" bash "$RUNNER" "$ROOT2")
if grep -q "RESULT_MARKER=relative" <<< "$OUT"; then
    echo "ok: absolute ENV_FILE used as-is"
else
    note_fail "absolute ENV_FILE (got: $OUT)"
fi

# 6. Explicit profile missing → exit 1.
if env -u BUILD_FLAVOR ENV_FILE=.env.missing bash "$RUNNER" "$ROOT2" > /dev/null 2>&1; then
    note_fail "missing explicit profile must exit 1"
else
    echo "ok: missing explicit profile hard-fails"
fi

# 7. Non-default profile that forgets BUILD_FLAVOR → exit 1.
printf 'PROFILE_MARKER=flavorless\n' > "$ROOT4/.env.noflavor"
if env -u BUILD_FLAVOR ENV_FILE=.env.noflavor bash "$RUNNER" "$ROOT4" > /dev/null 2>&1; then
    note_fail "flavorless non-default profile must exit 1"
else
    echo "ok: non-default profile without BUILD_FLAVOR hard-fails"
fi

# 8. Invalid flavor characters → exit 1 (space breaks ldflags, slash breaks paths).
printf 'BUILD_FLAVOR="two words"\n' > "$ROOT4/.env.space"
printf 'BUILD_FLAVOR=a/b\n' > "$ROOT4/.env.slash"
if env -u BUILD_FLAVOR ENV_FILE=.env.space bash "$RUNNER" "$ROOT4" > /dev/null 2>&1; then
    note_fail "flavor with a space must exit 1"
else
    echo "ok: flavor with a space hard-fails"
fi
if env -u BUILD_FLAVOR ENV_FILE=.env.slash bash "$RUNNER" "$ROOT4" > /dev/null 2>&1; then
    note_fail "flavor with a slash must exit 1"
else
    echo "ok: flavor with a slash hard-fails"
fi

# 9. Ambient BUILD_FLAVOR with no profile file → honored (default path).
OUT=$(env -u ENV_FILE BUILD_FLAVOR=ambient bash "$RUNNER" "$ROOT2")
if grep -q "RESULT_SUFFIX=-ambient" <<< "$OUT"; then
    echo "ok: ambient BUILD_FLAVOR honored on the default path"
else
    note_fail "ambient BUILD_FLAVOR (got: $OUT)"
fi

# 10. The link deny list is optional: a flavour without it still builds.
printf 'BUILD_FLAVOR=corp\n' > "$ROOT4/.env.nodeny"
if OUT=$(env -u BUILD_FLAVOR -u WATCHTOWER_LINK_FETCH_DENY_HOSTS ENV_FILE=.env.nodeny bash "$RUNNER" "$ROOT4") && grep -q "RESULT_SUFFIX=-corp" <<< "$OUT"; then
    echo "ok: a flavour without WATCHTOWER_LINK_FETCH_DENY_HOSTS builds"
else
    note_fail "a flavour must not need WATCHTOWER_LINK_FETCH_DENY_HOSTS"
fi
if env -u ENV_FILE -u BUILD_FLAVOR -u WATCHTOWER_LINK_FETCH_DENY_HOSTS bash "$RUNNER" "$ROOT2" > /dev/null 2>&1; then
    echo "ok: the public build needs no link deny list"
else
    note_fail "the public build must not need WATCHTOWER_LINK_FETCH_DENY_HOSTS"
fi

# 11. The retired shared Atlassian app (#1887 D4): a public release whose
# profile bakes WATCHTOWER_JIRA_CLIENT_ID/SECRET is refused; --dev, a
# non-release version and a flavoured build may keep them.
JIRA_SNIPPET="$WORK_DIR/shared-jira.sh"
sed -n "/# BEGIN shared-jira-check/,/# END shared-jira-check/p" "$BUILD_APP" > "$JIRA_SNIPPET"
if [ "$(tail -n 1 "$JIRA_SNIPPET")" != "# END shared-jira-check" ]; then
    echo "FAIL: shared-jira-check block not found in build-app.sh — markers moved?"
    exit 1
fi
JIRA_RUNNER="$WORK_DIR/jira-runner.sh"
cat > "$JIRA_RUNNER" <<EOF
set -euo pipefail
PROJECT_ROOT="\$1"
. "$SNIPPET"
. "$JIRA_SNIPPET"
echo "RESULT_JIRA=ok"
EOF
ROOT11="$WORK_DIR/root11"
mkdir -p "$ROOT11"
printf 'WATCHTOWER_JIRA_CLIENT_ID=shared-jira-id\nWATCHTOWER_JIRA_CLIENT_SECRET=shared-jira-secret\n' > "$ROOT11/.env"
printf 'BUILD_FLAVOR=corp\nWATCHTOWER_JIRA_CLIENT_ID=corp-jira-id\n' > "$ROOT11/.env.corp"
# run_jira <ENV_FILE> <DEV_MODE> <VERSION>: sets JIRA_RC and JIRA_OUT.
run_jira() {
    JIRA_RC=0
    JIRA_OUT=$(env -u BUILD_FLAVOR -u WATCHTOWER_JIRA_CLIENT_ID -u WATCHTOWER_JIRA_CLIENT_SECRET \
        ENV_FILE="$1" DEV_MODE="$2" VERSION="$3" bash "$JIRA_RUNNER" "$ROOT11" 2>&1) || JIRA_RC=$?
}
for v in 1.2.3 v1.2.3 v1.2.3-rc1; do
    run_jira .env false "$v"
    if [ "$JIRA_RC" -eq 1 ] && grep -q "a public release must not bake the retired shared Atlassian app" <<< "$JIRA_OUT"; then
        echo "ok: a public release $v with a Jira client is refused"
    else
        note_fail "public release $v with a Jira client: want exit 1 and the message, got rc=$JIRA_RC: $JIRA_OUT"
    fi
done
# The secret alone is refused too; ENV_FILE is the default .env path here, so
# the profile carries no flavour (a non-default one would need BUILD_FLAVOR).
mkdir -p "$WORK_DIR/root11s"
printf 'WATCHTOWER_JIRA_CLIENT_SECRET=shared-jira-secret\n' > "$WORK_DIR/root11s/.env"
JIRA_RC=0
JIRA_OUT=$(env -u BUILD_FLAVOR -u WATCHTOWER_JIRA_CLIENT_ID -u WATCHTOWER_JIRA_CLIENT_SECRET -u ENV_FILE \
    DEV_MODE=false VERSION=1.2.3 bash "$JIRA_RUNNER" "$WORK_DIR/root11s" 2>&1) || JIRA_RC=$?
if [ "$JIRA_RC" -eq 1 ]; then
    echo "ok: a public release with only the Jira secret is refused"
else
    note_fail "public release with only the Jira secret: want exit 1, got rc=$JIRA_RC: $JIRA_OUT"
fi
run_jira .env true 1.2.3
if [ "$JIRA_RC" -eq 0 ] && grep -q "RESULT_JIRA=ok" <<< "$JIRA_OUT"; then
    echo "ok: --dev may bake the development Jira client"
else
    note_fail "--dev with a Jira client must build: rc=$JIRA_RC: $JIRA_OUT"
fi
run_jira .env false local-build
if [ "$JIRA_RC" -eq 0 ]; then
    echo "ok: a non-release version may bake the development Jira client"
else
    note_fail "non-release version with a Jira client must build: rc=$JIRA_RC: $JIRA_OUT"
fi
run_jira .env.corp false 1.2.3
if [ "$JIRA_RC" -eq 0 ]; then
    echo "ok: a flavoured release keeps its Jira client"
else
    note_fail "flavoured release with a Jira client must build: rc=$JIRA_RC: $JIRA_OUT"
fi
mkdir -p "$WORK_DIR/root11n"
JIRA_RC=0
JIRA_OUT=$(env -u BUILD_FLAVOR -u WATCHTOWER_JIRA_CLIENT_ID -u WATCHTOWER_JIRA_CLIENT_SECRET -u ENV_FILE \
    DEV_MODE=false VERSION=1.2.3 bash "$JIRA_RUNNER" "$WORK_DIR/root11n" 2>&1) || JIRA_RC=$?
if [ "$JIRA_RC" -eq 0 ]; then
    echo "ok: a public release without a Jira client builds"
else
    note_fail "public release without a Jira client must build: rc=$JIRA_RC: $JIRA_OUT"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES profile-selection test(s) failed."
    exit 1
fi
echo "All profile-selection tests passed."

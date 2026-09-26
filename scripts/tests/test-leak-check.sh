#!/bin/bash
# Tests for scripts/leak-check.sh against throwaway git repos in a temp dir —
# never this repository's history, never the real denylist.
#
# Fixture values that the checker must flag are assembled at runtime (split
# string literals, printf fields) so this file's own added lines stay clean
# when leak-check scans the commit that adds it.
#
# Covers:
#   - denylist hit                                → exit 1, file:line reported,
#                                                   the pattern never echoed
#   - denylist file with blank/comment lines      → blank lines match nothing
#   - generic Slack id-shaped token               → exit 1
#   - the same token with the allow marker        → exit 0
#   - the allow marker never excuses a denylist hit
#   - allowlisted email domains                   → exit 0
#   - an email on another domain                  → exit 1
#   - removed lines only                          → exit 0
#   - a leak added then removed inside the range  → exit 1 (history keeps it)
#   - added text starting with "++"               → still scanned as content
#   - missing denylist file                       → loud SKIPPED, generic layer
#                                                   still runs
#   - --staged and stdin (-) modes
#   - an empty range (valid, degenerate)          → exit 0
#   - a bad argument                              → exit 2
#   - a denylist line that is not a valid ERE     → exit 2 naming the line
#                                                   number, pattern never echoed
#                                                   (one bad line must not make
#                                                   the layer match nothing)
#   - grep itself failing mid-scan                → exit 2, never "clean"
#   - a conflict-resolution merge commit adding a
#     denylisted token                            → exit 1, reported on the merge
#   - a clean merge                               → exit 0, no false hits
#   - a denylist file with CRLF line endings      → patterns still match
#   - a channel-shaped (C0…) Slack id             → exit 1
#   - a denylisted token in a commit message      → exit 1
#   - an author email on a foreign domain         → exit 1, unless that exact
#                                                   identity is already on
#                                                   origin/main; a denylisted
#                                                   identity is never excused
#   - a token added on a side branch, then merged → reported on the side commit
#                                                   only, never again on the merge
#                                                   (clean merge and conflict
#                                                   resolution that keeps it)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LEAK_CHECK="$SCRIPT_DIR/../leak-check.sh"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

if ! bash -n "$LEAK_CHECK"; then
    echo "FAIL: leak-check.sh does not parse"
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/leak-check-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SECRET_WORD="zorb""laxcorp"
SLACK_ID="U0""ABCDEFGH12"
DENYLIST="$TMP/denylist"
printf '# comment line\n\n%s\n   \n' "$SECRET_WORD" > "$DENYLIST"

# new_repo <name> — a repo with one base commit; prints its path.
new_repo() {
    local dir="$TMP/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.name test
    git -C "$dir" config user.email test@example.com
    echo base > "$dir/base.txt"
    git -C "$dir" add base.txt
    git -C "$dir" commit -q -m base
    echo "$dir"
}

commit_file() { # <repo> <file> <content>
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q -m "edit $2"
}

OUT="$TMP/out"
# run <repo> <args...> — runs leak-check inside the repo, sets RC, output in $OUT.
run() {
    local repo="$1"; shift
    set +e
    (cd "$repo" && WATCHTOWER_LEAK_DENYLIST="${DENY_OVERRIDE:-$DENYLIST}" bash "$LEAK_CHECK" "$@") > "$OUT" 2>&1
    RC=$?
    set -e
}

expect_rc() { # <want> <case>
    if [ "$RC" -ne "$1" ]; then
        note_fail "$2: exit $RC, want $1"
        sed 's/^/    /' "$OUT"
    fi
}
expect_out() { grep -q -F -- "$1" "$OUT" || { note_fail "$2: output lacks '$1'"; sed 's/^/    /' "$OUT"; }; }
expect_no_out() { if grep -q -i -F -- "$1" "$OUT"; then note_fail "$2: output contains '$1'"; fi; }

# 1. Denylist hit: reported by file:line, the pattern never echoed.
R="$(new_repo deny)"
commit_file "$R" notes.md "first line
the $SECRET_WORD workspace"
run "$R" HEAD~1..HEAD
expect_rc 1 "denylist hit"
expect_out "notes.md:2: denylisted identifier" "denylist hit"
expect_no_out "$SECRET_WORD" "denylist hit"

# 2. Blank lines in the denylist match nothing.
R="$(new_repo blank)"
commit_file "$R" ok.md "an ordinary line"
run "$R" HEAD~1..HEAD
expect_rc 0 "blank denylist lines"

# 3. Generic Slack id-shaped token.
R="$(new_repo slack)"
commit_file "$R" fixture.go "id := \"$SLACK_ID\""
run "$R" HEAD~1..HEAD
expect_rc 1 "Slack id"
expect_out "fixture.go:1: Slack id-shaped token" "Slack id"
expect_no_out "$SLACK_ID" "Slack id"

# 4. The allow marker excuses a deliberate fake...
R="$(new_repo allow)"
commit_file "$R" fixture.go "id := \"$SLACK_ID\" // leak-check:allow"
run "$R" HEAD~1..HEAD
expect_rc 0 "allow marker"

# 5. ...but never a denylist hit.
R="$(new_repo allow-deny)"
commit_file "$R" notes.md "$SECRET_WORD leak-check:allow"
run "$R" HEAD~1..HEAD
expect_rc 1 "allow marker vs denylist"

# 6. Allowlisted email domains.
R="$(new_repo mail-ok)"
commit_file "$R" mail.md "alice@example.com bob@mail.example.org carol@example.net
Co-Authored-By: Claude <noreply@anthropic.com>
dev@box.test support@aiwatchtowers.com a@x.com me@y.io"
run "$R" HEAD~1..HEAD
expect_rc 0 "allowed email domains"

# 7. An email on any other domain.
R="$(new_repo mail-bad)"
commit_file "$R" mail.md "$(printf 'contact %s@%s.org' someone corp-mail)"
run "$R" HEAD~1..HEAD
expect_rc 1 "foreign email domain"
expect_out "mail.md:1: email outside the allowed domains" "foreign email domain"

# 8. Removed lines are ignored.
R="$(new_repo removed)"
commit_file "$R" legacy.md "$SECRET_WORD and $SLACK_ID"
commit_file "$R" legacy.md "scrubbed"
run "$R" HEAD~1..HEAD
expect_rc 0 "removed lines only"

# 9. Added and removed inside one range: the adding commit is still in history.
run "$R" HEAD~2..HEAD
expect_rc 1 "add-then-remove inside the range"

# 10. Added text that itself starts with "++" is content, not a diff header.
R="$(new_repo plusplus)"
commit_file "$R" c.txt "++ $SLACK_ID"
run "$R" HEAD~1..HEAD
expect_rc 1 "added line starting with ++"

# 11. Missing denylist: loud skip, generic layer still runs.
R="$(new_repo missing)"
commit_file "$R" fixture.go "id := \"$SLACK_ID\""
DENY_OVERRIDE="$TMP/does-not-exist" run "$R" HEAD~1..HEAD
expect_rc 1 "missing denylist"
expect_out "denylist layer SKIPPED" "missing denylist"

# 12. --staged mode.
R="$(new_repo staged)"
printf 'the %s workspace\n' "$SECRET_WORD" > "$R/staged.md"
git -C "$R" add staged.md
run "$R" --staged
expect_rc 1 "--staged"
expect_out "staged.md:1: denylisted identifier" "--staged"

# 13. stdin mode.
R="$(new_repo stdin)"
set +e
printf -- '--- a/x.txt\n+++ b/x.txt\n@@ -0,0 +1,2 @@\n+clean\n+%s\n' "$SLACK_ID" \
    | (cd "$R" && WATCHTOWER_LEAK_DENYLIST="$DENYLIST" bash "$LEAK_CHECK" -) > "$OUT" 2>&1
RC=$?
set -e
expect_rc 1 "stdin"
expect_out "x.txt:2: Slack id-shaped token" "stdin"

# 14. Empty range (valid, degenerate).
R="$(new_repo empty)"
run "$R" HEAD..HEAD
expect_rc 0 "empty range"
expect_out "leak-check: clean" "empty range"

# 15. Bad argument.
run "$R" not-a-range
expect_rc 2 "bad argument"

# 16. A denylist line that does not compile fails the run loudly.
R="$(new_repo bad-deny)"
commit_file "$R" notes.md "the $SECRET_WORD workspace"
BAD_PATTERN="unbal""anced(paren"
printf '# comment\n%s\n%s\n' "$SECRET_WORD" "$BAD_PATTERN" > "$TMP/bad-denylist"
DENY_OVERRIDE="$TMP/bad-denylist" run "$R" HEAD~1..HEAD
expect_rc 2 "invalid denylist line"
expect_out "line 3 is not a valid extended regex" "invalid denylist line"
expect_no_out "$BAD_PATTERN" "invalid denylist line"
expect_no_out "$SECRET_WORD" "invalid denylist line"

# 16b. grep failing mid-scan (a shim that errors on the email pass) is fatal.
REAL_GREP="$(command -v grep)"
mkdir -p "$TMP/shim"
# shellcheck disable=SC2016  # the shim's "$@" must expand when it runs, not here
printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = "-o" ] && exit 2; done\nexec %s "$@"\n' "$REAL_GREP" > "$TMP/shim/grep"
chmod +x "$TMP/shim/grep"
R="$(new_repo grep-error)"
commit_file "$R" ok.md "an ordinary line"
PATH="$TMP/shim:$PATH" run "$R" HEAD~1..HEAD
expect_rc 2 "grep error mid-scan"
expect_out "grep failed" "grep error mid-scan"
expect_no_out "leak-check: clean" "grep error mid-scan"

# merge_repo <name> <side line> <main line> — base file `f` of three lines;
# `side` and the main branch each rewrite line 2, then main merges side
# (a conflict when the lines differ). Leaves the repo on main, merge unfinished
# when it conflicted.
merge_repo() {
    local dir
    dir="$(new_repo "$1")"
    printf 'one\ntwo\nthree\n' > "$dir/f"
    git -C "$dir" add f && git -C "$dir" commit -q -m f
    git -C "$dir" checkout -q -b side
    printf 'one\n%s\nthree\n' "$2" > "$dir/f"
    git -C "$dir" commit -q -a -m side
    git -C "$dir" checkout -q -
    printf 'one\n%s\nthree\n' "$3" > "$dir/f"
    echo other > "$dir/g"
    git -C "$dir" add f g && git -C "$dir" commit -q -m main
    git -C "$dir" merge -q --no-edit side > /dev/null 2>&1 || true
    echo "$dir"
}

# 17. A conflict resolution that introduces a denylisted token.
R="$(merge_repo evil-merge "side line" "main line")"
printf 'one\nresolved with %s\nmain line\nthree\n' "$SECRET_WORD" > "$R/f"
git -C "$R" add f && git -C "$R" commit -q --no-edit
MERGE_SHA="$(git -C "$R" rev-parse --short HEAD)"
run "$R" HEAD~2..HEAD
expect_rc 1 "conflict-resolution merge"
expect_out "$MERGE_SHA f:2: denylisted identifier" "conflict-resolution merge"

# 18. A clean merge produces no hits.
R="$(new_repo clean-merge)"
git -C "$R" checkout -q -b side
commit_file "$R" side.txt "side work"
git -C "$R" checkout -q -
commit_file "$R" main.txt "main work"
git -C "$R" merge -q --no-edit side > /dev/null
run "$R" HEAD~2..HEAD
expect_rc 0 "clean merge"

# 19. A side-branch token is reported on its own commit, never on the merge.
R="$(new_repo side-token)"
git -C "$R" checkout -q -b side
commit_file "$R" side.txt "the $SECRET_WORD workspace"
SIDE_SHA="$(git -C "$R" rev-parse --short HEAD)"
git -C "$R" checkout -q -
commit_file "$R" main.txt "main work"
git -C "$R" merge -q --no-edit side > /dev/null
run "$R" HEAD~1..HEAD
expect_rc 1 "side-branch token"
expect_out "$SIDE_SHA side.txt:1: denylisted identifier" "side-branch token"
if [ "$(grep -c 'denylisted identifier' "$OUT")" -ne 1 ]; then
    note_fail "side-branch token: reported more than once"
    sed 's/^/    /' "$OUT"
fi

# 20. A conflict resolution that keeps the side's token line: the line came
#     from a parent, so only the side commit reports it.
R="$(merge_repo kept-side "side has $SECRET_WORD" "main line")"
SIDE_SHA="$(git -C "$R" rev-parse --short side)"
printf 'one\nside has %s\nmain line\nthree\n' "$SECRET_WORD" > "$R/f"
git -C "$R" add f && git -C "$R" commit -q --no-edit
run "$R" HEAD~2..HEAD
expect_rc 1 "resolution keeps a side line"
expect_out "$SIDE_SHA f:2: denylisted identifier" "resolution keeps a side line"
if [ "$(grep -c 'denylisted identifier' "$OUT")" -ne 1 ]; then
    note_fail "resolution keeps a side line: reported more than once"
    sed 's/^/    /' "$OUT"
fi

# 21. CRLF denylist (a CI secret pasted from Windows) still matches.
R="$(new_repo crlf)"
commit_file "$R" notes.md "the $SECRET_WORD workspace"
printf '# comment\r\n%s\r\n' "$SECRET_WORD" > "$TMP/crlf-denylist"
DENY_OVERRIDE="$TMP/crlf-denylist" run "$R" HEAD~1..HEAD
expect_rc 1 "CRLF denylist"
expect_out "notes.md:1: denylisted identifier" "CRLF denylist"

# 22. A channel-shaped Slack id.
R="$(new_repo channel-id)"
commit_file "$R" fixture.go "ch := \"C0""ABCDEFGH12\""
run "$R" HEAD~1..HEAD
expect_rc 1 "channel id"
expect_out "fixture.go:1: Slack id-shaped token" "channel id"

# 23. A denylisted token in a commit message.
R="$(new_repo message)"
echo clean > "$R/m.txt"
git -C "$R" add m.txt
git -C "$R" commit -q -m "tidy up" -m "found on the $SECRET_WORD install"
run "$R" HEAD~1..HEAD
expect_rc 1 "commit message"
expect_out "<commit message>:3: denylisted identifier" "commit message"
expect_no_out "$SECRET_WORD" "commit message"

# 24. Author identity: a foreign email is flagged unless that exact identity
#     already authored a commit on origin/main; a denylisted one never passes.
FOREIGN="$(printf '%s@%s.org' dev corp-mail)"
OTHER="$(printf '%s@%s.org' someone-else corp-mail)"
R="$(new_repo identity)"
echo x > "$R/a.txt"; git -C "$R" add a.txt
GIT_AUTHOR_EMAIL="$FOREIGN" GIT_COMMITTER_EMAIL="$FOREIGN" git -C "$R" commit -q -m first
git -C "$R" update-ref refs/remotes/origin/main HEAD
echo y > "$R/b.txt"; git -C "$R" add b.txt
GIT_AUTHOR_EMAIL="$FOREIGN" GIT_COMMITTER_EMAIL="$FOREIGN" git -C "$R" commit -q -m known
run "$R" HEAD~1..HEAD
expect_rc 0 "identity already on origin/main"
echo z > "$R/c.txt"; git -C "$R" add c.txt
GIT_AUTHOR_EMAIL="$OTHER" git -C "$R" commit -q -m stranger
run "$R" HEAD~1..HEAD
expect_rc 1 "new foreign identity"
expect_out "<author>:1: email outside the allowed domains" "new foreign identity"
expect_no_out "<committer>" "new foreign identity"
DENIED="$(printf 'me@%s.org' "$SECRET_WORD")"
echo w > "$R/d.txt"; git -C "$R" add d.txt
GIT_AUTHOR_EMAIL="$DENIED" GIT_COMMITTER_EMAIL="$DENIED" git -C "$R" commit -q -m first-denied
git -C "$R" update-ref refs/remotes/origin/main HEAD
echo v > "$R/e.txt"; git -C "$R" add e.txt
GIT_AUTHOR_EMAIL="$DENIED" git -C "$R" commit -q -m again
run "$R" HEAD~1..HEAD
expect_rc 1 "denylisted identity on origin/main"
expect_out "<author>:1: denylisted identifier" "denylisted identity on origin/main"

if [ "$FAILURES" -gt 0 ]; then
    echo "test-leak-check: $FAILURES failure(s)"
    exit 1
fi
echo "test-leak-check: all cases passed"

#!/bin/bash
# Scans the lines a change ADDS for live-install data that must never land in
# this public repository. Removed and context lines are ignored: the job is to
# stop new leaks, not to re-litigate history.
#
# Usage:
#   scripts/leak-check.sh <A..B | A...B>  every commit reachable from B and not
#                                         from A, each scanned on its own patch (a
#                                         leak added then removed inside the range
#                                         still lands in history). A merge commit is
#                                         scanned on its combined diff
#                                         (`git diff-tree --cc`), counting only the
#                                         lines present in NONE of its parents — what
#                                         a conflict resolution or an "evil merge"
#                                         introduced; a clean merge adds nothing.
#                                         Each commit's message and its author and
#                                         committer identity are scanned too: all
#                                         three are published with the push.
#   scripts/leak-check.sh --staged        the index (git diff --cached)
#   scripts/leak-check.sh -               a unified diff read from stdin
#
# Two layers:
#   1. Denylist — one case-insensitive ERE per line, `#` comments allowed, from
#      $WATCHTOWER_LEAK_DENYLIST (default ~/.config/watchtower/leak-denylist).
#      The file is private and never committed. When it is missing the layer is
#      skipped LOUDLY and the generic layer still runs. A pattern that does not
#      compile fails the run (exit 2, naming the line number only) — one bad line
#      must never make the whole layer silently match nothing. There is no
#      inline override for a denylist hit.
#   2. Generic patterns for real-looking data: Slack ids (user U/W, team T,
#      channel C, DM D, group G, enterprise org E: the letter, `0`, then 8-10
#      uppercase alphanumerics) and email addresses on a domain outside the
#      allowlist below. A deliberate fake on a line carrying the marker
#      `leak-check:allow` passes this layer. An author/committer email already
#      used by a commit on origin/main (computed at runtime) is accepted as an
#      identity, never as content.
#
# Not scanned (documented limitations): binary files (git prints no text diff
# for them), and paths are not pattern-checked.
#
# Hits are reported as `path:line: <rule>` (prefixed with the short commit sha
# in range mode) and never echo the matched text or the denylist patterns —
# CI logs are public too. Exit 1 on any hit, 2 on a usage, denylist, grep or
# git error — every failure is loud, none reads as "clean".
set -euo pipefail

ALLOW_MARKER='leak-check:allow'
SLACK_ID_RE='\b[UTWCDGE]0[0-9A-Z]{8,10}\b'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

[ $# -eq 1 ] || usage

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/leak-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "leak-check: $*" >&2; exit 2; }

# safe_grep <grep args...> — grep that tells "no match" (exit 1, fine) from a
# grep error (exit >= 2, fatal). Call it with a plain redirect, never inside a
# pipeline, so the exit reaches this shell.
safe_grep() {
    local rc=0
    grep "$@" || rc=$?
    [ "$rc" -le 1 ] || fail "grep failed (exit $rc)"
}

# --- denylist ---------------------------------------------------------------
DENYLIST="${WATCHTOWER_LEAK_DENYLIST:-$HOME/.config/watchtower/leak-denylist}"
DENY_PATTERNS="$WORK/deny"
: > "$DENY_PATTERNS"
if [ -f "$DENYLIST" ]; then
    [ -r "$DENYLIST" ] || fail "denylist $DENYLIST is not readable"
    # Blank lines would match every line, so they are dropped with the comments.
    # Each remaining pattern is compiled on its own: `grep -f` over the whole
    # file errors out on one bad pattern, which would otherwise read as "no hit".
    n=0
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        n=$((n + 1))
        pattern="${pattern%$'\r'}"   # a secret pasted with CRLF endings
        case "$pattern" in *[![:space:]]*) ;; *) continue ;; esac   # blank
        trimmed="${pattern#"${pattern%%[![:space:]]*}"}"
        case "$trimmed" in '#'*) continue ;; esac                   # comment
        rc=0
        grep -i -E -e "$pattern" /dev/null 2>/dev/null || rc=$?
        [ "$rc" -le 1 ] || fail "denylist $DENYLIST line $n is not a valid extended regex"
        printf '%s\n' "$pattern" >> "$DENY_PATTERNS"
    done < "$DENYLIST"
    if [ ! -s "$DENY_PATTERNS" ]; then
        echo "leak-check: denylist $DENYLIST has no patterns — denylist layer SKIPPED (generic layer still runs)" >&2
    fi
else
    echo "leak-check: denylist $DENYLIST not found — denylist layer SKIPPED (generic layer still runs)" >&2
fi

# The published legal contact is public by design; anything else on its domain
# is not, so the address is allowlisted exactly, read from the page itself.
LEGAL_CONTACTS="$WORK/legal"
: > "$LEGAL_CONTACTS"
if [ -f "$REPO_ROOT/docs/legal/privacy-policy.md" ]; then
    safe_grep -o -E "$EMAIL_RE" "$REPO_ROOT/docs/legal/privacy-policy.md" > "$WORK/legal_raw"
    tr '[:upper:]' '[:lower:]' < "$WORK/legal_raw" | sort -u > "$LEGAL_CONTACTS"
fi

# Identities already on origin/main are public by construction; accepting them
# (for author/committer rows only) keeps the scan about what a push ADDS.
KNOWN_AUTHORS="$WORK/known_authors"
: > "$KNOWN_AUTHORS"
if git rev-parse --verify -q origin/main > /dev/null; then
    git_log_ok=0
    git log --format='%ae%n%ce' origin/main > "$WORK/authors_raw" || git_log_ok=$?
    [ "$git_log_ok" -eq 0 ] || fail "git log origin/main failed"
    tr '[:upper:]' '[:lower:]' < "$WORK/authors_raw" | sort -u > "$KNOWN_AUTHORS"
fi
NO_EXTRA_ALLOW="$WORK/no_extra_allow"
: > "$NO_EXTRA_ALLOW"

HITS="$WORK/hits"
: > "$HITS"

# Reads a unified diff on stdin and writes `path<TAB>line<TAB>text` for every
# added line. Hunk counters (not the `+++` prefix) decide what is a header, so
# an added line whose text itself starts with `++` is still content.
extract_added() {
    awk '
    function reset_hunk() { old_left = 0; new_left = 0 }
    BEGIN { path = ""; reset_hunk() }
    old_left > 0 || new_left > 0 {
        c = substr($0, 1, 1)
        if (c == "+") { if (path != "") printf "%s\t%d\t%s\n", path, ln, substr($0, 2); ln++; new_left--; next }
        if (c == "-") { old_left--; next }
        if (c == " ") { ln++; new_left--; old_left--; next }
        if (c == "\\") next
        reset_hunk()
    }
    /^\+\+\+ / {
        p = substr($0, 5)
        sub(/\t.*$/, "", p)
        gsub(/^"|"$/, "", p)
        if (p == "/dev/null") path = ""
        else { sub(/^b\//, "", p); path = p }
        next
    }
    /^@@ / {
        h = $0
        sub(/^@@ -/, "", h)
        split(h, parts, " ")
        n = split(parts[1], o, ",");  old_left = (n > 1) ? o[2] + 0 : 1
        nw = parts[2]; sub(/^\+/, "", nw)
        n = split(nw, w, ",");        ln = w[1] + 0; new_left = (n > 1) ? w[2] + 0 : 1
        next
    }
    '
}

# Reads a combined diff (`git diff-tree --cc`) on stdin and writes the same
# `path<TAB>line<TAB>text` rows, but only for lines whose every parent column is
# `+`: present in none of the parents, i.e. introduced by the merge itself. A
# line carried in from one side (` +`/`+ `) was already scanned in the commit
# that added it. File headers are only recognised outside a hunk (`diff --cc`
# can never start a content line, whose prefix columns are ` `/`+`/`-`).
extract_added_cc() {
    awk '
    /^diff --(cc|combined) / { in_hunk = 0; path = $0; sub(/^diff --(cc|combined) /, "", path); gsub(/^"|"$/, "", path); next }
    !in_hunk && /^\+\+\+ / {
        p = substr($0, 5); sub(/\t.*$/, "", p); gsub(/^"|"$/, "", p)
        if (p == "/dev/null") path = ""
        else { sub(/^b\//, "", p); path = p }
        next
    }
    /^@@@+ / {
        match($0, /^@+/); np = RLENGTH - 1      # @@@ = 2 parents, @@@@ = 3, …
        h = $0; sub(/^@+ /, "", h); sub(/ @+.*$/, "", h)
        k = split(h, parts, " "); nw = parts[k]; sub(/^\+/, "", nw)
        n = split(nw, w, ","); ln = w[1] + 0
        in_hunk = 1; next
    }
    in_hunk {
        if (substr($0, 1, 1) == "\\") next    # "\ No newline at end of file"
        cols = substr($0, 1, np)
        if (cols ~ /-/) next                    # not in the merge result
        if (cols ~ /^\++$/ && path != "") printf "%s\t%d\t%s\n", path, ln, substr($0, np + 1)
        ln++
    }
    '
}

# scan_added <label> [<extra allowed addresses file>] — scans the rows in
# $WORK/added, appends hits to $HITS.
scan_added() {
    local label="$1" extra="${2:-$NO_EXTRA_ALLOW}" added="$WORK/added" text="$WORK/text" allowed="$WORK/allowed" cand="$WORK/cand"
    [ -s "$added" ] || return 0
    cut -f3- "$added" > "$text"
    safe_grep -n -F "$ALLOW_MARKER" "$text" > "$WORK/allow_raw"
    cut -d: -f1 < "$WORK/allow_raw" > "$allowed"
    : > "$cand"

    # Each producer appends `<index into $text> <rule>`; the index maps back to
    # path:line through $added.
    if [ -s "$DENY_PATTERNS" ]; then
        safe_grep -n -i -E -f "$DENY_PATTERNS" "$text" > "$WORK/g_deny"
        cut -d: -f1 < "$WORK/g_deny" | sed 's/$/ denylisted identifier/' >> "$cand"
    fi

    safe_grep -n -E "$SLACK_ID_RE" "$text" > "$WORK/g_slack"
    cut -d: -f1 < "$WORK/g_slack" | awk -v allowed="$allowed" '
        BEGIN { while ((getline a < allowed) > 0) skip[a] = 1 }
        !($1 in skip) { print $1 " Slack id-shaped token" }' >> "$cand"

    safe_grep -n -o -E "$EMAIL_RE" "$text" > "$WORK/g_mail"
    awk -F: -v legal="$LEGAL_CONTACTS" -v extra="$extra" -v allowed="$allowed" '
        BEGIN {
            while ((getline l < legal) > 0) ok_addr[l] = 1
            while ((getline l < extra) > 0) ok_addr[l] = 1
            while ((getline a < allowed) > 0) skip[a] = 1
        }
        {
            idx = $1; addr = tolower(substr($0, length(idx) + 2))
            if (idx in skip || addr in ok_addr) next
            if (addr == "noreply@anthropic.com" || addr == "noreply@github.com") next
            dom = addr; sub(/^.*@/, "", dom)
            if (dom ~ /(^|\.)example\.(com|org|net)$/) next
            if (dom ~ /(^|\.)aiwatchtowers\.com$/) next
            if (dom == "users.noreply.github.com") next
            if (dom ~ /\.(test|example|invalid|localhost|local)$/) next
            if (dom ~ /^[a-z]\.[a-z]+$/) next   # x.com, a.io: obvious fixtures
            print idx " email outside the allowed domains"
        }' "$WORK/g_mail" >> "$cand"

    sort -t ' ' -k1,1n -k2 -u "$cand" > "$WORK/idx"
    awk -F '\t' -v label="$label" '
        NR == FNR { loc[FNR] = $1 ":" $2; next }
        {
            sp = index($0, " ")
            print label loc[substr($0, 1, sp - 1)] ": " substr($0, sp + 1)
        }' "$added" "$WORK/idx" >> "$HITS"
}

# git_to <file> <git args...> — runs git into a file; a git failure is fatal.
git_to() {
    local out="$1"; shift
    git -c core.quotePath=false "$@" > "$out" || fail "git $1 failed"
}

DIFF="$WORK/diff"
case "$1" in
    -h|--help) usage ;;
    --staged)
        git_to "$DIFF" diff --cached --no-color --no-ext-diff -M -U0
        extract_added < "$DIFF" > "$WORK/added"
        scan_added "" ;;
    -)
        cat > "$DIFF"
        extract_added < "$DIFF" > "$WORK/added"
        scan_added "" ;;
    *)
        range="$1"
        case "$range" in
            *...*) range="${range%%...*}..${range#*...}" ;;
            *..*) ;;
            *) echo "leak-check: expected a range A..B or A...B, got '$range'" >&2; exit 2 ;;
        esac
        git_to "$WORK/commits" rev-list --parents --reverse "$range"
        while read -r c parents; do
            label="$(git rev-parse --short "$c") " || fail "git rev-parse failed"
            case "$parents" in
                *' '*)
                    git_to "$DIFF" diff-tree --cc -p -U0 --no-color --no-ext-diff --no-commit-id "$c"
                    extract_added_cc < "$DIFF" > "$WORK/added" ;;
                *)
                    git_to "$DIFF" diff-tree --root -p -r -M -U0 --no-color --no-ext-diff --no-commit-id "$c"
                    extract_added < "$DIFF" > "$WORK/added" ;;
            esac
            scan_added "$label"

            # The message and the identities travel with the commit too.
            git_to "$WORK/msg" log -1 --format=%B "$c"
            awk '{ printf "<commit message>\t%d\t%s\n", NR, $0 }' "$WORK/msg" > "$WORK/added"
            scan_added "$label"
            git_to "$WORK/ident" log -1 --format='<author>%x09%an <%ae>%n<committer>%x09%cn <%ce>' "$c"
            awk -F '\t' '{ printf "%s\t1\t%s\n", $1, $2 }' "$WORK/ident" > "$WORK/added"
            scan_added "$label" "$KNOWN_AUTHORS"
        done < "$WORK/commits"
        ;;
esac

if [ -s "$HITS" ]; then
    echo "leak-check: live-install data in added lines:" >&2
    cat "$HITS" >&2
    echo "leak-check: replace it with a placeholder (see 'Public repo hygiene' in CLAUDE.md); a deliberate fake may carry '$ALLOW_MARKER' (generic rules only)." >&2
    exit 1
fi
echo "leak-check: clean"

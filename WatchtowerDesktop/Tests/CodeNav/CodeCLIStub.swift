import Darwin
import Foundation
import XCTest
@testable import WatchtowerDesktop

/// A fake `watchtower` for the code-navigation centers: `code index --json`
/// lists `STUB_FILES` (after `STUB_FULL_DELAY` seconds) or fails with
/// `STUB_FAIL` on stderr; `code index --serve` answers each request line
/// after `STUB_SERVE_DELAY` seconds with one symbol `r<N>` (N = request
/// number) per path — `dist/…` comes back skipped (git-ignored), `*.txt`
/// as an unsupported language; `code search` prints one match then sleeps.
/// A `--rules` file whose first line starts with "invalid" is read once per
/// process, as the CLI does: every done line of that process carries
/// `rules_error` "<path>: invalid YAML". Every
/// start ("start <pid> <args>") and request ("request <N>\t<paths>") is
/// logged, so a test counts runs and reaps every process group it saw.
struct CodeCLIStub {
    let directory: URL
    let executable: URL
    let log: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("code-cli-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("watchtower")
        log = directory.appendingPathComponent("calls.log")
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        FileManager.default.createFile(atPath: log.path, contents: Data())
    }

    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "STUB_LOG": log.path].merging(extra) { $1 }
    }

    private var lines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// How many `code index --json` runs started.
    var fullRuns: Int {
        lines.filter { $0.hasPrefix("start ") && $0.hasSuffix("--json") }.count
    }

    /// The log's events in order: "full" for a finished full run,
    /// "request" for a `--serve` request.
    var events: [String] {
        lines.compactMap { line in
            if line == "full done" { return "full" }
            return line.hasPrefix("request ") ? "request" : nil
        }
    }

    /// Each `--serve` request's paths, in order.
    var requests: [[String]] {
        lines.filter { $0.hasPrefix("request ") }.map { line in
            line.split(separator: "\t").dropFirst().map(String.init)
        }
    }

    /// The arguments of each `code index --serve` started, in order.
    var serveStarts: [String] {
        lines.filter { $0.hasPrefix("start ") && $0.hasSuffix("--serve") }
    }

    var startedPIDs: [pid_t] {
        lines.filter { $0.hasPrefix("start ") }.compactMap { pid_t($0.split(separator: " ")[1]) }
    }

    /// Every process group the stub started is gone within `timeout`; a
    /// survivor is killed (so a failing test leaves nothing behind) and
    /// reported.
    func assertAllGroupsReaped(timeout: Duration = .seconds(3), file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        var alive = startedPIDs.filter { killpg($0, 0) == 0 }
        while !alive.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            alive = alive.filter { killpg($0, 0) == 0 }
        }
        for pid in alive { killpg(pid, SIGKILL) }
        XCTAssertEqual(alive, [], "stub process groups left running", file: file, line: line)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
    #!/bin/sh
    echo "start $$ $*" >> "$STUB_LOG"
    rest='"line":1,"col":1,"end_line":1,"container":"","signature":"","doc":"","lang":"swift"'
    rules=""
    prev=""
    for a in "$@"; do
        [ "$prev" = "--rules" ] && rules="$a"
        prev="$a"
    done
    rerr=""
    if [ -n "$rules" ] && head -n 1 "$rules" 2>/dev/null | grep -q '^invalid'; then
        rerr=',"rules_error":"'"$rules"': invalid YAML"'
    fi
    case "$*" in
    *"code search"*)
        echo '{"path":"a.swift","line":1,"col":1,"text":"hit","text_col":1,"before":[],"after":[]}'
        sleep 30
        exit 0 ;;
    *--serve*)
        n=0
        while IFS= read -r line; do
            n=$((n + 1))
            printf 'request %s\t%s\n' "$n" "$line" >> "$STUB_LOG"
            sleep "${STUB_SERVE_DELAY:-0}"
            printf '%s\n' "$line" | tr '\t' '\n' | while IFS= read -r p; do
                case "$p" in
                dist/*) printf '{"file":"%s","lang":"","symbols":[],"skipped":true}\n' "$p" ;;
                *.txt) printf '{"file":"%s","lang":"","symbols":[]}\n' "$p" ;;
                *) printf '{"file":"%s","lang":"swift","symbols":[{"name":"r%s","kind":"function","path":"%s",%s}]}\n' "$p" "$n" "$p" "$rest" ;;
                esac
            done
            echo '{"done":true,"files":1,"symbols":1,"ms":1'"$rerr"'}'
        done
        exit 0 ;;
    esac
    if [ -n "$STUB_FAIL" ]; then
        echo "$STUB_FAIL" >&2
        exit 2
    fi
    sleep "${STUB_FULL_DELAY:-0}"
    for f in ${STUB_FILES:-}; do
        printf '{"file":"%s","lang":"swift","symbols":[{"name":"full","kind":"class","path":"%s",%s}]}\n' "$f" "$f" "$rest"
    done
    echo '{"done":true,"files":2,"symbols":2,"ms":1'"$rerr"'}'
    echo "full done" >> "$STUB_LOG"
    """#
}

extension CodeIndexCenter {
    /// A rules file for tests that do not care about it: one temp folder per
    /// test process, so a shown center never creates or watches the real
    /// Application Support folder.
    static let testRulesFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("code-rules-tests-\(ProcessInfo.processInfo.processIdentifier)/code-languages.yaml")
}

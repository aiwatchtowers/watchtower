// Headless check of the Files pane's editor page (CodeEditorWeb/index.html)
// and of the Monarch grammars in CodeEditorWeb/languages.js. Run through
// scripts/editor-bridge-check.sh, which compiles this file and passes the
// CodeEditorWeb folder; it needs the Monaco build from scripts/fetch-monaco.sh.
//
// The page is driven the way MonacoEditorView.Coordinator drives it
// (WatchtowerDesktop/Sources/Views/Workbench/CodeFilesPaneView.swift):
// served under wtcode://editor/, calls as `wt.fn(<JSON argument>)` through
// evaluateJavaScript, `wt.takePending()` read back as [[String: Any]], and
// the page's posts received on the "wt" message handler. "Typing" is a
// model edit made from the harness, which fires the same change listener a
// keystroke does.
//
// Manual tool, not part of any gate. Prints PASS/FAIL per check and exits
// non-zero on any failure.

import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

// MARK: - Page plumbing

/// Mirrors CodeEditorSchemeHandler in
/// WatchtowerDesktop/Sources/Views/Workbench/CodeFilesPaneView.swift (served
/// from a folder instead of the app bundle) — keep the two in step.
final class FolderSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let file = root.appendingPathComponent(String(url.path.drop { $0 == "/" })).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)]
        ) {
            task.didReceive(response)
        }
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

struct TextMessage {
    let id: String
    let text: String
    let base: Int
    let now: Bool
    let explicit: Bool
}

@MainActor
final class Page: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var ready = false
    var texts: [TextMessage] = []
    var errors: [String] = []
    var loadError: String?

    init(root: URL) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(FolderSchemeHandler(root: root), forURLScheme: "wtcode")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        config.userContentController.add(self, name: "wt")
        webView.navigationDelegate = self
    }

    func load() {
        webView.load(URLRequest(url: URL(string: "wtcode://editor/index.html")!))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
        case "text":
            // Decoded exactly as the Coordinator does; a malformed post is an error here.
            guard let id = body["id"] as? String, let text = body["text"] as? String, let base = body["base"] as? Int else {
                errors.append("malformed text message: \(body)")
                return
            }
            texts.append(TextMessage(
                id: id, text: text, base: base,
                now: body["now"] as? Bool ?? false, explicit: body["explicit"] as? Bool ?? false
            ))
        case "error":
            errors.append((body["message"] as? String) ?? "error without a message")
        default:
            errors.append("unknown message type \(type)")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loadError = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadError = "the web content process terminated"
    }

    /// evaluateJavaScript in its completion-handler form — the form the
    /// Coordinator's `call` uses. An error is recorded and fails the run's
    /// last check (in the app it would land in `editorErrors`). The harness's
    /// own probe scripts end in a value.
    func eval(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error { self?.errors.append("evaluateJavaScript: \(error.localizedDescription) — \(script.prefix(80))") }
                continuation.resume(returning: result)
            }
        }
    }

    /// The Coordinator's `call`: `fn(arg)` with the argument JSON-encoded,
    /// through the completion-handler evaluateJavaScript, nothing appended.
    func call(_ function: String, _ argument: Any) async {
        _ = await eval("\(function)(\(jsonArgument(argument)))")
    }

    /// The Coordinator's `takePending(from:)`: the async throwing
    /// evaluateJavaScript, the result read as [[String: Any]].
    func takePending() async -> [(id: String, text: String, base: Int)] {
        let raw: [[String: Any]]
        do {
            raw = try await webView.evaluateJavaScript("wt.takePending()") as? [[String: Any]] ?? []
        } catch {
            errors.append("wt.takePending failed: \(error.localizedDescription)")
            return []
        }
        return raw.compactMap { item in
            guard let id = item["id"] as? String, let text = item["text"] as? String, let base = item["base"] as? Int else {
                errors.append("malformed takePending item: \(item)")
                return nil
            }
            return (id, text, base)
        }
    }

    func evalString(_ script: String) async -> String? { await eval(script) as? String }
    func evalInt(_ script: String) async -> Int? { await eval(script) as? Int }
}

// MARK: - Harness helpers injected into the page

let helpers = #"""
window.__h = {
  model: function (id) {
    return monaco.editor.getModels().filter(function (m) { return m.uri.path.indexOf("/" + id + "/") === 0; })[0] || null;
  },
  type: function (id, text) {
    var m = __h.model(id);
    if (!m) { return false; }
    var end = m.getFullModelRange().getEndPosition();
    m.applyEdits([{ range: new monaco.Range(end.lineNumber, end.column, end.lineNumber, end.column), text: text }]);
    return true;
  },
  value: function (id) { var m = __h.model(id); return m ? m.getValue() : null; },
  lang: function (id) { var m = __h.model(id); return m ? m.getLanguageId() : null; },
  eol: function (id) { var m = __h.model(id); return m ? m.getEOL() : null; },
  count: function () { return monaco.editor.getModels().length; },
  onScreen: function () {
    var m = monaco.editor.getEditors()[0].getModel();
    return m ? m.uri.path.split("/")[1] : "";
  },
  detect: function (path, text) {
    var m = monaco.editor.createModel(text, undefined, monaco.Uri.file("/detect/" + path));
    var id = m.getLanguageId();
    m.dispose();
    return id;
  },
  // [type] for each needle: the token covering the needle's first character
  // on its line, with Monarch's ".<language>" postfix dropped.
  tokens: function (text, lang, needles) {
    var lines = text.split("\n");
    var tokens = monaco.editor.tokenize(text, lang);
    return needles.map(function (needle) {
      for (var l = 0; l < lines.length; l++) {
        var col = lines[l].indexOf(needle[1]);
        if (needle[0] !== l || col < 0) { continue; }
        var hit = null;
        tokens[l].forEach(function (t) { if (t.offset <= col) { hit = t; } });
        if (!hit) { return "<none>"; }
        var suffix = "." + lang;
        var type = hit.type;
        return type.slice(-suffix.length) === suffix ? type.slice(0, -suffix.length) : type;
      }
      return "<needle not found>";
    });
  }
};
true;
"""#

// MARK: - Checks

var failures = 0
var passes = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passes += 1
        print("PASS  \(name)")
    } else {
        failures += 1
        let more = detail()
        print("FAIL  \(name)\(more.isEmpty ? "" : " — \(more)")")
    }
}

@MainActor
func wait(_ timeout: Double, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

@MainActor
func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// A value as a JavaScript literal: JSON-encoded inside an array, the
/// brackets dropped (the Coordinator's `call` encoding).
func jsonArgument(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
    return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
}

@MainActor
func protocolChecks(_ page: Page) async {
    // show
    await page.call("wt.show", ["id": "a", "path": "main.go", "text": "package main\n", "rev": 1])
    check("show: puts the file on screen", await page.evalString("__h.onScreen()") == "a")
    check("show: language from the path", await page.evalString("__h.lang('a')") == "go")
    check("show: sends no text", page.texts.isEmpty)

    // edit revisions and the 300 ms debounce
    _ = await page.eval("__h.type('a', 'x'); true")
    await pause(0.1)
    check("edit: nothing sent before the debounce", page.texts.isEmpty)
    let sent = await wait(3) { page.texts.count == 1 }
    let first = page.texts.first
    check("edit: sent after the debounce", sent && first?.id == "a" && first?.text == "package main\nx",
          "\(page.texts)")
    check("edit: tagged with the shown revision, not now/explicit",
          first?.base == 1 && first?.now == false && first?.explicit == false, "\(String(describing: first))")
    page.texts.removeAll()

    // takePending
    _ = await page.eval("__h.type('a', 'y'); true")
    let taken = await page.takePending()
    check("takePending: hands over the unsent edit",
          taken.count == 1 && taken.first?.id == "a" && taken.first?.text == "package main\nxy" && taken.first?.base == 1,
          "\(taken)")
    await pause(0.6)
    check("takePending: the handed-over edit is not sent again", page.texts.isEmpty, "\(page.texts)")
    check("takePending: nothing left after", await page.takePending().isEmpty)

    // reload replace, nothing unsent
    await page.call("wt.reload", ["id": "a", "text": "package disk\n", "rev": 2, "mode": "replace"])
    check("reload replace: takes the disk text", await page.evalString("__h.value('a')") == "package disk\n")
    await pause(0.5)
    check("reload replace: sends no text", page.texts.isEmpty, "\(page.texts)")
    _ = await page.eval("__h.type('a', 'z'); true")
    let rebased = await page.takePending()
    check("reload replace: the next edit carries the new revision", rebased.first?.base == 2, "\(rebased)")

    // reload replace with an unsent edit: the edit goes out on its old base and is kept
    _ = await page.eval("__h.type('a', 'q'); true")
    await page.call("wt.reload", ["id": "a", "text": "package other\n", "rev": 3, "mode": "replace"])
    check("reload replace + unsent edit: sends it at once on its old base",
          page.texts.count == 1 && page.texts.first?.base == 2 && page.texts.first?.now == true
              && page.texts.first?.text == "package disk\nzq",
          "\(page.texts)")
    check("reload replace + unsent edit: keeps the edit", await page.evalString("__h.value('a')") == "package disk\nzq")
    page.texts.removeAll()
    _ = await page.eval("__h.type('a', '1'); true")
    let stillOld = await page.takePending()
    check("reload replace + unsent edit: keeps the old base", stillOld.first?.base == 2, "\(stillOld)")

    // reload force with an unsent edit: the disk wins, nothing is sent
    _ = await page.eval("__h.type('a', '2'); true")
    await page.call("wt.reload", ["id": "a", "text": "package forced\n", "rev": 4, "mode": "force"])
    check("reload force: takes the text over an unsent edit", await page.evalString("__h.value('a')") == "package forced\n")
    await pause(0.5)
    check("reload force: sends nothing", page.texts.isEmpty, "\(page.texts)")
    check("reload force: drops the unsent edit", await page.takePending().isEmpty)
    _ = await page.eval("__h.type('a', '3'); true")
    let forced = await page.takePending()
    check("reload force: the next edit carries the new revision", forced.first?.base == 4, "\(forced)")

    // reload rebase with an unsent edit: text kept, new base, sent at once
    _ = await page.eval("__h.type('a', '4'); true")
    await page.call("wt.reload", ["id": "a", "text": "ignored\n", "rev": 5, "mode": "rebase"])
    check("reload rebase: keeps the text", await page.evalString("__h.value('a')") == "package forced\n34")
    check("reload rebase: sends the unsent edit at once on the new base",
          page.texts.count == 1 && page.texts.first?.base == 5 && page.texts.first?.now == true
              && page.texts.first?.text == "package forced\n34",
          "\(page.texts)")
    page.texts.removeAll()

    // reload rebase, nothing unsent
    await page.call("wt.reload", ["id": "a", "text": "ignored\n", "rev": 6, "mode": "rebase"])
    await pause(0.5)
    check("reload rebase (nothing unsent): sends nothing", page.texts.isEmpty, "\(page.texts)")
    _ = await page.eval("__h.type('a', '5'); true")
    let rebasedAgain = await page.takePending()
    check("reload rebase (nothing unsent): the next edit carries the new revision",
          rebasedAgain.first?.base == 6, "\(rebasedAgain)")

    // reload of an unknown id is ignored
    let before = await page.evalInt("__h.count()")
    await page.call("wt.reload", ["id": "nope", "text": "x", "rev": 1, "mode": "force"])
    check("reload: an unknown id is ignored", await page.evalInt("__h.count()") == before && page.errors.isEmpty)

    // tab switch flushes the previous file's edit with now
    _ = await page.eval("__h.type('a', '6'); true")
    await page.call("wt.show", ["id": "b", "path": "notes.toml", "text": "a = 1\r\nb = 2\r\n", "rev": 7])
    check("show (switch): sends the previous file's edit at once",
          page.texts.count == 1 && page.texts.first?.id == "a" && page.texts.first?.now == true, "\(page.texts)")
    page.texts.removeAll()
    check("show (switch): the new file is on screen", await page.evalString("__h.onScreen()") == "b")
    check("show: keeps CRLF line endings", await page.evalString("__h.eol('b')") == "\r\n")
    _ = await page.eval("__h.type('b', 'c = 3\\r\\n'); true")
    let crlf = await page.takePending()
    check("edit: CRLF text comes back as CRLF", crlf.first?.text == "a = 1\r\nb = 2\r\nc = 3\r\n", "\(crlf)")

    // switching back reuses the model (undo, cursor and scroll survive)
    let models = await page.evalInt("__h.count()")
    await page.call("wt.show", ["id": "a", "path": "main.go", "text": "stale text Swift holds\n", "rev": 1])
    let backText = await page.evalString("__h.value('a')")
    let backCount = await page.evalInt("__h.count()")
    check("show (back): reuses the model, keeps its text over what show sent",
          backText == "package forced\n3456" && backCount == models, "\(String(describing: backText)), \(String(describing: backCount)) models")
    _ = await page.eval("__h.type('a', '7'); true")
    let reused = await page.takePending()
    check("show (back): the model keeps its revision", reused.first?.base == 6, "\(reused)")

    // explicit save (Cmd+S) and blur
    _ = await page.eval("""
        (function () {
          var e = monaco.editor.getEditors()[0];
          e.focus();
          var target = e.getContainerDomNode().querySelector('textarea') || document.activeElement;
          target.dispatchEvent(new KeyboardEvent('keydown', { key: 's', code: 'KeyS', keyCode: 83, metaKey: true, bubbles: true, cancelable: true }));
          return true;
        })()
        """)
    let saved = await wait(1) { !page.texts.isEmpty }
    check("Cmd+S: sends the file on screen at once, explicit",
          saved && page.texts.first?.id == "a" && page.texts.first?.now == true && page.texts.first?.explicit == true,
          "\(page.texts)")
    page.texts.removeAll()
    _ = await page.eval("__h.type('b', 'd = 4'); __h.type('a', '8'); window.dispatchEvent(new Event('blur')); true")
    let flushedIDs = Set(page.texts.map(\.id))
    check("blur: sends every unsent edit at once",
          flushedIDs == ["a", "b"] && page.texts.allSatisfy { $0.now && !$0.explicit }, "\(page.texts)")
    page.texts.removeAll()

    // rename: new language, same model, the probe model is disposed
    let countBeforeRename = await page.evalInt("__h.count()")
    await page.call("wt.rename", ["id": "a", "path": "build/Makefile"])
    check("rename: the language follows the new name", await page.evalString("__h.lang('a')") == "makefile")
    let renamedText = await page.evalString("__h.value('a')")
    let renamedCount = await page.evalInt("__h.count()")
    check("rename: keeps the text and leaves no probe model",
          renamedText == "package forced\n345678" && renamedCount == countBeforeRename,
          "\(String(describing: renamedText)), \(String(describing: renamedCount)) models")
    await page.call("wt.rename", ["id": "b", "path": ".env.local"])
    check("rename: a file off screen changes language too", await page.evalString("__h.lang('b')") == "dotenv")

    // text that would break hand-escaping survives the JSON-encoded call
    let tricky = "quote \" backslash \\ </script> \u{2028} line sep, emoji \u{1F600}, tab\t\n"
    await page.call("wt.show", ["id": "c", "path": "tricky.txt", "text": tricky, "rev": 1])
    check("show: arbitrary text round-trips through the JSON-encoded call",
          await page.evalString("__h.value('c')") == tricky)

    // close
    _ = await page.eval("__h.type('b', 'e'); true")
    let countBeforeClose = await page.evalInt("__h.count()") ?? 0
    await page.call("wt.close", "b")
    check("close: sends the closing file's unsent edit at once",
          page.texts.count == 1 && page.texts.first?.id == "b" && page.texts.first?.now == true, "\(page.texts)")
    page.texts.removeAll()
    let closedCount = await page.evalInt("__h.count()")
    let closedGone = await page.eval("__h.model('b') === null") as? Bool
    check("close: disposes the model", closedCount == countBeforeClose - 1 && closedGone == true)
    check("close: an off-screen close leaves the screen alone", await page.evalString("__h.onScreen()") == "c")
    await page.call("wt.close", "c")
    check("close: closing the file on screen clears the editor", await page.evalString("__h.onScreen()") == "")
    await page.call("wt.close", "never-opened")
    check("close: an unknown id is harmless", page.errors.isEmpty, "\(page.errors)")
    check("close: nothing pending afterwards", await page.takePending().isEmpty)

    // reopening a closed id starts fresh from what Swift sends
    await page.call("wt.show", ["id": "b", "path": ".env.local", "text": "FRESH=1\n", "rev": 9])
    check("show after close: a new model with the given text", await page.evalString("__h.value('b')") == "FRESH=1\n")
    _ = await page.eval("__h.type('b', 'x'); true")
    let fresh = await page.takePending()
    check("show after close: the new model carries the given revision", fresh.first?.base == 9, "\(fresh)")

    // show(null)
    _ = await page.eval("__h.type('b', 'y'); true")
    await page.call("wt.show", NSNull())
    check("show(null): clears the editor", await page.evalString("__h.onScreen()") == "")
    check("show(null): keeps the model", await page.evalString("__h.value('b')") == "FRESH=1\nxy")
    let afterNull = await page.takePending()
    check("show(null): an unsent edit stays pending", afterNull.count == 1 && afterNull.first?.id == "b", "\(afterNull)")
    await page.call("wt.close", "b")
    await page.call("wt.close", "a")
    page.texts.removeAll()
}

@MainActor
func detectionChecks(_ page: Page) async {
    let cases: [(path: String, text: String, expected: String)] = [
        (".zshrc", "", "shell"),
        ("tool", "#!/bin/bash\necho hi\n", "shell"),
        ("tool", "#!/usr/bin/env python3\nprint(1)\n", "python"),
        ("tool", "#!/usr/bin/env node\n", "javascript"),
        ("Podfile", "", "ruby"),
        ("Info.plist", "", "xml"),
        ("app.entitlements", "", "xml"),
        ("settings.jsonc", "", "json"),
        ("Dockerfile.dev", "", "dockerfile"),
        ("Jenkinsfile", "", "java"),
        (".env", "", "dotenv"),
        (".env.production", "", "dotenv"),
        ("Makefile", "", "makefile"),
        ("rules.mk", "", "makefile"),
        ("Cargo.lock", "", "toml"),
        ("pyproject.toml", "", "toml"),
        (".gitignore", "", "ignore"),
        ("CODEOWNERS", "", "ignore"),
        ("go.mod", "", "gomod"),
        ("go.sum", "", "gomod"),
        ("fix.patch", "", "diff"),
        ("server.log", "", "log"),
        ("server.log.1", "", "log"),
        ("data.csv", "", "csv"),
        ("data.tsv", "", "tsv")
    ]
    for item in cases {
        let got = await page.evalString("__h.detect(\(jsonArgument(item.path)), \(jsonArgument(item.text)))")
        let shebang = item.text.hasPrefix("#!") ? " (\(item.text.split(separator: "\n")[0]))" : ""
        check("language: \(item.path)\(shebang) → \(item.expected)", got == item.expected, "got \(got ?? "nil")")
    }
}

@MainActor
func tokenChecks(_ page: Page) async {
    // (language, sample, [(line, needle, expected token class)])
    let samples: [(String, String, [(Int, String, String)])] = [
        ("dotenv", "export API_KEY=\"x${HOME}\" # note\nPORT=8080\nDEBUG=true\n", [
            (0, "export", "keyword"), (0, "API_KEY", "variable"), (0, "=", "delimiter"),
            (0, "${HOME}", "variable.predefined"), (0, "# note", "comment"),
            (1, "8080", "number"), (2, "true", "keyword")
        ]),
        ("makefile", "CC := clang\n.PHONY: build\nbuild: main.o\n\t@echo $(CC) $@\n# note\n", [
            (0, "CC", "variable"), (0, ":=", "operator"), (1, ".PHONY", "keyword"),
            (2, "build", "type"), (3, "@", "keyword"), (3, "echo", "keyword"),
            (3, "$(", "variable.predefined"), (3, "$@", "variable.predefined"), (4, "# note", "comment")
        ]),
        ("toml", "[package]\nname = \"wt\" # c\nversion = 1.5\nok = true\nwhen = 2026-01-02\n", [
            (0, "[package]", "type"), (1, "name", "variable"), (1, "\"wt\"", "string"), (1, "# c", "comment"),
            (2, "1.5", "number"), (3, "true", "keyword"), (4, "2026-01-02", "number")
        ]),
        ("ignore", "# c\n!keep.txt\n**/*.log\n[ab].tmp\n/docs @team\n", [
            (0, "# c", "comment"), (1, "!", "keyword"), (2, "**", "keyword"),
            (3, "[ab]", "regexp"), (4, "@team", "type")
        ]),
        ("gomod", "module example.com/x\n\ngo 1.25\nrequire example.com/y v1.2.3 // indirect\n", [
            (0, "module", "keyword"), (0, "example.com/x", "string"), (2, "1.25", "number"),
            (3, "v1.2.3", "number"), (3, "// indirect", "comment")
        ]),
        ("diff", "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@ func\n-old\n+new\n context\n", [
            (0, "diff", "diff.meta"), (1, "---", "diff.meta"), (2, "+++", "diff.meta"),
            (3, "@@ -1 +1 @@", "diff.hunk"), (3, " func", "comment"),
            (4, "-old", "deleted"), (5, "+new", "inserted"), (6, " context", "")
        ]),
        ("log", "2026-01-02 03:04:05 ERROR failed user=a\nWarning: low\nINFO ok\ndebug 42\n", [
            (0, "2026-01-02", "log.date"), (0, "ERROR", "log.error"), (0, "user", "variable"),
            (1, "Warning", "log.warn"), (2, "INFO", "log.info"), (3, "debug", "log.debug"), (3, "42", "number")
        ]),
        ("csv", "a,b,c,d,e,f,g\n1,\"x,y\",3\n", [
            (0, "a", "csv.c0"), (0, ",", "delimiter"), (0, "b", "csv.c1"), (0, "c", "csv.c2"),
            (0, "f", "csv.c5"), (0, "g", "csv.c0"), (1, "1", "csv.c0"), (1, "\"x,y\"", "csv.c1"), (1, "3", "csv.c2")
        ]),
        ("tsv", "a\tb\tc\n1\t2\n", [
            (0, "a", "csv.c0"), (0, "\t", "delimiter"), (0, "b", "csv.c1"), (0, "c", "csv.c2"), (1, "1", "csv.c0")
        ])
    ]
    for (language, sample, needles) in samples {
        let array = needles.map { "[\($0.0), \(jsonArgument($0.1))]" }.joined(separator: ", ")
        let got = await page.eval("__h.tokens(\(jsonArgument(sample)), \(jsonArgument(language)), [\(array)])") as? [String] ?? []
        for (index, needle) in needles.enumerated() {
            let actual = index < got.count ? got[index] : "<missing>"
            let shown = needle.1.replacingOccurrences(of: "\t", with: "\\t")
            check("tokens \(language): \"\(shown)\" → \(needle.2.isEmpty ? "(plain)" : needle.2)",
                  actual == needle.2, "got \(actual.isEmpty ? "(plain)" : actual)")
        }
    }
    // setTheme falls back silently on an unknown name, so a theme counts as
    // defined only when Monaco's generated token colours include a colour
    // that only its extraRules in languages.js set.
    for (theme, colour) in [("wt-dark", "#85e89d"), ("wt-light", "#22863a")] {
        let css = await page.evalString("""
            (function () {
              monaco.editor.setTheme(\(jsonArgument(theme)));
              return Array.prototype.map.call(document.querySelectorAll('style'), function (s) {
                return s.textContent.indexOf('.mtk') >= 0 ? s.textContent : '';
              }).join('').toLowerCase();
            })()
            """) ?? ""
        check("themes: \(theme) is defined (its diff colour \(colour) is in the token colours)",
              css.contains(colour), css.isEmpty ? "no token colour style found" : "colour absent")
    }
}

// MARK: - Main

@MainActor
func run(root: URL) async -> Int32 {
    let page = Page(root: root)
    page.load()
    let loaded = await wait(30) { page.ready || page.loadError != nil || !page.errors.isEmpty }
    guard loaded, page.ready else {
        print("FAIL  page load — \(page.loadError ?? page.errors.first ?? "no ready message within 30 s")")
        return 1
    }
    check("page load: posts ready with no error", page.errors.isEmpty, "\(page.errors)")
    _ = await page.eval(helpers)

    await protocolChecks(page)
    await detectionChecks(page)
    await tokenChecks(page)

    check("no error posted by the page during the run", page.errors.isEmpty, page.errors.joined(separator: "; "))
    print("\n\(passes) passed, \(failures) failed")
    return failures == 0 ? 0 : 1
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: editor-bridge-check <CodeEditorWeb folder>\n", stderr)
    exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
// A page that stops answering must not hang the run.
DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
    print("FAIL  the run did not finish within 180 s")
    exit(1)
}
Task { @MainActor in
    let code = await run(root: root)
    exit(code)
}
app.run()

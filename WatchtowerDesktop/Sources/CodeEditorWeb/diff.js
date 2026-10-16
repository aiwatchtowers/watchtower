// The Changes pane's diff page code (see the protocol at the top of
// diff.html). Kept out of diff.html: the page's CSP allows no inline script.
(function () {
  "use strict";
  // vs/loader.js did not load: the Monaco build is not installed.
  if (typeof require === "undefined") {
    document.getElementById("missing").style.display = "block";
    post({ type: "error", message: "Monaco is not installed" });
    return;
  }
  require.config({ paths: { vs: "vs" } });
  require(["vs/editor/editor.main"], function () {
    registerExtraLanguages();

    // The TypeScript worker is trimmed from the bundle (fetch-monaco.sh):
    // switch the TS/JS language service off so nothing asks for it.
    var ts = (monaco.typescript || (monaco.languages && monaco.languages.typescript));
    if (ts) {
      [ts.typescriptDefaults, ts.javascriptDefaults].forEach(function (d) {
        if (d && d.setDiagnosticsOptions) { d.setDiagnosticsOptions({ noSemanticValidation: true, noSyntaxValidation: true }); }
      });
    }

    var dark = window.matchMedia("(prefers-color-scheme: dark)");
    function applyTheme() { monaco.editor.setTheme(dark.matches ? "wt-dark" : "wt-light"); }
    applyTheme();
    dark.addEventListener("change", applyTheme);

    var editor = monaco.editor.createDiffEditor(document.getElementById("diff"), {
      automaticLayout: true, readOnly: true, originalEditable: false, renderSideBySide: true,
      renderOverviewRuler: true, minimap: { enabled: false }, scrollBeyondLastLine: false,
      fontFamily: "SF Mono, Menlo, monospace", fontSize: 12
    });
    var zones = [];
    var noteZones = [];
    var hunkZones = [];
    var models = { original: null, modified: null };
    // Each showDiff gets fresh model URIs: the language follows the path,
    // and a disposed model's URI is never reused.
    var serial = 0;

    function lineCount(text) { return String(text || "").split("\n").length; }

    function renderComments(list) {
      var mod = editor.getModifiedEditor();
      mod.changeViewZones(function (acc) {
        zones.forEach(function (z) { acc.removeZone(z); });
        zones = [];
        (list || []).forEach(function (c) {
          var node = document.createElement("div");
          node.className = "wt-comment wt-" + c.status;
          var body = document.createElement("div");
          body.textContent = c.body;           // textContent only: never HTML from the DB
          node.appendChild(body);
          var lines = lineCount(c.body) + 1;
          if (c.reply) {
            var reply = document.createElement("div");
            reply.className = "wt-reply";
            reply.textContent = "Agent: " + c.reply;
            node.appendChild(reply);
            lines += lineCount(c.reply);
          }
          zones.push(acc.addZone({ afterLineNumber: c.endLine, heightInLines: lines, domNode: node }));
        });
      });
    }

    // The agent's notes: a read-only zone above each note's first line.
    function renderNotes(list) {
      var mod = editor.getModifiedEditor();
      mod.changeViewZones(function (acc) {
        noteZones.forEach(function (z) { acc.removeZone(z); });
        noteZones = [];
        (list || []).forEach(function (n) {
          var node = document.createElement("div");
          node.className = "wt-note";
          var label = document.createElement("div");
          label.className = "wt-note-label";
          label.textContent = "Agent note";
          var body = document.createElement("div");
          body.textContent = n.text;           // textContent only: never HTML from the DB
          node.appendChild(label);
          node.appendChild(body);
          noteZones.push(acc.addZone({
            afterLineNumber: Math.max(0, n.startLine - 1), heightInLines: lineCount(n.text) + 1, domNode: node
          }));
        });
      });
    }

    // One line above each hunk with an Undo button; a disabled one carries
    // the reason as its title. The button posts the hunk id only.
    function renderHunks(list) {
      var mod = editor.getModifiedEditor();
      mod.changeViewZones(function (acc) {
        hunkZones.forEach(function (z) { acc.removeZone(z); });
        hunkZones = [];
        (list || []).forEach(function (h) {
          var node = document.createElement("div");
          node.className = "wt-hunk";
          var button = document.createElement("button");
          button.type = "button";
          button.className = "wt-undo";
          button.textContent = "Undo";
          if (h.canUndo) {
            button.addEventListener("click", function () { post({ type: "undo", hunkId: String(h.id) }); });
          } else {
            button.disabled = true;
            button.title = String(h.reason || "");
          }
          node.appendChild(button);
          hunkZones.push(acc.addZone({ afterLineNumber: Math.max(0, h.newStart - 1), heightInLines: 1, domNode: node }));
        });
      });
    }

    function addCommentAction(ed, side) {
      ed.addAction({
        id: "wt.comment", label: "Comment", contextMenuGroupId: "navigation",
        keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyMod.Alt | monaco.KeyCode.KeyM],
        run: function (target) {
          var s = target.getSelection();
          if (!s) { return; }
          // A selection ending at column 1 of a line does not take that line.
          var end = s.endLineNumber > s.startLineNumber && s.endColumn === 1 ? s.endLineNumber - 1 : s.endLineNumber;
          post({ type: "comment", side: side, startLine: s.startLineNumber, endLine: end });
        }
      });
    }
    addCommentAction(editor.getModifiedEditor(), "new");
    addCommentAction(editor.getOriginalEditor(), "old");

    window.wt = {
      showDiff: function (a) {
        var previous = models;
        serial += 1;
        var path = a.path || "file";
        var language = a.language || undefined;
        models = {
          original: monaco.editor.createModel(a.original || "", language, monaco.Uri.file("/old/" + serial + "/" + path)),
          modified: monaco.editor.createModel(a.modified || "", language, monaco.Uri.file("/new/" + serial + "/" + path))
        };
        editor.setModel({ original: models.original, modified: models.modified });
        editor.updateOptions({ renderSideBySide: !a.inline });
        // Disposed only once the editor holds the new pair.
        if (previous.original) { previous.original.dispose(); }
        if (previous.modified) { previous.modified.dispose(); }
        renderComments(a.comments);
        renderNotes(a.notes);
        renderHunks(a.hunks);
      },
      setComments: renderComments,
      setNotes: renderNotes,
      setHunks: renderHunks,
      focus: function () { editor.getModifiedEditor().focus(); }
    };
    post({ type: "ready" });
  }, function (err) {
    post({ type: "error", message: "Monaco failed to load: " + String(err && err.message || err) });
  });
})();

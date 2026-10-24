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
    registerTextMateGrammars();

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
      fontFamily: "SF Mono, Menlo, monospace", fontSize: 12,
      // Changes view (board #959): unchanged runs fold into "N hidden lines"
      // bars; wt.setFullFile(true) shows the whole file.
      hideUnchangedRegions: { enabled: true, contextLineCount: 3, minimumLineCount: 6, revealLineCount: 20 }
    });
    var zones = [];
    var noteZones = [];
    var hunkZones = [];
    var models = { original: null, modified: null };
    // The new-side lines each zone needs on screen, by kind ([[from, to]]).
    var zoneRuns = { comments: [], notes: [], hunks: [] };
    // The cursor is the page's own (set by showDiff or by revealZones), not
    // one the owner placed: revealZones need not put it back.
    var cursorIsOurs = true;
    // Each showDiff gets fresh model URIs: the language follows the path,
    // and a disposed model's URI is never reused.
    var serial = 0;

    function lineCount(text) { return String(text || "").split("\n").length; }

    // A zone's height in editor lines: the node laid out off screen at the
    // editor's content width (its text wraps there), never below the count
    // of its hard lines. The 8px side margins of .wt-comment/.wt-note and
    // their 2px top and bottom margins are taken off and added back.
    function zoneLines(ed, node, minLines) {
      var width = ed.getLayoutInfo().contentWidth - 16;
      var lineHeight = ed.getOption(monaco.editor.EditorOption.lineHeight);
      if (!(width > 0) || !(lineHeight > 0)) { return minLines; }
      var probe = node.cloneNode(true);
      probe.style.position = "absolute";
      probe.style.visibility = "hidden";
      probe.style.left = "-10000px";
      probe.style.top = "0";
      probe.style.width = width + "px";
      document.body.appendChild(probe);
      var height = probe.getBoundingClientRect().height + 4;
      document.body.removeChild(probe);
      return Math.max(minLines, Math.ceil(height / lineHeight));
    }

    // A zone on a folded line would vanish with its line (Review Focus 1).
    // Monaco 0.57 has no API call to unfold one hidden region, but its diff
    // editor unfolds the region holding a line the modified editor's cursor
    // is set to (any reason other than a model swap): that is the public
    // way taken here, so the Full-file fallback of the plan is not needed.
    // Each line of a zone's run is revealed; the owner's own selection, if
    // there is one, is put back afterwards.
    function revealZones() {
      var mod = editor.getModifiedEditor();
      var model = mod.getModel();
      if (!model) { return; }
      var last = model.getLineCount();
      var saved = cursorIsOurs ? null : mod.getSelections();
      ["comments", "notes", "hunks"].forEach(function (kind) {
        zoneRuns[kind].forEach(function (run) {
          for (var line = Math.max(1, run[0]); line <= Math.min(last, run[1]); line++) {
            mod.setPosition({ lineNumber: line, column: 1 });
          }
        });
      });
      if (saved) { mod.setSelections(saved); }
    }
    editor.getModifiedEditor().onDidChangeCursorSelection(function (e) {
      // 3 = CursorChangeReason.Explicit: the owner's click or keys.
      if (e.reason === 3) { cursorIsOurs = false; }
    });
    // A focus(line) sent before the shown diff is computed waits for it:
    // the fold computed then would hide the line again.
    var pendingFocus = 0;
    function applyFocus() {
      var mod = editor.getModifiedEditor();
      var line = pendingFocus;
      pendingFocus = 0;
      mod.setPosition({ lineNumber: line, column: 1 });
      cursorIsOurs = false;
      mod.revealLineInCenter(line);
    }
    // A new or recomputed diff folds afresh.
    editor.onDidUpdateDiff(function () {
      revealZones();
      if (pendingFocus > 0) { applyFocus(); }
    });

    function renderComments(list) {
      var mod = editor.getModifiedEditor();
      // The commented lines and the line under them, where the zone sits.
      zoneRuns.comments = (list || []).map(function (c) { return [c.startLine, c.endLine + 1]; });
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
          zones.push(acc.addZone({ afterLineNumber: c.endLine, heightInLines: zoneLines(mod, node, lines), domNode: node }));
        });
      });
    }

    // The agent's notes: a read-only zone above each note's first line.
    function renderNotes(list) {
      var mod = editor.getModifiedEditor();
      // The zone sits after startLine - 1, above the noted lines.
      zoneRuns.notes = (list || []).map(function (n) { return [n.startLine - 1, n.endLine]; });
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
            afterLineNumber: Math.max(0, n.startLine - 1), heightInLines: zoneLines(mod, node, lineCount(n.text) + 1), domNode: node
          }));
        });
      });
    }

    // One line above each hunk with an Undo button; a disabled one carries
    // the reason as its title. The button posts the hunk id only.
    function renderHunks(list) {
      var mod = editor.getModifiedEditor();
      // A hunk's first line is a context line; its zone sits on the one above.
      zoneRuns.hunks = (list || []).map(function (h) { return [h.newStart - 1, h.newStart]; });
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

    // Ask agent (board #962): the selection's lines go to Swift, which
    // quotes them into the session's Workchat draft.
    function addAskAction(ed, side) {
      ed.addAction({
        id: "wt.ask", label: "Ask agent", contextMenuGroupId: "navigation",
        keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyA],
        run: function (target) {
          var s = target.getSelection();
          if (!s) { return; }
          // A selection ending at column 1 of a line does not take that line.
          var end = s.endLineNumber > s.startLineNumber && s.endColumn === 1 ? s.endLineNumber - 1 : s.endLineNumber;
          post({ type: "ask", side: side, startLine: s.startLineNumber, endLine: end });
        }
      });
    }
    addAskAction(editor.getModifiedEditor(), "new");
    addAskAction(editor.getOriginalEditor(), "old");

    // Go to definition and Usages on the new side only (board #960,
    // codenav.js): requests name the shown file's path. The old side has no
    // navigation.
    var shownPath = "";
    var nav = wtCodeNav(editor.getModifiedEditor(), function () { return shownPath; }, post);

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
        editor.updateOptions({ renderSideBySide: !a.inline, hideUnchangedRegions: { enabled: !a.fullFile } });
        cursorIsOurs = true;
        // A new file: its path names the requests; the old one's marks go.
        shownPath = a.path || "";
        nav.clear();
        // A focus waiting for the previous file's diff is not this file's.
        pendingFocus = 0;
        // Disposed only once the editor holds the new pair.
        if (previous.original) { previous.original.dispose(); }
        if (previous.modified) { previous.modified.dispose(); }
        renderComments(a.comments);
        renderNotes(a.notes);
        renderHunks(a.hunks);
        // The zones' lines are revealed once the new diff is computed.
      },
      setComments: function (list) { renderComments(list); revealZones(); },
      setNotes: function (list) { renderNotes(list); revealZones(); },
      setHunks: function (list) { renderHunks(list); revealZones(); },
      // Folding back folds every region again: the zones' lines come back.
      setFullFile: function (on) {
        editor.updateOptions({ hideUnchangedRegions: { enabled: !on } });
        if (!on) { revealZones(); }
      },
      // A line in a folded run is unfolded (the cursor goes to it), then
      // centred.
      focus: function (line) {
        var mod = editor.getModifiedEditor();
        if (line > 0) {
          pendingFocus = line;
          // null = the shown pair's diff is not computed yet (board #960).
          if (editor.getLineChanges() !== null) { applyFocus(); }
        }
        mod.focus();
      },
      definitionAtCursor: function () { return nav.definitionAtCursor(); },
      definitionDone: function (req) { nav.definitionDone(req); },
      usagesAtCursor: function () { return nav.usagesAtCursor(); }
    };
    post({ type: "ready" });
  }, function (err) {
    post({ type: "error", message: "Monaco failed to load: " + String(err && err.message || err) });
  });
})();

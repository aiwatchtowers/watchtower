// The editor page's code (see the protocol at the top of index.html). Kept
// out of index.html: the page's CSP allows no inline script.
(function () {
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
    // Highlighting (TextMate grammars, textmate.js) does not need it.
    var ts = (monaco.typescript || (monaco.languages && monaco.languages.typescript));
    if (ts) {
      var off = { completionItems: false, hovers: false, documentSymbols: false, definitions: false,
        references: false, documentHighlights: false, rename: false, diagnostics: false,
        documentRangeFormattingEdits: false, signatureHelp: false, onTypeFormattingEdits: false,
        codeActions: false, inlayHints: false };
      [ts.typescriptDefaults, ts.javascriptDefaults].forEach(function (d) {
        if (!d) { return; }
        if (d.setModeConfiguration) { d.setModeConfiguration(off); }
        if (d.setDiagnosticsOptions) { d.setDiagnosticsOptions({ noSemanticValidation: true, noSyntaxValidation: true }); }
      });
    }

    // The app's navigation chords (spec §10) that Monaco 0.57 binds by
    // default; "-command" removes that command's binding to the chord.
    // scripts/editor-bridge-check.swift asserts none of the chords is left.
    var K = monaco.KeyCode, M = monaco.KeyMod;
    monaco.editor.addKeybindingRules([
      { keybinding: M.CtrlCmd | M.Shift | K.KeyO, command: "-editor.action.quickOutline" },
      { keybinding: M.CtrlCmd | K.KeyI, command: "-editor.action.triggerSuggest" },
      { keybinding: M.CtrlCmd | K.KeyI, command: "-focusSuggestion" },
      { keybinding: M.CtrlCmd | K.KeyI, command: "-toggleSuggestionDetails" },
      { keybinding: M.CtrlCmd | M.Alt | K.Enter, command: "-editor.action.replaceAll" },
      { keybinding: M.CtrlCmd | M.Alt | K.Enter, command: "-quickInput.accept" },
      { keybinding: M.CtrlCmd | M.WinCtrl | K.RightArrow, command: "-quickInput.acceptInBackground" }
    ]);

    var dark = window.matchMedia("(prefers-color-scheme: dark)");
    function applyTheme() { monaco.editor.setTheme(dark.matches ? "wt-dark" : "wt-light"); }
    applyTheme();
    dark.addEventListener("change", applyTheme);

    var editor = monaco.editor.create(document.getElementById("editor"), {
      automaticLayout: true,
      fontFamily: "SF Mono, Menlo, monospace",
      fontSize: 12,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      renderWhitespace: "selection",
      model: null
    });
    var models = {};      // buffer id -> model
    var bases = {};       // buffer id -> disk revision the model was given
    var viewStates = {};  // buffer id -> saved cursor/scroll
    var pending = {};     // buffer id -> debounce timer of an unsent edit
    var current = null;   // buffer id on screen
    var reveals = {};     // buffer id -> {line, col} waiting for its show

    function send(id, now, explicit) {
      clearTimeout(pending[id]);
      delete pending[id];
      var model = models[id];
      if (model) {
        post({ type: "text", id: id, text: model.getValue(), base: bases[id], now: !!now, explicit: !!explicit });
      }
    }

    function flushAll(now) {
      Object.keys(pending).forEach(function (id) { send(id, now, false); });
    }

    function uriFor(id, path) { return monaco.Uri.file("/" + id + "/" + path); }

    function modelFor(args) {
      if (models[args.id]) { return models[args.id]; }
      var model = monaco.editor.createModel(args.text, undefined, uriFor(args.id, args.path));
      model.setEOL(args.text.indexOf("\r\n") >= 0 ? monaco.editor.EndOfLineSequence.CRLF : monaco.editor.EndOfLineSequence.LF);
      model.onDidChangeContent(function () {
        if (model.__replacing) { return; }
        clearTimeout(pending[args.id]);
        pending[args.id] = setTimeout(function () { send(args.id, false, false); }, 300);
      });
      models[args.id] = model;
      bases[args.id] = args.rev;
      return model;
    }

    function revealNow(args) {
      var model = editor.getModel();
      if (!model) { return; }
      var line = Math.min(Math.max(1, args.line | 0), model.getLineCount());
      var col = Math.min(Math.max(1, args.col | 0), model.getLineMaxColumn(line));
      editor.setPosition({ lineNumber: line, column: col });
      editor.revealPositionInCenter({ lineNumber: line, column: col });
    }

    function replaceText(model, text) {
      if (model.getValue() === text) { return; }
      model.__replacing = true;
      model.pushEditOperations([], [{ range: model.getFullModelRange(), text: text }], function () { return null; });
      model.__replacing = false;
    }

    // Go to definition: Cmd+click (or the menu's definitionAtCursor) posts
    // the word; it stays underlined (busy) until Swift answers that req.
    var definitionReq = 0;
    var busy = { model: null, ids: [], req: 0 };
    var link = { model: null, ids: [] };

    function decorate(holder, model, range, cls) {
      if (holder.model && !holder.model.isDisposed()) { holder.model.deltaDecorations(holder.ids, []); }
      holder.model = model;
      holder.ids = model && range ? model.deltaDecorations([], [{ range: range, options: { inlineClassName: cls } }]) : [];
    }

    function wordRange(model, position) {
      var word = model.getWordAtPosition(position);
      return word ? { word: word.word,
        range: new monaco.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn) } : null;
    }

    function requestDefinition(position) {
      var model = editor.getModel();
      var hit = model && current ? wordRange(model, position) : null;
      if (!hit) { return false; }
      definitionReq += 1;
      decorate(link, null, null, "");
      decorate(busy, model, hit.range, "wt-def-busy");
      busy.req = definitionReq;
      var at = editor.getScrolledVisiblePosition({ lineNumber: position.lineNumber, column: hit.range.startColumn });
      var box = editor.getDomNode().getBoundingClientRect();
      post({ type: "definition", req: definitionReq, id: current, word: hit.word,
        line: position.lineNumber, col: position.column,
        x: box.left + (at ? at.left : 0), y: box.top + (at ? at.top + at.height : 0) });
      return true;
    }

    function isDefinitionGesture(e) {
      return e.event.metaKey && !e.event.altKey && !e.event.shiftKey && !e.event.ctrlKey
        && e.target.type === monaco.editor.MouseTargetType.CONTENT_TEXT && e.target.position;
    }

    editor.onMouseDown(function (e) {
      if (e.event.leftButton && isDefinitionGesture(e)) { requestDefinition(e.target.position); }
    });
    editor.onMouseMove(function (e) {
      var model = editor.getModel();
      var hit = model && isDefinitionGesture(e) ? wordRange(model, e.target.position) : null;
      decorate(link, hit ? model : null, hit ? hit.range : null, "wt-def-link");
    });
    editor.onMouseLeave(function () { decorate(link, null, null, ""); });
    editor.onKeyUp(function (e) { if (e.keyCode === monaco.KeyCode.Meta) { decorate(link, null, null, ""); } });

    // `fn` at most once per 100 ms: the first call at once, the last one
    // always made.
    function throttled(fn) {
      var timer = null, dirty = false;
      return function () {
        if (timer) { dirty = true; return; }
        fn();
        timer = setTimeout(function tick() {
          if (dirty) {
            dirty = false;
            fn();
            timer = setTimeout(tick, 100);
          } else {
            timer = null;
          }
        }, 100);
      };
    }

    // The cursor for the jump bar and history.
    function sendCursor() {
      var position = editor.getPosition();
      if (current && position) { post({ type: "cursor", id: current, line: position.lineNumber, col: position.column }); }
    }
    editor.onDidChangeCursorPosition(throttled(sendCursor));

    // Code questions (spec §9.2): the selection and the scroll for the ✦
    // button, Cmd+I and the context menu's "Ask AI".
    var SELECTION_LIMIT = 20480;
    function sendSelection() {
      var model = editor.getModel(), sel = editor.getSelection();
      if (!current || !model || !sel) { return; }
      var range = sel, truncated = false;
      if (!sel.isEmpty() && model.getValueLengthInRange(sel) > SELECTION_LIMIT) {
        var cut = model.getPositionAt(model.getOffsetAt(sel.getStartPosition()) + SELECTION_LIMIT);
        range = new monaco.Range(sel.startLineNumber, sel.startColumn, cut.lineNumber, cut.column);
        truncated = true;
      }
      post({ type: "selection", id: current, text: sel.isEmpty() ? "" : model.getValueInRange(range), truncated: truncated,
        startLine: sel.startLineNumber, startCol: sel.startColumn, endLine: sel.endLineNumber, endCol: sel.endColumn });
    }
    editor.onDidChangeCursorSelection(throttled(sendSelection));
    var sendScroll = throttled(function () { if (current) { post({ type: "scroll", id: current }); } });
    editor.onDidScrollChange(function (e) { if (e.scrollTopChanged || e.scrollLeftChanged) { sendScroll(); } });

    function requestAskAI() {
      if (!current || !editor.getModel()) { return false; }
      sendSelection();
      post({ type: "askAI", id: current });
      return true;
    }
    // Not a keybinding (the chord check would see one): consumed here, so
    // the app's menu item for the same chord does not fire as well.
    editor.onKeyDown(function (e) {
      if (e.keyCode === monaco.KeyCode.KeyI && e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        requestAskAI();
      }
    });
    editor.addAction({
      id: "wt.askAI",
      label: "Ask AI",
      contextMenuGroupId: "navigation",
      contextMenuOrder: 0,
      run: function () { requestAskAI(); }
    });

    function selectionRect() {
      var model = editor.getModel(), sel = editor.getSelection();
      if (!current || !model || !sel) { return null; }
      var start = editor.getScrolledVisiblePosition(sel.getStartPosition());
      var end = editor.getScrolledVisiblePosition(sel.getEndPosition());
      if (!start || !end) { return null; }
      var layout = editor.getLayoutInfo();
      var box = editor.getDomNode().getBoundingClientRect();
      var top = Math.max(0, Math.min(start.top, end.top));
      var bottom = Math.min(layout.height, Math.max(start.top + start.height, end.top + end.height));
      if (bottom <= top) { return null; }
      var oneLine = sel.startLineNumber === sel.endLineNumber;
      var left = oneLine ? Math.min(start.left, end.left) : layout.contentLeft;
      var right = oneLine ? Math.max(start.left, end.left) : layout.width - layout.verticalScrollbarWidth;
      return { x: box.left + left, y: box.top + top, w: Math.max(1, right - left), h: bottom - top };
    }

    // A suggested change as an inline diff: the old text struck through
    // (a model decoration, kept across tab switches), the new text in a
    // view zone under it (per editor: re-added when the file is shown).
    var proposals = {};   // buffer id -> {range, text, decorations, zone}
    function proposalRange(p) {
      return new monaco.Range(p.range.startLine, p.range.startCol, p.range.endLine, p.range.endCol);
    }
    function removeZone(p) {
      if (p.zone === null) { return; }
      var zone = p.zone;
      p.zone = null;
      editor.changeViewZones(function (zones) { zones.removeZone(zone); });
    }
    function addZone(id) {
      var p = proposals[id], model = models[id];
      if (!p || !model || current !== id || p.zone !== null || p.text === "") { return; }
      var font = editor.getOption(monaco.editor.EditorOption.fontInfo);
      var node = document.createElement("div");
      node.className = "wt-proposal-new";
      node.style.fontFamily = font.fontFamily;
      node.style.fontSize = font.fontSize + "px";
      node.style.lineHeight = editor.getOption(monaco.editor.EditorOption.lineHeight) + "px";
      // A selection's trailing line break is kept in the suggestion; it ends
      // the last line and adds none to the zone.
      var shown = p.text.replace(/\r?\n$/, "");
      node.textContent = shown;
      monaco.editor.colorize(shown, model.getLanguageId(), {}).then(function (html) {
        if (proposals[id] === p) { node.innerHTML = html; }
      }, function () {});
      var after = p.range.endCol === 1 && p.range.endLine > p.range.startLine ? p.range.endLine - 1 : p.range.endLine;
      editor.changeViewZones(function (zones) {
        p.zone = zones.addZone({ afterLineNumber: after, heightInLines: shown.split("\n").length, domNode: node });
      });
    }
    function clearProposalOf(id) {
      var p = proposals[id];
      if (!p) { return; }
      removeZone(p);
      if (models[id] && !models[id].isDisposed()) { models[id].deltaDecorations(p.decorations, []); }
      delete proposals[id];
    }

    // Usages: the word at the cursor (a right-click moves the cursor there
    // first). No keybinding: Shift+Cmd+U belongs to the app's menu, which
    // asks usagesAtCursor.
    function requestUsages() {
      var model = editor.getModel();
      var position = editor.getPosition();
      var hit = model && current && position ? wordRange(model, position) : null;
      if (!hit) { return false; }
      post({ type: "usages", id: current, word: hit.word, line: position.lineNumber, col: position.column });
      return true;
    }
    editor.addAction({
      id: "wt.showUsages",
      label: "Show All Usages",
      contextMenuGroupId: "navigation",
      contextMenuOrder: 1,
      run: function () { requestUsages(); }
    });

    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () {
      if (current) { send(current, true, true); }
    });
    window.addEventListener("blur", function () { flushAll(true); });

    // Leaving the shown file: drop its proposal zone, keep its view state.
    function leaveCurrent() {
      if (current && proposals[current]) { removeZone(proposals[current]); }
      if (current && models[current]) { viewStates[current] = editor.saveViewState(); }
    }

    window.wt = {
      show: function (args) {
        if (!args) {
          leaveCurrent();
          editor.setModel(null);
          current = null;
          return;
        }
        if (current === args.id && editor.getModel()) { return; }
        flushAll(true);
        leaveCurrent();
        // Before setModel: setting the model and restoring its view state
        // move the cursor, and that cursor message must carry the new id.
        current = args.id;
        editor.setModel(modelFor(args));
        if (viewStates[args.id]) { editor.restoreViewState(viewStates[args.id]); }
        if (reveals[args.id]) { revealNow(reveals[args.id]); delete reveals[args.id]; }
        addZone(args.id);
        if (!editor.getOption(monaco.editor.EditorOption.readOnly)) { editor.focus(); }
      },
      reveal: function (args) {
        if (!models[args.id]) { return; }
        if (current !== args.id) { reveals[args.id] = args; return; }
        revealNow(args);
        editor.focus();
      },
      reload: function (args) {
        var model = models[args.id];
        if (!model) { return; }
        if (args.mode === "rebase") {
          bases[args.id] = args.rev;
          if (pending[args.id]) { send(args.id, true, false); }
          return;
        }
        if (args.mode !== "force" && pending[args.id]) {
          send(args.id, true, false);
          return;
        }
        clearTimeout(pending[args.id]);
        delete pending[args.id];
        if (model.getValue() !== args.text) { clearProposalOf(args.id); }
        replaceText(model, args.text);
        bases[args.id] = args.rev;
      },
      // A model's URI cannot change: the language follows the new name by
      // asking Monaco what a throwaway model of that name would be.
      rename: function (args) {
        var model = models[args.id];
        if (!model) { return; }
        var probe = monaco.editor.createModel("", undefined, uriFor("probe-" + args.id, args.path));
        monaco.editor.setModelLanguage(model, probe.getLanguageId());
        probe.dispose();
      },
      close: function (id) {
        if (pending[id]) { send(id, true, false); }
        clearProposalOf(id);
        if (models[id]) {
          if (current === id) { editor.setModel(null); current = null; }
          models[id].dispose();
          delete models[id];
        }
        delete bases[id];
        delete viewStates[id];
        delete reveals[id];
      },
      takePending: function () {
        return Object.keys(pending).map(function (id) {
          clearTimeout(pending[id]);
          delete pending[id];
          return { id: id, text: models[id] ? models[id].getValue() : "", base: bases[id] };
        }).filter(function (edit) { return models[edit.id]; });
      },
      focus: function () { editor.focus(); },
      setReadOnly: function (flag) { editor.updateOptions({ readOnly: !!flag }); },
      definitionAtCursor: function () {
        var position = editor.getPosition();
        return !!position && requestDefinition(position);
      },
      definitionDone: function (req) {
        if (req === busy.req) { decorate(busy, null, null, ""); busy.req = 0; }
      },
      usagesAtCursor: function () { return requestUsages(); },
      askAI: function () { return requestAskAI(); },
      selectionRect: function () { return selectionRect(); },
      proposeEdit: function (args) {
        var model = models[args.id];
        if (!model) { return false; }
        clearProposalOf(args.id);
        var p = { range: args.range, text: args.text, zone: null, decorations: [] };
        p.decorations = model.deltaDecorations([], [{ range: proposalRange(p), options: { inlineClassName: "wt-proposal-old" } }]);
        proposals[args.id] = p;
        addZone(args.id);
        if (current === args.id) { editor.revealRangeInCenterIfOutsideViewport(proposalRange(p)); }
        return true;
      },
      clearProposal: function (id) { clearProposalOf(id); },
      applyEdit: function (args) {
        var model = models[args.id];
        if (!model) { return "missing"; }
        var range = new monaco.Range(args.range.startLine, args.range.startCol, args.range.endLine, args.range.endCol);
        // Line breaks compared as LF: Monaco writes the model's own (CRLF
        // in a CRLF file) whatever the suggestion used.
        var lf = monaco.editor.EndOfLinePreference.LF;
        if (!model.validateRange(range).equalsRange(range)
          || model.getValueInRange(range, lf) !== String(args.expected).replace(/\r\n/g, "\n")) {
          return "changed";
        }
        clearProposalOf(args.id);
        if (current === args.id) {
          editor.pushUndoStop();
          editor.executeEdits("wt-ask-ai", [{ range: range, text: args.text, forceMoveMarkers: true }]);
          editor.pushUndoStop();
        } else {
          model.pushStackElement();
          model.pushEditOperations([], [{ range: range, text: args.text }], function () { return null; });
          model.pushStackElement();
        }
        return "applied";
      }
    };
    post({ type: "ready" });
  }, function (err) {
    post({ type: "error", message: "Monaco failed to load: " + String(err && err.message || err) });
  });
})();

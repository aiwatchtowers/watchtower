// Go to definition and Usages for one Monaco editor, shared by the code
// viewer's page (editor.js) and the diff page's new side (diff.js, board
// #960). Kept out of the pages: their CSP allows no inline script.
//
// wtCodeNav(editor, currentId, post) is called once the editor exists:
//   - Cmd+click on a word (or definitionAtCursor) posts
//     `definition {req, id, word, line, col, x, y}`; the word stays
//     underlined (busy, class wt-def-busy) until definitionDone(req) answers
//     the latest req; Cmd+hover underlines the word (class wt-def-link);
//   - the context menu's "Show All Usages" (or usagesAtCursor) posts
//     `usages {id, word, line, col}` for the word at the cursor (a
//     right-click moves the cursor there first). No keybinding: Shift+Cmd+U
//     belongs to the app's menu, which asks usagesAtCursor.
// `currentId()` is the id the messages carry; a falsy one posts nothing.
// Returns {definitionAtCursor, definitionDone, usagesAtCursor, clear}.
function wtCodeNav(editor, currentId, post) {
  "use strict";
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
    var id = currentId();
    var hit = model && id ? wordRange(model, position) : null;
    if (!hit) { return false; }
    definitionReq += 1;
    decorate(link, null, null, "");
    decorate(busy, model, hit.range, "wt-def-busy");
    busy.req = definitionReq;
    var at = editor.getScrolledVisiblePosition({ lineNumber: position.lineNumber, column: hit.range.startColumn });
    var box = editor.getDomNode().getBoundingClientRect();
    post({ type: "definition", req: definitionReq, id: id, word: hit.word,
      line: position.lineNumber, col: position.column,
      x: box.left + (at ? at.left : 0), y: box.top + (at ? at.top + at.height : 0) });
    return true;
  }

  function requestUsages() {
    var model = editor.getModel();
    var position = editor.getPosition();
    var id = currentId();
    var hit = model && id && position ? wordRange(model, position) : null;
    if (!hit) { return false; }
    post({ type: "usages", id: id, word: hit.word, line: position.lineNumber, col: position.column });
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

  editor.addAction({
    id: "wt.showUsages",
    label: "Show All Usages",
    contextMenuGroupId: "navigation",
    contextMenuOrder: 1,
    run: function () { requestUsages(); }
  });

  return {
    definitionAtCursor: function () {
      var position = editor.getPosition();
      return !!position && requestDefinition(position);
    },
    definitionDone: function (req) {
      if (req === busy.req) { decorate(busy, null, null, ""); busy.req = 0; }
    },
    usagesAtCursor: function () { return requestUsages(); },
    // Another file on screen: the old one's underlines go.
    clear: function () {
      decorate(link, null, null, "");
      decorate(busy, null, null, "");
      busy.req = 0;
    }
  };
}

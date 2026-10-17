// Code viewer (board #738): TextMate highlighting, as in VS Code — the
// vscode-textmate tokenizer with the Oniguruma regex engine (WebAssembly),
// and the grammars of textmate/grammars (scripts/fetch-textmate.sh). A
// language below gets its TextMate grammar; every other one keeps Monaco's
// Monarch grammar (or languages.js's own).
//
// Nothing is loaded at startup: the engine on the first model of a
// TextMate language, each grammar (and the grammars it embeds) on the
// first model of its language. Monaco tokenizes lazily and incrementally,
// line by line from the previous line's state, the viewport first. When
// the engine or a grammar fails, the language falls back to Monaco's
// Monarch grammar and the failure is posted once.
//
// Tokens carry a theme-independent class, not a colour: TOKEN_CLASSES maps
// TextMate scope selectors to the class names the wt-dark/wt-light themes
// colour (languages.js). The selectors are matched by vscode-textmate's own
// theme engine (parent selectors, specificity), fed a "theme" whose colours
// are the class indexes; a token's colour id then names its class.
/* global monaco, require, post */
(function () {
  "use strict";

  // Grammar file (textmate/grammars/<name>.js) -> its scope name. Some are
  // here only for the languages that embed them (C++'s macros, Markdown's
  // fenced diff and Makefile blocks).
  var GRAMMARS = {
    "bat": "source.batchfile", "bicep": "source.bicep", "c": "source.c", "clojure": "source.clojure",
    "coffee": "source.coffee", "cpp": "source.cpp", "cpp-macro": "source.cpp.embedded.macro",
    "csharp": "source.cs", "css": "source.css", "cypher": "source.cypher", "dart": "source.dart",
    "diff": "source.diff", "docker": "source.dockerfile", "fsharp": "source.fsharp",
    "go": "source.go", "graphql": "source.graphql", "handlebars": "text.html.handlebars", "hcl": "source.hcl",
    "html": "text.html.basic", "html-derivative": "text.html.derivative", "ini": "source.ini",
    "java": "source.java", "javascript": "source.js", "json": "source.json", "jsonc": "source.json.comments",
    "julia": "source.julia", "kotlin": "source.kotlin", "less": "source.css.less", "liquid": "text.html.liquid",
    "lua": "source.lua", "make": "source.makefile", "markdown": "text.html.markdown", "mdx": "source.mdx",
    "mipsasm": "source.mips", "objective-c": "source.objc", "pascal": "source.pascal", "perl": "source.perl",
    "php": "source.php", "powerquery": "source.powerquery", "powershell": "source.powershell",
    "proto": "source.proto", "pug": "text.pug", "python": "source.python", "r": "source.r",
    "razor": "text.aspnetcorerazor", "regexp": "source.regexp.python", "rst": "source.rst",
    "ruby": "source.ruby", "rust": "source.rust", "scala": "source.scala", "scheme": "source.scheme",
    "scss": "source.css.scss", "shellscript": "source.shell", "shellsession": "text.shell-session",
    "solidity": "source.solidity", "sql": "source.sql", "swift": "source.swift",
    "system-verilog": "source.systemverilog", "tsx": "source.tsx",
    "twig": "text.html.twig", "typescript": "source.ts", "typespec": "source.tsp", "vb": "source.asp.vb.net",
    "verilog": "source.verilog", "wgsl": "source.wgsl", "xml": "text.xml", "xsl": "text.xml.xsl",
    "yaml": "source.yaml"
  };

  // Monaco language id -> its grammar.
  var LANGUAGES = {
    "bat": "bat", "bicep": "bicep", "c": "c", "clojure": "clojure", "coffeescript": "coffee", "cpp": "cpp",
    "csharp": "csharp", "css": "css", "cypher": "cypher", "dart": "dart", "dockerfile": "docker", "fsharp": "fsharp", "go": "go", "graphql": "graphql",
    "handlebars": "handlebars", "hcl": "hcl", "html": "html", "ini": "ini", "java": "java",
    "javascript": "javascript", "json": "jsonc", "julia": "julia", "kotlin": "kotlin", "less": "less",
    "liquid": "liquid", "lua": "lua", "markdown": "markdown", "mdx": "mdx",
    "mips": "mipsasm", "mysql": "sql", "objective-c": "objective-c", "pascal": "pascal", "perl": "perl",
    "pgsql": "sql", "php": "php", "powerquery": "powerquery", "powershell": "powershell", "proto": "proto",
    "pug": "pug", "python": "python", "r": "r", "razor": "razor", "redshift": "sql",
    "restructuredtext": "rst", "ruby": "ruby", "rust": "rust", "scala": "scala", "scheme": "scheme",
    "scss": "scss", "shell": "shellscript", "sol": "solidity", "sql": "sql", "swift": "swift",
    "systemverilog": "system-verilog", "twig": "twig", "typescript": "typescript",
    "typescriptreact": "tsx", "typespec": "typespec", "vb": "vb", "verilog": "verilog", "wgsl": "wgsl", "xml": "xml", "yaml": "yaml"
  };

  // Token class -> the TextMate scope selectors that give it. The most
  // specific match wins, as in a VS Code theme; no match = plain text.
  var TOKEN_CLASSES = [
    ["comment", ["comment", "punctuation.definition.comment"]],
    ["comment.doc", ["comment.block.documentation", "comment.line.documentation",
      "comment.line.double-slash.documentation", "comment.line.triple-slash.documentation",
      "comment.block.documentation punctuation.definition.comment",
      "comment.line.documentation punctuation.definition.comment",
      "comment.line.triple-slash.documentation punctuation.definition.comment"]],
    ["string", ["string", "constant.character", "punctuation.definition.string", "markup.raw.block.yaml"]],
    ["string.escape", ["constant.character.escape", "constant.character.format.placeholder",
      "constant.other.placeholder"]],
    // Code inside a string (`${…}`, `#{…}`, `\(…)`, JSX `{…}`) is code, not
    // string, as VS Code's themes reset it; the braces around it are
    // delimiters (bracket pairs, like Monarch's). Rust's format `{}` is
    // not code and stays string, so meta.interpolation is HCL's only.
    ["embedded", ["meta.embedded", "meta.template.expression", "meta.interpolation.hcl"]],
    ["delimiter.embedded", ["punctuation.section.embedded", "punctuation.definition.template-expression"]],
    ["regexp", ["string.regexp"]],
    ["number", ["constant.numeric", "keyword.other.unit"]],
    // Not "variable.other.constant": TypeScript gives it every `const`.
    ["constant", ["variable.other.constant.go", "variable.other.enummember", "constant.other.enum",
      "support.constant", "constant.other.caps"]],
    ["constant.language", ["constant.language"]],
    ["keyword", ["keyword", "storage", "storage.type", "storage.modifier",
      "keyword.operator.new", "keyword.operator.expression", "keyword.operator.logical.python",
      "keyword.operator.word", "keyword.operator.wordlike", "keyword.operator.sizeof", "keyword.operator.cast",
      "keyword.operator.instanceof", "keyword.operator.in", "keyword.operator.of", "keyword.operator.delete",
      "support.type.primitive", "support.type.builtin", "storage.type.primitive", "storage.type.built-in",
      "keyword.type", "entity.name.type.numeric.go", "entity.name.type.string.go",
      "storage.type.numeric.go", "storage.type.string.go", "storage.type.boolean.go", "storage.type.byte.go",
      "storage.type.error.go", "storage.type.rune.go", "storage.type.uintptr.go"]],
    ["operator", ["keyword.operator"]],
    // Plain to the themes; the refiners read them.
    ["delimiter.accessor", ["punctuation.other.period", "punctuation.accessor", "punctuation.separator.period",
      "punctuation.separator.dot", "punctuation.separator.member"]],
    ["variable", ["variable.other", "variable.other.readwrite"]],
    ["string.import", ["entity.name.import.go"]],
    ["variable.language", ["variable.language"]],
    ["type", ["entity.name.type", "entity.name.class", "entity.name.struct", "entity.name.interface",
      "entity.name.enum", "entity.name.trait", "entity.name.union", "entity.other.inherited-class",
      "support.class", "support.type", "storage.type.java", "storage.type.object", "storage.type.generic",
      "meta.type.annotation entity.name.type", "entity.name.type.class"]],
    ["type.parameter", ["entity.name.type.parameter", "entity.name.type.template", "variable.type.parameter"]],
    ["function", ["entity.name.function", "support.function", "variable.function",
      "meta.function-call.generic", "entity.name.function.member", "entity.name.function.call",
      "support.function.builtin", "meta.method.identifier entity.name.function"]],
    ["namespace", ["entity.name.namespace", "entity.name.package", "entity.name.module",
      "entity.name.type.module", "entity.name.type.namespace", "entity.name.scope-resolution",
      "support.other.namespace", "storage.modifier.import", "storage.modifier.package",
      "support.module", "entity.name.type.package", "variable.other.import.go"]],
    ["property", ["variable.other.property", "variable.other.object.property", "variable.other.member",
      "variable.other.field", "entity.name.variable.field", "support.variable.property",
      "meta.object-literal.key", "support.type.property-name", "entity.name.tag.yaml",
      "variable.other.key", "keyword.key", "support.type.property-name.json",
      "meta.structure.dictionary.key.python", "entity.name.variable.property", "variable.object.property",
      "meta.attribute.python", "variable.other.swift"]],
    ["parameter", ["variable.parameter", "entity.name.variable.parameter"]],
    ["annotation", ["meta.decorator", "entity.name.function.decorator", "punctuation.decorator",
      "storage.type.annotation", "punctuation.definition.annotation", "meta.attribute.rust",
      "keyword.other.attribute", "storage.modifier.attribute", "entity.name.function.attribute",
      "meta.declaration.annotation"]],
    ["tag", ["entity.name.tag", "punctuation.definition.tag", "support.class.component"]],
    ["attribute.name", ["entity.other.attribute-name"]],
    ["markup.heading", ["markup.heading", "entity.name.section", "markup.heading entity.name"]],
    ["markup.bold", ["markup.bold"]],
    ["markup.italic", ["markup.italic"]],
    ["markup.link", ["markup.underline.link", "string.other.link", "markup.link"]],
    ["markup.code", ["markup.inline.raw", "markup.raw", "markup.fenced_code.block"]],
    ["markup.quote", ["markup.quote"]],
    ["markup.list", ["markup.list punctuation.definition.list", "punctuation.definition.list.begin.markdown"]],
    ["inserted", ["markup.inserted"]],
    ["deleted", ["markup.deleted"]],
    ["diff.meta", ["meta.diff.header", "meta.diff.index", "meta.diff.header.from-file", "meta.diff.header.to-file",
      "punctuation.definition.from-file", "punctuation.definition.to-file", "meta.diff.only-in"]],
    ["diff.hunk", ["meta.diff.range"]]
  ];

  // Standard token types (0 other, 1 comment, 2 string, 3 regex) that
  // vscode-textmate's scope-name rule gets wrong: code inside strings (as
  // VS Code's TypeScript extension sets it; meta.embedded is code already,
  // and HCL's `${…}`) and Go's `string` type, a keyword whose scope name
  // says "string".
  var TOKEN_TYPES = {
    "meta.template.expression": 0, "meta.template.expression string": 2, "meta.template.expression comment": 1,
    "meta.interpolation.hcl": 0, "meta.interpolation.hcl string": 2, "meta.interpolation.hcl comment": 1,
    "storage.type.string.go": 0
  };

  var GRAMMAR_FOR_SCOPE = {};
  Object.keys(GRAMMARS).forEach(function (name) { GRAMMAR_FOR_SCOPE[GRAMMARS[name]] = name; });

  // The class theme: class i is "colour" #000000 + i + 1 (0 is the default).
  function classTheme() {
    var settings = [{ settings: { foreground: "#000000", background: "#ffffff" } }];
    TOKEN_CLASSES.forEach(function (entry, i) {
      var hex = (i + 1).toString(16);
      settings.push({ scope: entry[1], settings: { foreground: "#" + "000000".slice(hex.length) + hex } });
    });
    return { name: "wt-classes", settings: settings };
  }

  function load(module) {
    return new Promise(function (resolve, reject) { require([module], resolve, reject); });
  }

  function decodeBase64(text) {
    var binary = atob(text), bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
    return bytes;
  }

  // Each failure is posted once on the page's error channel.
  var reported = {};
  function reportOnce(key, message) {
    if (reported[key]) { return; }
    reported[key] = true;
    post({ type: "error", message: "Editor: " + message });
  }
  // The AMD loader's errors name the module (their message is the script
  // error event's "[object Event]").
  function describe(err) {
    if (err && err.moduleId) { return "could not load " + err.moduleId; }
    return String((err && err.message) || err);
  }

  var engine = null;   // Promise of {tm, registry, classOf}, made on first use
  function getEngine() {
    if (engine) { return engine; }
    engine = Promise.all([load("textmate/vscode-textmate"), load("textmate/vscode-oniguruma"), load("textmate/onig-wasm")])
      .catch(function (err) {
        // A build without textmate/ (scripts/fetch-monaco.sh not run).
        reportOnce("engine", "the TextMate engine failed to load (" + describe(err) + "); files keep Monaco's " +
          "Monarch colours. Run scripts/fetch-monaco.sh and rebuild.");
        throw err;
      })
      .then(function (modules) {
        var tm = modules[0], onig = modules[1];
        var onigLib = onig.loadWASM(decodeBase64(modules[2]).buffer).then(function () {
          return {
            createOnigScanner: function (patterns) { return onig.createOnigScanner(patterns); },
            createOnigString: function (text) { return onig.createOnigString(text); }
          };
        }, function (err) {
          reportOnce("engine", "the Oniguruma WebAssembly failed to start (" + describe(err) + "); files keep " +
            "Monaco's Monarch colours");
          throw err;
        });
        var registry = new tm.Registry({
          onigLib: onigLib,
          theme: classTheme(),
          // An embedded language with no grammar here, or whose grammar
          // fails, stays plain; a failing language's own grammar fails it
          // in providerFor.
          loadGrammar: function (scope) {
            var name = GRAMMAR_FOR_SCOPE[scope];
            return name ? load("textmate/grammars/" + name).catch(function (err) {
              reportOnce("grammar " + name, "the TextMate grammar " + name + " failed to load (" + describe(err) + ")");
              return null;
            }) : Promise.resolve(null);
          }
        });
        // vscode-textmate's colour ids -> class names.
        var classOf = registry.getColorMap().map(function (colour) {
          var index = parseInt(String(colour).slice(1), 16) - 1;
          return index >= 0 && index < TOKEN_CLASSES.length ? TOKEN_CLASSES[index][0] : "";
        });
        // The engine is up only with Oniguruma: a wasm failure fails the
        // engine once, not each grammar.
        return onigLib.then(function () { return { tm: tm, registry: registry, classOf: classOf }; });
      });
    return engine;
  }

  // vscode-textmate's encoded token attributes: the standard token type in
  // bits 8–9, the colour id in bits 15–23.
  var TOKEN_TYPE_MASK = 0x300, TOKEN_TYPE_OFFSET = 8;
  var FOREGROUND_MASK = 0xFF8000, FOREGROUND_OFFSET = 15;
  // Monaco reads a token's standard type off its name (the words comment,
  // string, regex/regexp), and bracket matching, bracket colours and
  // auto-closing go by it. A class whose name does not say its type gets
  // it as a suffix ("property.string": a JSON key, coloured as a property
  // by the "property" rule, a string to the brackets).
  var TYPE_NAMES = ["", "comment", "string", "regexp"];
  var TYPED_NAME = /\b(comment|string|regex|regexp)\b/;
  function tokenName(cls, type) {
    var word = TYPE_NAMES[type];
    if (!word || TYPED_NAME.test(cls)) { return cls; }
    return (cls || "plain") + "." + word;
  }
  // A line taking longer than this is left where the tokenizer stopped (the
  // rest plain) and the next line starts from the state before it, as VS
  // Code does.
  var LINE_TIME_LIMIT_MS = 500;

  // What a grammar does not tell apart, told from the line's text: a
  // refiner gets the line, its class per character (to change in place)
  // and the names the file imported so far ("|a|b|"), and returns the
  // names after the line. The names ride in the line state, so an import
  // edited at the top re-tokenizes the lines below it.
  var IDENTIFIER = /[A-Za-z_][A-Za-z0-9_]*/g;

  function setRange(classes, from, to, cls) {
    for (var i = from; i < to; i++) { classes[i] = cls; }
  }

  // Each identifier of `line` that starts and ends in the same class, one
  // of `among`.
  function eachIdentifier(line, classes, among, fn) {
    IDENTIFIER.lastIndex = 0;
    var m;
    while ((m = IDENTIFIER.exec(line)) !== null) {
      var start = m.index, end = start + m[0].length;
      if (among.indexOf(classes[start]) >= 0 && classes[end - 1] === classes[start]) { fn(m[0], start, end); }
    }
  }

  function hasName(names, name) { return names.indexOf("|" + name + "|") >= 0; }
  function addName(names, name) {
    return !name || name === "_" || name === "." || hasName(names, name) ? names : (names || "|") + name + "|";
  }

  // `name.` where name is an imported package or module.
  function markQualifiers(line, classes, names, among) {
    if (!names) { return; }
    eachIdentifier(line, classes, among, function (name, start, end) {
      if (line.charAt(end) === "." && hasName(names, name)) { setRange(classes, start, end, "namespace"); }
    });
  }

  // A Go import's package name: the path's last element, without a major
  // version element (".../v2") or a ".vN"/"go-" decoration.
  function goPackageName(path) {
    var parts = path.split("/");
    var last = parts.pop();
    if (/^v\d+$/.test(last) && parts.length) { last = parts.pop(); }
    return last.replace(/\.v\d+$/, "").replace(/^go-/, "").replace(/-go$/, "").replace(/[^A-Za-z0-9_]/g, "");
  }

  var REFINERS = {
    // Packages (imported names before a "."), fields and methods after a
    // "." (the grammar gives both the plain variable scope).
    go: function (line, classes, names) {
      var alias = false;
      for (var i = 0; i < line.length; i++) {
        if (classes[i] === "namespace" && classes[i - 1] !== "namespace") {
          var a = /^[A-Za-z_.]\w*/.exec(line.slice(i));
          if (a) { names = addName(names, a[0]); alias = true; }
        } else if (classes[i] === "string.import" && classes[i - 1] !== "string.import") {
          var end = i;
          while (end < line.length && classes[end] === "string.import") { end++; }
          if (!alias) { names = addName(names, goPackageName(line.slice(i, end))); }
          alias = false;
        }
      }
      markQualifiers(line, classes, names, ["variable", "type"]);
      eachIdentifier(line, classes, ["variable"], function (name, start, end) {
        if (line.charAt(start - 1) === ".") { setRange(classes, start, end, "property"); }
      });
      return names;
    },
    // Modules: the names an `import` binds, and their uses before a ".".
    python: function (line, classes, names) {
      var m = /^(\s*)(import\s+)(.*)$/.exec(line);
      // The grammar's import keyword, not the word in a docstring; the
      // list ends where a comment starts.
      if (m && classes[m[1].length] === "keyword") {
        var at = m[1].length + m[2].length;
        var list = m[3];
        for (var c = 0; c < list.length; c++) {
          if (/^comment/.test(classes[at + c] || "")) { list = list.slice(0, c); break; }
        }
        list.split(",").forEach(function (part) {
          var bound = /^(\s*)([\w.]+)(?:\s+as\s+(\w+))?/.exec(part);
          if (bound) {
            var start = at + bound[1].length;
            setRange(classes, start, start + bound[2].length, "namespace");
            names = addName(names, bound[3] || bound[2].split(".")[0]);
          }
          at += part.length + 1;
        });
      }
      // `from m import a`: m is a module; what it binds may not be.
      var from = /^(\s*)(from\s+)([\w.]+)/.exec(line);
      if (from && classes[from[1].length] === "keyword") {
        var at2 = from[1].length + from[2].length;
        setRange(classes, at2, at2 + from[3].length, "namespace");
      }
      markQualifiers(line, classes, names, [""]);
      return names;
    },
    // Types: Swift's grammar leaves most type references unscoped, and
    // they are the identifiers in UpperCamelCase. Argument labels.
    swift: function (line, classes, names) {
      var m = /^(\s*(?:@\w+\s+)*)(import\s+(?:\w+\s+)?)(\w+)/.exec(line);
      // The grammar's import keyword, not the word in a string.
      if (m && classes[m[1].length] === "keyword") {
        var at = m[1].length + m[2].length;
        setRange(classes, at, at + m[3].length, "namespace");
      }
      eachIdentifier(line, classes, ["", "function"], function (name, start, end) {
        if (classes[start] === "" && /^[A-Z]/.test(name)) { setRange(classes, start, end, "type"); }
        // An argument label: the grammar scopes it as a method.
        if (classes[start] === "function" && /^\s*:/.test(line.slice(end))) { setRange(classes, start, end, "parameter"); }
      });
      return names;
    }
  };

  // A line's state: the grammar's rule stack and the names imported so far.
  function LineState(stack, names) { this.stack = stack; this.names = names; }
  LineState.prototype.clone = function () { return this; };
  LineState.prototype.equals = function (other) {
    return other instanceof LineState && other.names === this.names && other.stack.equals(this.stack);
  };

  function tokensProvider(e, grammar, languageId) {
    var refine = REFINERS[languageId] || null;
    var initial = new LineState(e.tm.INITIAL, "");
    function classAt(raw, i) { return e.classOf[(raw[i + 1] & FOREGROUND_MASK) >>> FOREGROUND_OFFSET] || ""; }
    function typeAt(raw, i) { return (raw[i + 1] & TOKEN_TYPE_MASK) >>> TOKEN_TYPE_OFFSET; }
    function tokenize(line, state) {
      var result = grammar.tokenizeLine2(line, state.stack, LINE_TIME_LIMIT_MS);
      var raw = result.tokens, names = state.names, tokens = [], last = null, i, name;
      if (refine) {
        var classes = new Array(line.length), types = new Array(line.length);
        for (i = 0; i < raw.length; i += 2) {
          var to = i + 2 < raw.length ? raw[i + 2] : line.length;
          setRange(classes, raw[i], to, classAt(raw, i));
          setRange(types, raw[i], to, typeAt(raw, i));
        }
        names = refine(line, classes, names);
        for (i = 0; i < line.length; i++) {
          name = tokenName(classes[i], types[i]);
          if (name !== last) { tokens.push({ startIndex: i, scopes: name }); last = name; }
        }
        if (!tokens.length) { tokens.push({ startIndex: 0, scopes: "" }); }
      } else {
        for (i = 0; i < raw.length; i += 2) {
          name = tokenName(classAt(raw, i), typeAt(raw, i));
          if (name === last) { continue; }
          tokens.push({ startIndex: raw[i], scopes: name });
          last = name;
        }
      }
      return { tokens: tokens, endState: result.stoppedEarly ? state : new LineState(result.ruleStack, names) };
    }
    return {
      getInitialState: function () { return initial; },
      // A throw (a pattern Oniguruma rejects, a refiner bug) leaves the
      // line plain and is posted once per language, not once per line.
      tokenize: function (line, state) {
        try {
          return tokenize(line, state);
        } catch (err) {
          reportOnce("tokenize " + languageId, "TextMate tokenizing " + languageId + " failed (" + describe(err) + ")");
          return { tokens: [{ startIndex: 0, scopes: "" }], endState: state };
        }
      }
    };
  }

  // What colours a language TextMate failed for: Monaco's own Monarch
  // grammar (its basic-languages entry keeps the module's loader; TSX takes
  // TypeScript's), or for JSON the JSON mode's tokenizer, switched back on.
  var MONARCH_OF = { typescriptreact: "typescript" };
  function fallbackFor(languageId) {
    if (languageId === "json") {
      setJsonModeTokens(true);
      return Promise.resolve(null);
    }
    var from = MONARCH_OF[languageId] || languageId;
    var entry = monaco.languages.getLanguages().filter(function (l) { return l.id === from; })[0];
    if (!entry || typeof entry.loader !== "function") { return Promise.resolve(null); }
    return entry.loader().then(function (mod) { return (mod && mod.language) || null; }, function () { return null; });
  }

  function failed(languageId, why) {
    reportOnce("language " + languageId, "the TextMate grammar for " + languageId + " failed (" + why +
      "); it keeps Monaco's Monarch colours");
  }

  var ready = {};      // language id -> Promise of its tokenizer (TextMate, else Monarch, else null)
  var textMate = {};   // language id -> true once its TextMate tokenizer is made
  function providerFor(languageId) {
    if (!ready[languageId]) {
      var scope = GRAMMARS[LANGUAGES[languageId]];
      ready[languageId] = getEngine().then(function (e) {
        return e.registry.loadGrammarWithConfiguration(scope, 1, { tokenTypes: TOKEN_TYPES }).then(function (grammar) {
          if (!grammar) {
            // Its module failed to load, and loadGrammar posted that, naming it.
            if (!reported["grammar " + LANGUAGES[languageId]]) { failed(languageId, "no grammar for " + scope); }
            throw new Error("no grammar for " + scope);
          }
          textMate[languageId] = true;
          return tokensProvider(e, grammar, languageId);
        }, function (err) {
          failed(languageId, describe(err));
          throw err;
        });
      }).catch(function () { return fallbackFor(languageId); });
    }
    return ready[languageId];
  }

  window.wtTextMate = {
    // A Promise of true once `languageId`'s TextMate tokenizer is in place
    // (false: none, or it failed and Monarch took over) — for the headless
    // check.
    whenReady: function (languageId) {
      if (!LANGUAGES[languageId]) { return Promise.resolve(false); }
      return providerFor(languageId).then(function () { return !!textMate[languageId]; });
    },
    languages: function () { return Object.keys(LANGUAGES); }
  };

  // After registerExtraLanguages (the languages must exist). The factories
  // replace the Monarch ones Monaco registered for the same ids, and fall
  // back to them when TextMate fails.
  window.registerTextMateGrammars = function () {
    Object.keys(LANGUAGES).forEach(function (id) {
      monaco.languages.registerTokensProviderFactory(id, { create: function () { return providerFor(id); } });
    });
    setJsonModeTokens(false);
  };

  // The JSON mode sets its own tokens provider when a JSON model appears,
  // over the factory; switched off, it keeps its other features.
  function setJsonModeTokens(on) {
    var json = monaco.json || (monaco.languages && monaco.languages.json);
    var defaults = json && json.jsonDefaults;
    if (defaults && defaults.setModeConfiguration) {
      defaults.setModeConfiguration(Object.assign({}, defaults.modeConfiguration, { tokens: on }));
    } else {
      reportOnce("json mode", "could not switch the JSON mode's own colours " + (on ? "on" : "off"));
    }
  }
})();

// POC (code viewer): what Monaco does not highlight out of the box.
// 1. File associations for languages Monaco already has (by extension, by
//    file name, by shebang for scripts with no extension). Registering an
//    existing id again merges into it.
// 2. Languages Monaco ships nothing for: Monarch grammars for dotenv,
//    Makefile, TOML, ignore files, go.mod/go.sum, diff/patch, logs and
//    CSV/TSV (tuned here, kept over their TextMate grammars), and TSX,
//    which only its TextMate grammar colours (textmate.js).
// 3. The editor themes: vs/vs-dark under the token palette below.
/* global monaco, post */
(function () {
  "use strict";

  var VARIABLE = /\$\{[^}]*\}|\$[A-Za-z_]\w*/;

  var associations = [
    { id: "shell",
      extensions: [".zsh", ".ksh", ".fish", ".command"],
      filenames: [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile",
        ".bash_aliases", ".bash_logout", ".profile", ".envrc", "pre-commit", "pre-push", "commit-msg",
        "prepare-commit-msg", "post-commit", "post-merge", "post-checkout", "pre-rebase", "gradlew"],
      firstLine: "^#!.*\\b(ba|z|k|da|fi)?sh\\b" },
    { id: "python", extensions: [".pyi", ".bzl", ".star"],
      filenames: ["BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "SConstruct", "SConscript", "Snakefile"],
      firstLine: "^#!.*\\bpython[\\d.]*\\b" },
    { id: "javascript", firstLine: "^#!.*\\b(node|deno|bun)\\b" },
    { id: "ruby", extensions: [".podspec", ".rake", ".ru", ".jbuilder"],
      filenames: ["Podfile", "Fastfile", "Appfile", "Matchfile", "Pluginfile", "Brewfile", "Vagrantfile",
        "Guardfile", "Dangerfile", "Berksfile", "Capfile", "Thorfile"],
      firstLine: "^#!.*\\bruby\\b" },
    { id: "perl", firstLine: "^#!.*\\bperl\\b" },
    { id: "php", firstLine: "^#!.*\\bphp\\b|^<\\?php" },
    { id: "json",
      extensions: [".jsonc", ".json5", ".jsonl", ".ndjson", ".webmanifest", ".code-workspace", ".resolved",
        ".prettierrc", ".swcrc", ".map"],
      filenames: ["composer.lock", "Pipfile.lock", "flake.lock", ".watchmanconfig"] },
    { id: "xml",
      extensions: [".plist", ".entitlements", ".xcscheme", ".xcworkspacedata", ".storyboard", ".xib",
        ".iml", ".resx", ".nuspec", ".rss", ".atom", ".kml", ".gpx", ".xliff", ".xlf", ".fxml"],
      filenamePatterns: ["*.xml.dist", "*.xml.dist.*"] },
    { id: "yaml", extensions: [".clang-format", ".clang-tidy", ".yamllint", ".cff"],
      filenamePatterns: ["*.yml.dist", "*.yaml.dist"] },
    { id: "ini",
      extensions: [".conf", ".cfg", ".cnf", ".service", ".timer", ".socket", ".desktop", ".npmrc",
        ".yarnrc", ".pylintrc", ".flake8", ".coveragerc", ".gitmodules", ".hgrc", ".curlrc", ".wgetrc"] },
    { id: "dockerfile", filenames: ["Containerfile", "dockerfile"],
      filenamePatterns: ["Dockerfile.*", "*.Dockerfile", "Containerfile.*"] },
    { id: "markdown", extensions: [".mdc"] },
    { id: "objective-c", extensions: [".mm"] },
    { id: "html", extensions: [".vue", ".svelte", ".astro", ".ejs"] },
    { id: "handlebars", extensions: [".tmpl", ".gotmpl", ".mustache"] },
    // No Groovy in Monaco; Java's grammar reads Gradle and Jenkinsfiles well enough.
    { id: "java", extensions: [".groovy", ".gradle", ".gvy"], filenames: ["Jenkinsfile"] },
    { id: "pgsql", extensions: [".psql", ".pgsql"] },
    { id: "sql", extensions: [".ddl", ".dml"] },
    { id: "hcl", extensions: [".nomad"] }
  ];

  var dotenv = {
    tokenizer: {
      root: [
        [/^\s*#.*$/, "comment"],
        [/^(\s*)(export)(\s+)([A-Za-z_][\w.\-]*)(\s*)(=)/, ["", "keyword", "", "variable", "", "delimiter"]],
        [/^(\s*)([A-Za-z_][\w.\-]*)(\s*)(=)/, ["", "variable", "", "delimiter"]],
        [/\s+#.*$/, "comment"],
        [/"/, { token: "string.quote", next: "@dquoted" }],
        [/'[^']*'?/, "string"],
        [VARIABLE, "variable.predefined"],
        [/\b(true|false|yes|no|null)\b/, "keyword"],
        [/-?\d+(\.\d+)?\b/, "number"],
        [/[^\s#$"']+|\$/, "string"],
        [/\s+/, ""]
      ],
      // Double quotes may span lines in dotenv, so this state may too.
      dquoted: [
        [VARIABLE, "variable.predefined"],
        [/\\./, "string.escape"],
        [/"/, { token: "string.quote", next: "@pop" }],
        [/[^"\\$]+|\$/, "string"]
      ]
    }
  };

  // Recipes are not told apart from rules (Monarch keeps no per-line
  // state): shell words get colored wherever they appear.
  var makefile = {
    tokenizer: {
      root: [
        [/^\s*#.*$/, "comment"],
        [/\s#.*$/, "comment"],
        [/^\s*-?(include|sinclude|ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|export|unexport|override|undefine|vpath)\b/, "keyword"],
        [/^(\s*)([A-Za-z_][\w.\-]*)(\s*)(\?=|:=|::=|\+=|!=|=)/, ["", "variable", "", "operator"]],
        [/^(\.PHONY|\.DEFAULT|\.SUFFIXES|\.PRECIOUS|\.INTERMEDIATE|\.SECONDARY|\.DELETE_ON_ERROR|\.SILENT|\.ONESHELL|\.EXPORT_ALL_VARIABLES)(?=\s*:)/, "keyword"],
        [/^[^\s:=#][^:=#]*(?=::?(?!=))/, "type"],
        [/\$\((?:[a-z\-]+\s)?/, { token: "variable.predefined", next: "@call" }],
        [/\$\{[^}]*\}|\$[@<^?*%+|$]|\$\w/, "variable.predefined"],
        [/^\t@/, "keyword"],
        [/\b(if|then|else|elif|fi|for|in|do|done|case|esac|while|until|echo|cd|exit|test|set|export|true|false)\b/, "keyword"],
        [/"(?:[^"\\]|\\.)*"?/, "string"],
        [/'[^']*'?/, "string"],
        [/[;|&<>]/, "delimiter"],
        [/[^\s$"'#;|&<>]+|\$/, ""],
        [/\s+/, ""]
      ],
      call: [
        [/\$\((?:[a-z\-]+\s)?/, { token: "variable.predefined", next: "@push" }],
        [/\)/, { token: "variable.predefined", next: "@pop" }],
        [/[,]/, "delimiter"],
        [/[^$),]+|\$/, "variable.predefined"]
      ]
    }
  };

  var toml = {
    tokenizer: {
      root: [
        [/#.*$/, "comment"],
        [/^\s*\[\[[^\]]*\]\]/, "type"],
        [/^\s*\[[^\]]*\]/, "type"],
        [/("(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_\-]+)(?=(\s*\.\s*("(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_\-]+))*\s*=)/, "variable"],
        [/"""/, { token: "string", next: "@mlBasic" }],
        [/'''/, { token: "string", next: "@mlLiteral" }],
        [/"/, { token: "string", next: "@basic" }],
        [/'[^']*'/, "string"],
        [/\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?)?([Zz]|[+\-]\d{2}:\d{2})?|\d{2}:\d{2}:\d{2}(\.\d+)?/, "number"],
        [/[+\-]?(0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|(\d[\d_]*)(\.[\d_]+)?([eE][+\-]?\d+)?|inf|nan)\b/, "number"],
        [/\b(true|false)\b/, "keyword"],
        [/[{}\[\],.=]/, "delimiter"],
        [/\s+/, ""]
      ],
      basic: [
        [/\\./, "string.escape"],
        [/"/, { token: "string", next: "@pop" }],
        [/[^"\\]+/, "string"]
      ],
      mlBasic: [
        [/\\./, "string.escape"],
        [/"""/, { token: "string", next: "@pop" }],
        [/[^"\\]+|"/, "string"]
      ],
      mlLiteral: [
        [/'''/, { token: "string", next: "@pop" }],
        [/[^']+|'/, "string"]
      ]
    }
  };

  var ignore = {
    tokenizer: {
      root: [
        [/^\s*#.*$/, "comment"],
        [/^!/, "keyword"],
        [/\\./, "string.escape"],
        [/\*\*|\*|\?/, "keyword"],
        [/\[[^\]]*\]/, "regexp"],
        [/@[\w\-./]+/, "type"],
        [/\//, "delimiter"],
        [/[^\s\\*?\[\/@]+|\s+/, ""]
      ]
    }
  };

  var gomod = {
    tokenizer: {
      root: [
        [/\/\/.*$/, "comment"],
        [/^\s*(module|go|toolchain|godebug|require|replace|exclude|retract|tool|ignore|use)\b/, "keyword"],
        [/=>/, "operator"],
        [/h1:[A-Za-z0-9+\/=]+/, "comment"],
        [/\bv\d+\.\d+\.\d+[\w.+\-]*(\/go\.mod)?/, "number"],
        [/\b\d+\.\d+(\.\d+)?\b/, "number"],
        [/[()\[\],]/, "delimiter"],
        [/"(?:[^"\\]|\\.)*"/, "string"],
        [/[\w.\-~]+(\/[\w.\-~]+)+/, "string"],
        [/\S+|\s+/, ""]
      ]
    }
  };

  var diff = {
    tokenizer: {
      root: [
        [/^(diff|index|new file mode|deleted file mode|old mode|new mode|similarity index|rename from|rename to|Binary files|Only in)\b.*$/, "diff.meta"],
        [/^(---|\+\+\+) .*$/, "diff.meta"],
        // [@] not @: Monarch reads @name in a regex as an attribute reference.
        [/^([@]{2}[^@]*[@]{2})(.*)$/, ["diff.hunk", "comment"]],
        [/^\+.*$/, "inserted"],
        [/^-.*$/, "deleted"],
        [/^\\.*$/, "comment"],
        [/.*$/, ""]
      ]
    }
  };

  var log = {
    ignoreCase: true,
    tokenizer: {
      root: [
        [/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}([.,]\d+)?(Z|[+\-]\d{2}:?\d{2})?|\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?|\b\d{2}:\d{2}:\d{2}(\.\d+)?\b/, "log.date"],
        [/\b(error|err|fatal|panic|critical|crit|severe|exception|failed|failure)\b/, "log.error"],
        [/\b(warn|warning)\b/, "log.warn"],
        [/\b(info|notice)\b/, "log.info"],
        [/\b(debug|trace|verbose)\b/, "log.debug"],
        [/"(?:[^"\\]|\\.)*"/, "string"],
        [/\b[\w.\-]+(?==)/, "variable"],
        [/https?:\/\/\S+/, "string"],
        [/\b0x[0-9a-f]+\b|\b\d+(\.\d+)?\b/, "number"],
        [/[\w\-]+|\s+|./, ""]
      ]
    }
  };

  // Rainbow columns: one state per column, cycling through six colors.
  // A field at the start of a line always begins column 0.
  function columns(separator) {
    var sep = separator === "\t" ? "\\t" : separator;
    var field = new RegExp("\"(?:[^\"]|\"\")*\"?|[^" + sep + "\"]+");
    var lineStart = new RegExp("^(?:\"(?:[^\"]|\"\")*\"?|[^" + sep + "\"]+)");
    var tokenizer = {};
    for (var k = 0; k < 6; k++) {
      tokenizer["c" + k] = [
        [lineStart, { token: "csv.c0", switchTo: "@c0" }],
        [new RegExp("^" + sep), { token: "delimiter", switchTo: "@c1" }],
        [field, "csv.c" + k],
        [new RegExp(sep), { token: "delimiter", switchTo: "@c" + ((k + 1) % 6) }]
      ];
    }
    return { start: "c0", tokenizer: tokenizer };
  }

  var grammars = [
    { language: { id: "dotenv", aliases: ["dotenv"], extensions: [".env"], filenames: [".env"], filenamePatterns: [".env.*", "*.env"] },
      tokens: dotenv, config: { comments: { lineComment: "#" } } },
    { language: { id: "makefile", aliases: ["Makefile"], extensions: [".mk", ".mak", ".make"],
        filenames: ["Makefile", "makefile", "GNUmakefile", "BSDmakefile"] },
      tokens: makefile, config: { comments: { lineComment: "#" } } },
    { language: { id: "toml", aliases: ["TOML"], extensions: [".toml"],
        filenames: ["Cargo.lock", "Pipfile", "poetry.lock", "uv.lock", "Gopkg.lock"] },
      tokens: toml, config: { comments: { lineComment: "#" }, brackets: [["[", "]"], ["{", "}"]] } },
    { language: { id: "ignore", aliases: ["Ignore"],
        extensions: [".gitignore", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore",
          ".gcloudignore", ".helmignore", ".vscodeignore", ".slugignore", ".stylelintignore"],
        filenames: [".ignore", ".rgignore", ".fdignore", "CODEOWNERS", "OWNERS"] },
      tokens: ignore, config: { comments: { lineComment: "#" } } },
    { language: { id: "gomod", aliases: ["go.mod"], filenames: ["go.mod", "go.work", "go.sum", "go.work.sum"] },
      tokens: gomod, config: { comments: { lineComment: "//" }, brackets: [["(", ")"]] } },
    { language: { id: "diff", aliases: ["Diff"], extensions: [".diff", ".patch", ".rej"] },
      tokens: diff, config: {} },
    { language: { id: "log", aliases: ["Log"], extensions: [".log"], filenamePatterns: ["*.log.*"] },
      tokens: log, config: {} },
    // Monaco reads .tsx as TypeScript, whose TextMate grammar has no JSX;
    // the language configuration is TypeScript's (confFrom).
    { language: { id: "typescriptreact", aliases: ["TypeScript JSX", "tsx"], extensions: [".tsx"] },
      tokens: null, confFrom: "typescript" },
    { language: { id: "csv", aliases: ["CSV"], extensions: [".csv"] }, tokens: columns(","), config: {} },
    { language: { id: "tsv", aliases: ["TSV"], extensions: [".tsv", ".tab"] }, tokens: columns("\t"), config: {} }
  ];

  // The themes' token colours, after JetBrains' Dark (New UI) and IntelliJ
  // Light schemes: [token, dark, light, font style]. The tokens are the
  // classes textmate.js gives TextMate grammars and the names Monarch
  // grammars use; Monaco matches a rule by prefix ("type" colours
  // "type.identifier.swift"), so one rule covers both.
  var palette = [
    ["", "BCBEC4", "080808"],
    ["comment", "7A7E85", "8C8C8C", "italic"],
    ["comment.doc", "5F826B", "8C8C8C", "italic"],
    ["string", "6AAB73", "067D17"],
    ["string.escape", "CF8E6D", "0037A6"],
    ["regexp", "42C3D4", "264EFF"],
    ["number", "2AACB8", "1750EB"],
    ["constant", "C77DBB", "871094", "italic"],
    ["constant.language", "CF8E6D", "0033B3"],
    ["keyword", "CF8E6D", "0033B3"],
    ["operator", "BCBEC4", "080808"],
    ["delimiter", "BCBEC4", "080808"],
    ["delimiter.embedded", "CF8E6D", "0033B3"],
    ["identifier", "BCBEC4", "080808"],
    ["variable", "BCBEC4", "080808"],
    ["variable.language", "CF8E6D", "0033B3"],
    ["variable.predefined", "C77DBB", "871094"],
    ["type", "16BAAC", "A65E00"],
    ["type.parameter", "16BAAC", "A65E00"],
    ["function", "56A8F5", "00627A"],
    ["predefined", "56A8F5", "00627A"],
    ["namespace", "AFBF7E", "56677A"],
    ["property", "C77DBB", "871094"],
    ["parameter", "B189F5", "6A3DB8"],
    ["annotation", "B3AE60", "9E880D"],
    ["tag", "D5B778", "0033B3"],
    ["metatag", "D5B778", "0033B3"],
    ["attribute.name", "BABABA", "174AD4"],
    ["attribute.value", "6AAB73", "067D17"],
    ["markup.heading", "CF8E6D", "0033B3", "bold"],
    ["markup.bold", "", "", "bold"],
    ["markup.italic", "", "", "italic"],
    ["markup.link", "56A8F5", "006DCC", "underline"],
    ["markup.code", "C9A26D", "3A6C00"],
    ["markup.quote", "7A7E85", "8C8C8C", "italic"],
    ["markup.list", "CF8E6D", "0033B3"],
    ["inserted", "85e89d", "22863a"],
    ["deleted", "f97583", "b31d28"],
    ["diff.meta", "b392f0", "6f42c1", "bold"],
    ["diff.hunk", "79b8ff", "005cc5"],
    ["log.error", "f97583", "d73a49", "bold"],
    ["log.warn", "ffdf5d", "b08800", "bold"],
    ["log.info", "79b8ff", "0366d6"],
    ["log.debug", "959da5", "6a737d"],
    ["log.date", "959da5", "6a737d"],
    ["csv.c0", "9cdcfe", "0451a5"],
    ["csv.c1", "ce9178", "a31515"],
    ["csv.c2", "b5cea8", "098658"],
    ["csv.c3", "c586c0", "af00db"],
    ["csv.c4", "dcdcaa", "795e26"],
    ["csv.c5", "4ec9b0", "267f99"]
  ];

  function themeRules(column) {
    return palette.map(function (p) {
      var rule = { token: p[0] };
      if (p[column]) { rule.foreground = p[column]; }
      // "" too: a rule without a style must not inherit its parent's
      // ("constant.language" is not italic like "constant").
      rule.fontStyle = p[3] || "";
      return rule;
    });
  }

  // `id` takes `from`'s language configuration (brackets, comments, Enter
  // rules, word pattern) from Monaco's basic-languages module, when a model
  // of `id` first appears.
  function borrowConfiguration(id, from) {
    var entry = monaco.languages.getLanguages().filter(function (l) { return l.id === from; })[0];
    if (!entry || typeof entry.loader !== "function") { return; }
    monaco.languages.onLanguageEncountered(id, function () {
      entry.loader().then(function (mod) {
        if (mod && mod.conf) { monaco.languages.setLanguageConfiguration(id, mod.conf); }
      }, function (err) {
        post({ type: "error", message: "Editor: " + from + "'s language configuration for " + id + " failed: " +
          String((err && err.message) || err) });
      });
    });
  }

  window.registerExtraLanguages = function () {
    associations.forEach(function (a) { monaco.languages.register(a); });
    grammars.forEach(function (g) {
      monaco.languages.register(g.language);
      if (g.tokens) { monaco.languages.setMonarchTokensProvider(g.language.id, g.tokens); }
      if (g.confFrom) { borrowConfiguration(g.language.id, g.confFrom); } else {
        monaco.languages.setLanguageConfiguration(g.language.id, g.config);
      }
    });
    monaco.editor.defineTheme("wt-light", { base: "vs", inherit: true, rules: themeRules(2),
      colors: { "editor.foreground": "#080808" } });
    monaco.editor.defineTheme("wt-dark", { base: "vs-dark", inherit: true, rules: themeRules(1),
      colors: { "editor.foreground": "#BCBEC4" } });
  };
})();

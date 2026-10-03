# Third-party notices

Third-party code compiled into the Watchtower CLI beyond ordinary Go module
dependencies: the tree-sitter runtime and the grammars the code index
(`internal/codeindex`) parses with. Each grammar module comes from
[go-sitter-forest](https://github.com/alexaandru/go-sitter-forest), which
wraps the upstream grammar's generated `parser.c` (and `scanner.c` where the
grammar has one) in a Go package; the upstream grammar's own licence applies
to that C code, the forest licence to the Go wrapper.

An untagged build carries the Go, Python and Swift grammars; the release build
(`-tags codegrammars`) carries every grammar below. A grammar joins this file
in the same change that adds its `internal/codeindex/grammar_<id>.go`.

Markdown, YAML, TOML, JSON, HTML, CSS, SCSS and Dockerfiles are indexed by
scanners in the package itself, with no grammar; Vue and Svelte files are
parsed with the JavaScript and TypeScript grammars listed below. None of them
adds a component to this file.

## Runtime

| Component | Go module | Version | Licence | Upstream |
|---|---|---|---|---|
| go-tree-sitter (Go binding, vendors the tree-sitter C library) | `github.com/tree-sitter/go-tree-sitter` | v0.25.0 | MIT | https://github.com/tree-sitter/go-tree-sitter |
| tree-sitter C library (vendored in the binding's `src/`) | — | as vendored by go-tree-sitter v0.25.0 | MIT | https://github.com/tree-sitter/tree-sitter |
| ICU subset (vendored in the binding's `src/unicode/`) | — | as vendored by go-tree-sitter v0.25.0 | Unicode / ICU licence (ICU 58 and later) | https://github.com/unicode-org/icu |

## Grammars

| Language | Go module | Version | Wrapper licence | Grammar licence | Upstream grammar |
|---|---|---|---|---|---|
| Bash | `github.com/alexaandru/go-sitter-forest/bash` | v1.9.6 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-bash |
| C | `github.com/alexaandru/go-sitter-forest/c` | v1.9.4 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-c |
| C# | `github.com/alexaandru/go-sitter-forest/c_sharp` | v1.9.6 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-c-sharp |
| C++ | `github.com/alexaandru/go-sitter-forest/cpp` | v1.9.5 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-cpp |
| Clojure | `github.com/alexaandru/go-sitter-forest/clojure` | v1.9.1 | MIT | CC0-1.0 (below) | https://github.com/sogaiu/tree-sitter-clojure |
| Dart | `github.com/alexaandru/go-sitter-forest/dart` | v1.9.4 | MIT | MIT | https://github.com/UserNobody14/tree-sitter-dart |
| Elixir | `github.com/alexaandru/go-sitter-forest/elixir` | v1.9.5 | MIT | Apache-2.0 and MIT (below) | https://github.com/elixir-lang/tree-sitter-elixir |
| Elm | `github.com/alexaandru/go-sitter-forest/elm` | v1.9.1 | MIT | MIT | https://github.com/elm-tooling/tree-sitter-elm |
| Erlang | `github.com/alexaandru/go-sitter-forest/erlang` | v1.9.7 | MIT | Apache-2.0 (below) | https://github.com/WhatsApp/tree-sitter-erlang |
| Go | `github.com/alexaandru/go-sitter-forest/go` | v1.9.4 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-go |
| GraphQL | `github.com/alexaandru/go-sitter-forest/graphql` | v1.9.0 | MIT | MIT | https://github.com/bkegley/tree-sitter-graphql |
| Groovy | `github.com/alexaandru/go-sitter-forest/groovy` | v1.9.4 | MIT | MIT | https://github.com/murtaza64/tree-sitter-groovy |
| Haskell | `github.com/alexaandru/go-sitter-forest/haskell` | v1.9.2 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-haskell |
| HCL / Terraform | `github.com/alexaandru/go-sitter-forest/hcl` | v1.9.3 | MIT | Apache-2.0 (below) | https://github.com/tree-sitter-grammars/tree-sitter-hcl |
| Java | `github.com/alexaandru/go-sitter-forest/java` | v1.9.5 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-java |
| JavaScript | `github.com/alexaandru/go-sitter-forest/javascript` | v1.9.2 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-javascript |
| Julia | `github.com/alexaandru/go-sitter-forest/julia` | v1.9.10 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-julia |
| Kotlin | `github.com/alexaandru/go-sitter-forest/kotlin` | v1.9.4 | MIT | MIT | https://github.com/fwcd/tree-sitter-kotlin |
| Lua | `github.com/alexaandru/go-sitter-forest/lua` | v1.9.3 | MIT | MIT | https://github.com/tree-sitter-grammars/tree-sitter-lua |
| Nim | `github.com/alexaandru/go-sitter-forest/nim` | v1.9.1 | MIT | MPL-2.0 (below) | https://github.com/alaviss/tree-sitter-nim |
| Objective-C | `github.com/alexaandru/go-sitter-forest/objc` | v1.9.1 | MIT | MIT | https://github.com/tree-sitter-grammars/tree-sitter-objc |
| OCaml | `github.com/alexaandru/go-sitter-forest/ocaml` | v1.9.6 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-ocaml |
| Perl | `github.com/alexaandru/go-sitter-forest/perl` | v1.9.9 | MIT | MIT | https://github.com/tree-sitter-perl/tree-sitter-perl |
| PHP | `github.com/alexaandru/go-sitter-forest/php` | v1.9.5 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-php |
| Protocol Buffers | `github.com/alexaandru/go-sitter-forest/proto` | v1.9.1 | MIT | MIT | https://github.com/coder3101/tree-sitter-proto |
| Python | `github.com/alexaandru/go-sitter-forest/python` | v1.9.10 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-python |
| R | `github.com/alexaandru/go-sitter-forest/r` | v1.9.6 | MIT | MIT | https://github.com/r-lib/tree-sitter-r |
| Ruby | `github.com/alexaandru/go-sitter-forest/ruby` | v1.9.3 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-ruby |
| Rust | `github.com/alexaandru/go-sitter-forest/rust` | v1.9.13 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-rust |
| Scala | `github.com/alexaandru/go-sitter-forest/scala` | v1.9.8 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-scala |
| SQL | `github.com/alexaandru/go-sitter-forest/sql` | v1.9.13 | MIT | MIT | https://github.com/DerekStride/tree-sitter-sql |
| Swift | `github.com/alexaandru/go-sitter-forest/swift` | v1.9.5 | MIT | MIT | https://github.com/alex-pinkus/tree-sitter-swift |
| TSX | `github.com/alexaandru/go-sitter-forest/tsx` | v1.9.2 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-typescript |
| TypeScript | `github.com/alexaandru/go-sitter-forest/typescript` | v1.9.4 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-typescript |
| Zig | `github.com/alexaandru/go-sitter-forest/zig` | v1.9.4 | MIT | MIT | https://github.com/tree-sitter-grammars/tree-sitter-zig |

Licence texts and notices follow the tables: every copyright line, the MIT
text once, the full Apache-2.0 text with the Elixir NOTICE, the MPL-2.0 source
pointer for Nim and the ICU notice. This file ships in the app bundle
(`Contents/Resources/THIRD_PARTY_NOTICES.md`, copied by `scripts/build-app.sh`).

The queries under `internal/codeindex/queries/` are Watchtower's own; those
that start from an upstream grammar's `tags.scm` say so in their header and
are derived works under that grammar's licence listed above.
Their headers name what they changed from upstream (Apache-2.0 §4(b)).

## Copyright notices

Each line below is reproduced from the file named after it: the grammar's
upstream licence (as its repository's default branch reads it), its NOTICE,
or the header of a C source in the Go module. Every grammar module's Go
wrapper adds the forest's own MIT notice, from each module's `LICENSE`:

    Copyright (c) 2019 Maxim Sukharev, 2024 Alex Ungur

- **go-tree-sitter** (MIT), from the module's `LICENSE`:
  - Copyright (c) 2024 Amaan Qureshi <amaanq12@gmail.com> <!-- leak-check:allow -->
- **tree-sitter C library** (MIT), from the upstream LICENSE:
  - Copyright (c) 2018 Max Brunsfeld
- **ICU subset**: see "Unicode / ICU licence" below.
- **Bash**, from the upstream LICENSE:
  - Copyright (c) 2017 Max Brunsfeld
- **C**, from the upstream LICENSE:
  - Copyright (c) 2014 Max Brunsfeld
- **C#**, from the upstream LICENSE:
  - Copyright (c) 2014-2023 Max Brunsfeld, Damien Guard, Amaan Qureshi, and contributors.
- **C++**, from the upstream LICENSE:
  - Copyright (c) 2014 Max Brunsfeld
- **Clojure**: none: dedicated to the public domain (CC0 1.0, upstream COPYING.txt).
- **Dart**, from the upstream LICENSE:
  - Copyright (c) 2020-2023 UserNobody14 and others
- **Elixir**, from the upstream NOTICE, reproduced below:
  - Copyright (c) 2018-2021 Max Brunsfeld
  - Copyright (c) 2021 Anantha Kumaran
  - Copyright 2021 The Elixir Team
- **Elm**, from the upstream LICENSE:
  - Copyright (c) 2018 Kolja Lampe
- **Erlang**, from the module's `scanner.c` header; the upstream LICENSE is the bare Apache-2.0 text:
  - Copyright (c) Meta Platforms, Inc. and affiliates.
- **Go**, from the upstream LICENSE:
  - Copyright (c) 2014 Max Brunsfeld
- **GraphQL**, from the upstream LICENSE:
  - Copyright (c) 2021 bkegley
- **Groovy**, from the upstream LICENSE:
  - Copyright (c) 2024 Murtaza Javaid
- **Haskell**, from the upstream LICENSE:
  - Copyright (c) 2014 Max Brunsfeld
- **HCL / Terraform**: none: the upstream LICENSE is the bare Apache-2.0 text and the module's C sources carry no copyright line.
- **Java**, from the upstream LICENSE:
  - Copyright (c) 2017 Ayman Nadeem
- **JavaScript**, from the upstream LICENSE:
  - Copyright (c) 2014 Max Brunsfeld
- **Julia**, from the upstream LICENSE:
  - Copyright (c) 2018 Max Brunsfeld, GitHub
- **Kotlin**, from the upstream LICENSE:
  - Copyright (c) 2019 fwcd
- **Lua**, from the upstream LICENSE:
  - Copyright (c) 2021 Munif Tanjim
- **Nim**, from the module's `scanner.c` header; the upstream LICENSE.txt is the bare MPL-2.0 text:
  - Copyright (c) 2023 Leorize <leorize+oss@disroot.org> <!-- leak-check:allow -->
- **Objective-C**, from the upstream LICENSE:
  - Copyright (c) 2023 Amaan Qureshi <amaanq12@gmail.com> <!-- leak-check:allow -->
- **OCaml**, from the upstream LICENSE:
  - Copyright (c) 2020 Max Brunsfeld and Pieter Goetschalckx
- **Perl**, from the upstream LICENSE:
  - Copyright 2025 Avishai "Veesh" Goldman
- **PHP**, from the upstream LICENSE:
  - Copyright (c) 2017 Josh Vera, GitHub
  - Copyright (c) 2019 Max Brunsfeld, Amaan Qureshi, Christian Frøystad, Caleb White
- **Protocol Buffers**, from the upstream LICENSE:
  - Copyright (c) 2024-2025 Mohammad Ashar Khan
- **Python**, from the upstream LICENSE:
  - Copyright (c) 2016 Max Brunsfeld
- **R**, from the upstream LICENSE:
  - Copyright (c) 2025 tree-sitter-r authors
- **Ruby**, from the upstream LICENSE:
  - Copyright (c) 2016 Rob Rix
- **Rust**, from the upstream LICENSE:
  - Copyright (c) 2017 Maxim Sokolov
- **Scala**, from the upstream LICENSE:
  - Copyright (c) 2018 Max Brunsfeld and GitHub
- **SQL**, from the upstream LICENSE:
  - Copyright (c) 2021 Derek Stride
- **Swift**, from the upstream LICENSE:
  - Copyright (c) 2021 alex-pinkus
- **TSX**, from the upstream LICENSE:
  - Copyright (c) 2017 Max Brunsfeld
- **TypeScript**, from the upstream LICENSE:
  - Copyright (c) 2017 Max Brunsfeld
- **Zig**, from the upstream LICENSE:
  - Copyright (c) 2024 Amaan Qureshi <amaanq12@gmail.com> <!-- leak-check:allow -->

## MIT License

The text of the MIT licence that the tree-sitter runtime, every grammar's Go
wrapper and every grammar marked MIT above are under, each with its
copyright line above (reproduced from the forest modules' `LICENSE`):

```text
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Apache License 2.0

The Elixir grammar's non-generated files (its `scanner.c` among them) and the
Erlang and HCL grammars are under this licence; the full text, reproduced
from the Erlang grammar's upstream LICENSE:

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

### NOTICE files

The Elixir grammar's upstream NOTICE, reproduced in full. The Erlang and HCL
repositories carry no NOTICE file.

```text
LEGAL NOTICE INFORMATION
------------------------

All the files in this distribution are copyright to the terms below.

== All files in src/ except scanner.cc (generated by tree-sitter-cli)

Copyright (c) 2018-2021 Max Brunsfeld

The MIT License (MIT)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

== Some file fragments in test/corpus/

Copyright (c) 2021 Anantha Kumaran

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

== All other files

Copyright 2021 The Elixir Team

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## Mozilla Public License 2.0 (Nim)

The Nim grammar's `parser.c` and `scanner.c` are Covered Software under the
Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/), compiled in
unmodified. Their source code is available from the upstream repository,
https://github.com/alaviss/tree-sitter-nim, and as the Go module
`github.com/alexaandru/go-sitter-forest/nim` v1.9.1.

## CC0 1.0 (Clojure)

The Clojure grammar is dedicated to the public domain under CC0 1.0 Universal
(https://creativecommons.org/publicdomain/zero/1.0/); no notice is required.

## Unicode / ICU licence

The ICU subset vendored in go-tree-sitter's `src/unicode/`, under the notice
reproduced from that directory's `LICENSE` (its first section, which covers
ICU itself):

```text
COPYRIGHT AND PERMISSION NOTICE (ICU 58 and later)

Copyright © 1991-2019 Unicode, Inc. All rights reserved.
Distributed under the Terms of Use in https://www.unicode.org/copyright.html.

Permission is hereby granted, free of charge, to any person obtaining
a copy of the Unicode data files and any associated documentation
(the "Data Files") or Unicode software and any associated documentation
(the "Software") to deal in the Data Files or Software
without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, and/or sell copies of
the Data Files or Software, and to permit persons to whom the Data Files
or Software are furnished to do so, provided that either
(a) this copyright and permission notice appear with all copies
of the Data Files or Software, or
(b) this copyright and permission notice appear in associated
Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT OF THIRD PARTY RIGHTS.
IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS
NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL
DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE,
DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder
shall not be used in advertising or otherwise to promote the sale,
use or other dealings in these Data Files or Software without prior
written authorization of the copyright holder.
```

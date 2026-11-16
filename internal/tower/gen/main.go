// Command gen writes the Swift side of the tower interface from the Go
// types registered in internal/tower/commands: the types, the command list,
// the interface version (Swift and Go) and the golden round-trip test.
//
//	go run ./internal/tower/gen -root <repo>         write the files
//	go run ./internal/tower/gen -root <repo> -check  exit 1 with a diff when they differ
//
// See docs/features/tower-interface.md, "Generator".
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
	"watchtower/internal/tower/commands"
	"watchtower/internal/tower/gen/testdata/sample"
)

// The generated files, relative to the repository root.
const (
	generatedDir     = "WatchtowerInterface/Sources/WatchtowerInterface/Generated/"
	typesPath        = generatedDir + "TowerTypes.swift"
	commandsPath     = generatedDir + "TowerCommands.swift"
	versionSwiftPath = generatedDir + "InterfaceVersion.swift"
	goldenTestsPath  = "WatchtowerInterface/Tests/WatchtowerInterfaceTests/Generated/GoldenRoundTripTests.swift"
	sampleTypesPath  = "WatchtowerInterface/Tests/WatchtowerInterfaceTests/Generated/SampleTypes.swift"
	versionGoPath    = "internal/tower/interface_version.go"
)

func main() {
	root := flag.String("root", ".", "the repository root")
	check := flag.Bool("check", false, "compare instead of writing; exit 1 with a diff when anything differs")
	flag.Parse()

	var r tower.Registry
	commands.RegisterAll(&r, commands.Deps{})
	files, err := generate(&r)
	if err != nil {
		fmt.Fprintln(os.Stderr, "gen:", err)
		os.Exit(1)
	}
	if *check {
		same, err := checkFiles(*root, files)
		if err != nil {
			fmt.Fprintln(os.Stderr, "gen:", err)
			os.Exit(1)
		}
		if !same {
			fmt.Fprintln(os.Stderr, "gen: the generated interface is out of date; run make gen-interface")
			os.Exit(1)
		}
		return
	}
	if err := writeFiles(*root, files); err != nil {
		fmt.Fprintln(os.Stderr, "gen:", err)
		os.Exit(1)
	}
}

// envelopeTypes are generated besides the commands' own types.
var envelopeTypes = []reflect.Type{reflect.TypeFor[api.Request](), reflect.TypeFor[api.Response]()}

// roots are the envelope and every command's request and response.
func roots(r *tower.Registry) []reflect.Type {
	out := append([]reflect.Type(nil), envelopeTypes...)
	for _, c := range r.Commands() {
		out = append(out, c.Req, c.Resp)
	}
	return out
}

// generate returns every generated file by its repository-relative path.
func generate(r *tower.Registry) (map[string][]byte, error) {
	c, err := collect(roots(r))
	if err != nil {
		return nil, err
	}
	types := c.render()
	// The generator's sample types, compiled into the Swift tests so its
	// output runs, not only typechecks (NilCollectionsTests).
	sampleTypes, err := swiftTypes([]reflect.Type{reflect.TypeFor[sample.Sample]()})
	if err != nil {
		return nil, err
	}
	sampleTypes = bytes.Replace(sampleTypes, []byte("import Foundation\n"), []byte("import Foundation\nimport WatchtowerInterface\n"), 1)
	cmds := commandsSwift(r.Commands())
	version := interfaceVersion(types, cmds)
	enum := ""
	for _, n := range c.sorted() {
		if n.enum {
			enum = n.goType.Name()
			break
		}
	}
	return map[string][]byte{
		typesPath:        types,
		commandsPath:     cmds,
		versionSwiftPath: []byte(fmt.Sprintf("%s\n\n/// The generated interface's version: the first 16 hex characters of the\n/// SHA-256 of TowerTypes.swift and TowerCommands.swift; tower.hello answers it.\npublic enum InterfaceVersion {\n    public static let current = %q\n}\n", header, version)),
		versionGoPath:    []byte(fmt.Sprintf("%s\n\npackage tower\n\n// InterfaceVersion is the generated interface's version (the first 16 hex\n// characters of the SHA-256 of the generated TowerTypes.swift and\n// TowerCommands.swift), answered by tower.hello.\nconst InterfaceVersion = %q\n", header, version)),
		goldenTestsPath:  goldenTests(goldenTypes(r), enum),
		sampleTypesPath:  sampleTypes,
	}, nil
}

// interfaceVersion is the first 16 hex characters of the SHA-256 of the
// generated types and commands.
func interfaceVersion(types, cmds []byte) string {
	h := sha256.New()
	h.Write(types)
	h.Write(cmds)
	return hex.EncodeToString(h.Sum(nil))[:16]
}

func commandsSwift(cmds []tower.Command) []byte {
	var b strings.Builder
	b.WriteString(header + `

import Foundation

/// Every registered tower command.
public enum TowerCommand: String, CaseIterable, Sendable {
`)
	for _, c := range cmds {
		fmt.Fprintf(&b, "    case %s = %q\n", swiftIdent(lowerCamel(c.Name)), c.Name)
	}
	b.WriteString("\n    /// True for a read: it carries no request_id and is never ledgered.\n")
	b.WriteString("    public var isRead: Bool {\n        switch self {\n")
	for _, c := range cmds {
		fmt.Fprintf(&b, "        case .%s: %t\n", swiftIdent(lowerCamel(c.Name)), c.Spec.Read)
	}
	b.WriteString("        }\n    }\n}\n")
	return []byte(b.String())
}

func writeFiles(root string, files map[string][]byte) error {
	for _, path := range sortedPaths(files) {
		full := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(full, files[path], 0o644); err != nil {
			return err
		}
	}
	return nil
}

// checkFiles writes files into a temporary folder and diffs each against
// root, printing a unified diff for every one that differs.
func checkFiles(root string, files map[string][]byte) (bool, error) {
	tmp, err := os.MkdirTemp("", "gen-interface-")
	if err != nil {
		return false, err
	}
	defer func() { _ = os.RemoveAll(tmp) }()
	if err := writeFiles(tmp, files); err != nil {
		return false, err
	}
	same := true
	for _, path := range sortedPaths(files) {
		old := filepath.Join(root, filepath.FromSlash(path))
		have, err := os.ReadFile(old)
		switch {
		case errors.Is(err, os.ErrNotExist):
			old = os.DevNull
		case err != nil:
			return false, err
		}
		if bytes.Equal(have, files[path]) {
			continue
		}
		same = false
		cmd := exec.Command("diff", "-u", "-L", "a/"+path, "-L", "b/"+path, old, filepath.Join(tmp, filepath.FromSlash(path)))
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 1 {
				fmt.Fprintf(os.Stderr, "%s differs (diff failed: %v)\n", path, err)
			}
		}
	}
	return same, nil
}

func sortedPaths(files map[string][]byte) []string {
	out := make([]string, 0, len(files))
	for p := range files {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

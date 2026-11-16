package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"watchtower/internal/tower"
	"watchtower/internal/tower/commands"
	"watchtower/internal/tower/gen/testdata/sample"
)

var update = flag.Bool("update", false, "rewrite testdata/sample.swift.golden")

func TestGenerate_SampleMatchesGolden(t *testing.T) {
	got, err := swiftTypes([]reflect.Type{reflect.TypeFor[sample.Sample]()})
	if err != nil {
		t.Fatal(err)
	}
	golden := filepath.Join("testdata", "sample.swift.golden")
	if *update {
		if err := os.WriteFile(golden, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("generated sample differs from %s (go test -run TestGenerate_SampleMatchesGolden -update):\n%s", golden, got)
	}
}

// Sample is a struct the generator must refuse: time.Time has no mapping.
type Sample struct {
	At time.Time `json:"at"`
}

func TestGenerate_TimeFieldFails(t *testing.T) {
	_, err := swiftTypes([]reflect.Type{reflect.TypeFor[Sample]()})
	if err == nil || !strings.Contains(err.Error(), "Sample.At") {
		t.Fatalf("err = %v, want one naming Sample.At", err)
	}
}

func TestGenerate_UnsupportedKindsFail(t *testing.T) {
	type Bytes struct {
		B []byte `json:"b"`
	}
	type Any struct {
		A any `json:"a"`
	}
	type IntKey struct {
		M map[int]string `json:"m"`
	}
	for _, typ := range []reflect.Type{reflect.TypeFor[Bytes](), reflect.TypeFor[Any](), reflect.TypeFor[IntKey]()} {
		if _, err := swiftTypes([]reflect.Type{typ}); err == nil || !strings.Contains(err.Error(), typ.Name()+".") {
			t.Errorf("%s: err = %v, want one naming the field", typ.Name(), err)
		}
	}
}

// Go writes a nil slice or map without omitempty as null; the generated
// Swift decodes it (or a missing key) as empty. testdata/sample_nil.json is
// that Go output, which the Swift NilCollectionsTests decode.
func TestGenerate_NilCollectionsDecodeAsEmpty(t *testing.T) {
	got, err := json.Marshal(sample.Sample{})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(got, []byte(`"tags":null`)) || !bytes.Contains(got, []byte(`"scores":null`)) {
		t.Fatalf("a nil slice and map should marshal as null: %s", got)
	}
	want, err := os.ReadFile(filepath.Join("testdata", "sample_nil.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(bytes.TrimSpace(want)) != string(got) {
		t.Errorf("testdata/sample_nil.json is not Go's encoding of sample.Sample{}:\n file %s\n  got %s", bytes.TrimSpace(want), got)
	}
	swift, err := swiftTypes([]reflect.Type{reflect.TypeFor[sample.Sample]()})
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{
		"self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []",
		"self.scores = try container.decodeIfPresent([String: Int].self, forKey: .scores) ?? [:]",
		"self.parent = try container.decodeIfPresent(Inner.self, forKey: .parent)",
		"self.count = try container.decode(Int.self, forKey: .count)",
	} {
		if !strings.Contains(string(swift), line) {
			t.Errorf("generated Sample lacks %q", line)
		}
	}
}

type Clash string

func (Clash) EnumValues() []string { return []string{"not_found", "notFound"} }

type Digit string

func (Digit) EnumValues() []string { return []string{"1h"} }

func TestGenerate_EnumValuesWithoutACaseOfTheirOwnFail(t *testing.T) {
	type WithClash struct {
		C Clash `json:"c"`
	}
	type WithDigit struct {
		D Digit `json:"d"`
	}
	for _, typ := range []reflect.Type{reflect.TypeFor[WithClash](), reflect.TypeFor[WithDigit]()} {
		if _, err := swiftTypes([]reflect.Type{typ}); err == nil || !strings.Contains(err.Error(), "no Swift case") {
			t.Errorf("%s: err = %v, want a case-name error", typ.Name(), err)
		}
	}
}

func registry() *tower.Registry {
	var r tower.Registry
	commands.RegisterAll(&r, commands.Deps{})
	return &r
}

func TestGenerate_HeaderOnEveryFile(t *testing.T) {
	files, err := generate(registry())
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("no files generated")
	}
	for path, content := range files {
		if !strings.HasPrefix(string(content), header+"\n") {
			t.Errorf("%s does not start with %q", path, header)
		}
	}
}

func TestEveryRegisteredTypeHasAGolden(t *testing.T) {
	types := goldenTypes(registry())
	names := map[string]bool{}
	for _, typ := range types {
		names[typ.Name()] = true
	}
	for _, want := range []string{"Request", "Response", "ChangedEvent", "HelloResponse", "PingResponse", "PauseRequest", "PauseResponse"} {
		if !names[want] {
			t.Errorf("golden types miss %s", want)
		}
	}
	for _, typ := range types {
		path := filepath.Join("..", "api", "testdata", typ.Name()+".json")
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Errorf("%s: %v", typ.Name(), err)
			continue
		}
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		v := reflect.New(typ).Interface()
		if err := dec.Decode(v); err != nil {
			t.Errorf("%s: decode: %v", path, err)
			continue
		}
		again, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		if a, b := canonicalJSON(t, raw), canonicalJSON(t, again); a != b {
			t.Errorf("%s does not round-trip:\n file %s\n  got %s", path, a, b)
		}
	}
}

func canonicalJSON(t *testing.T, raw []byte) string {
	t.Helper()
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func TestInterfaceVersionIsTheOutputHash(t *testing.T) {
	files, err := generate(registry())
	if err != nil {
		t.Fatal(err)
	}
	want := interfaceVersion(files[typesPath], files[commandsPath])
	if len(want) != 16 {
		t.Fatalf("version %q is not 16 hex chars", want)
	}
	if tower.InterfaceVersion != want {
		t.Errorf("tower.InterfaceVersion = %q, the generated output hashes to %q (run make gen-interface)", tower.InterfaceVersion, want)
	}
	if !strings.Contains(string(files[versionSwiftPath]), `"`+want+`"`) {
		t.Errorf("%s does not carry %q", versionSwiftPath, want)
	}
	if !strings.Contains(string(files[versionGoPath]), `"`+want+`"`) {
		t.Errorf("%s does not carry %q", versionGoPath, want)
	}
}

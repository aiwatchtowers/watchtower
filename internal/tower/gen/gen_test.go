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
	r := registry()
	types := goldenTypes(r)
	names := map[string]bool{}
	for _, typ := range types {
		names[typ.Name()] = true
	}
	for _, c := range r.Commands() {
		for _, typ := range []reflect.Type{c.Req, c.Resp} {
			if typ.NumField() > 0 && !names[typ.Name()] {
				t.Errorf("%s: %s has fields but no golden", c.Name, typ.Name())
			}
		}
	}
	for _, want := range []string{"Request", "Response", "HelloResponse", "PingResponse"} {
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

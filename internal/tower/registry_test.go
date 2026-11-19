package tower

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"watchtower/internal/tower/api"
)

func TestRegistry_CommandsSpecsAndOverrides(t *testing.T) {
	r := &Registry{}
	RegisterBuiltins(r)
	Register(r, "test.act", func(context.Context, *Ctx, testParams) (testResult, error) { return testResult{}, nil },
		Spec{
			Grant: "static",
			IdempotentFor: func(p json.RawMessage) (bool, error) {
				var v testParams
				err := json.Unmarshal(p, &v)
				return v.Note == "done", err
			},
			GrantFor: func(json.RawMessage) (string, error) { return "inbox", nil },
		})

	var names []string
	for _, c := range r.Commands() {
		names = append(names, c.Name)
	}
	if !reflect.DeepEqual(names, []string{"test.act", "tower.hello", "tower.ping"}) {
		t.Fatalf("commands = %v", names)
	}
	hello := r.Commands()[1]
	if hello.Req != reflect.TypeFor[api.HelloRequest]() || hello.Resp != reflect.TypeFor[api.HelloResponse]() || !hello.Spec.Read {
		t.Fatalf("hello = %+v", hello)
	}

	for note, want := range map[string]bool{"done": true, "approve": false} {
		got, err := r.IsIdempotent("test.act", json.RawMessage(`{"note":"`+note+`"}`))
		if err != nil || got != want {
			t.Errorf("IsIdempotent(%s) = %v, %v; want %v", note, got, err, want)
		}
	}
	if g, err := r.GrantFor("test.act", nil); err != nil || g != "inbox" {
		t.Errorf("GrantFor = %q, %v", g, err)
	}
	if _, err := r.IsIdempotent("test.nope", nil); err == nil {
		t.Error("IsIdempotent of an unknown command did not fail")
	}

	defer func() {
		if recover() == nil {
			t.Fatal("a duplicate name did not panic")
		}
	}()
	RegisterBuiltins(r)
}

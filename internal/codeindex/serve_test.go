package codeindex

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// streamLines splits a stream into per-run groups of decoded lines, each
// group ending with its done line.
func streamLines(t *testing.T, out string) [][]map[string]any {
	t.Helper()
	var runs [][]map[string]any
	var cur []map[string]any
	for line := range strings.SplitSeq(strings.TrimSuffix(out, "\n"), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("line %q: %v", line, err)
		}
		cur = append(cur, m)
		if m["done"] == true {
			runs = append(runs, cur)
			cur = nil
		}
	}
	if cur != nil {
		t.Fatalf("lines after the last done line: %v", cur)
	}
	return runs
}

func TestServe_OneRunPerLineEachEndingInDone(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.md", []byte("# A\n## B\n"))
	write(t, root, "b.md", []byte("# C\n"))
	in := strings.NewReader("a.md\n\n\nb.md\tgone.md\n")
	var out bytes.Buffer
	if err := Serve(context.Background(), root, 2, in, &out); err != nil {
		t.Fatalf("Serve: %v", err)
	}
	runs := streamLines(t, out.String())
	if len(runs) != 2 {
		t.Fatalf("%d runs, want 2 (empty lines are no-ops):\n%s", len(runs), out.String())
	}
	if len(runs[0]) != 2 || runs[0][0]["file"] != "a.md" || runs[0][1]["files"] != 1.0 || runs[0][1]["symbols"] != 2.0 {
		t.Errorf("run 1 = %v", runs[0])
	}
	files := map[any]map[string]any{}
	for _, m := range runs[1][:len(runs[1])-1] {
		files[m["file"]] = m
	}
	if len(files) != 2 || files["gone.md"]["deleted"] != true || files["b.md"]["lang"] != "markdown" {
		t.Errorf("run 2 = %v", runs[1])
	}
	if d := runs[1][len(runs[1])-1]; d["files"] != 2.0 || d["symbols"] != 1.0 {
		t.Errorf("run 2 done = %v", d)
	}
}

func TestStream_CancelledRunHasNoDoneLine(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.md", []byte("# A\n"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var out bytes.Buffer
	if err := Stream(ctx, root, nil, 2, &out); err == nil {
		t.Fatal("want ctx's error")
	}
	if strings.Contains(out.String(), `"done"`) {
		t.Fatalf("a cancelled run wrote a done line: %s", out.String())
	}
}

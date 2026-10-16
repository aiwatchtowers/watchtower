package sessionfeed

import (
	"encoding/json"
	"fmt"
	"strings"
)

func jsonLine(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b) + "\n"
}

func userStr(uuid, text string) string {
	return jsonLine(map[string]any{"type": "user", "uuid": uuid, "timestamp": "2026-10-01T10:00:00Z",
		"message": map[string]any{"role": "user", "content": text}})
}

func userBlocks(uuid string, blocks ...map[string]any) string {
	return jsonLine(map[string]any{"type": "user", "uuid": uuid, "timestamp": "2026-10-01T10:00:00Z",
		"message": map[string]any{"role": "user", "content": blocks}})
}

func metaUser(uuid, text string) string {
	return jsonLine(map[string]any{"type": "user", "uuid": uuid, "isMeta": true,
		"message": map[string]any{"role": "user", "content": text}})
}

func assistantRec(uuid, msgID string, blocks ...map[string]any) string {
	return jsonLine(map[string]any{"type": "assistant", "uuid": uuid, "timestamp": "2026-10-01T10:00:01Z",
		"message": map[string]any{"id": msgID, "role": "assistant", "content": blocks}})
}

func textB(s string) map[string]any { return map[string]any{"type": "text", "text": s} }

func briefAttachment(uuid, event, stdout string) string {
	return jsonLine(map[string]any{"type": "attachment", "uuid": uuid, "timestamp": "2026-10-01T09:00:00Z",
		"attachment": map[string]any{"type": "hook_success", "hookEvent": event, "stdout": stdout}})
}

func join(lines ...string) string { return strings.Join(lines, "") }

func repeat(c string, n int) string { return strings.Repeat(c, n) }

func askLine(id int) string {
	return fmt.Sprintf("Ask #%d answered (Q: A) — read it with get_ask %d using the skill.", id, id)
}

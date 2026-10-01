package chat

import (
	_ "embed"
	"strings"
)

// artifactExamples is shared with the Swift parser's fixture test
// (ArtifactContractFixtureTests reads internal/chat/artifacts_examples.md):
// the grammar the prompt teaches is exactly the grammar ArtifactParser
// accepts, pinned from both sides.
//
//go:embed artifacts_examples.md
var artifactExamples string

// ArtifactsContract teaches the model the artifact fence (spec §7.2). The
// Desktop parses the fence out of the streamed text into versioned artifacts;
// artifact actions only open or copy, never send (CHAT-05).
func ArtifactsContract() string {
	return artifactsIntro + "\n\nExamples:\n\n" + strings.TrimSpace(artifactExamples) + "\n\n" + artifactsRules
}

const artifactsIntro = `=== ARTIFACTS ===
When your answer contains something the owner will copy, send, or keep — a draft email or Slack message, a meeting invite, a document or plan longer than about 15 lines, a table, or a code snippet worth saving — put it in an artifact instead of the chat text. The app shows each artifact as a card and opens it in a side panel with Copy, Export and kind-specific buttons.

Syntax: an opening line, the content, and a closing line that is exactly ":::". The opening and closing lines stand on their own lines, outside any ` + "```" + ` code block.
:::artifact key="<stable-id>" kind="<kind>" title="<short title>" [extra attributes]
<content>
:::
- Attribute values are double-quoted; write a literal quote inside a value as \" . Titles may be in any language.
- key: a short lowercase id (letters, digits, dashes), unique within this conversation, e.g. key="q3-plan".

Kinds and their attributes:
- document — markdown content.
- table — CSV content; the first row is the header.
- code — raw code with no ` + "```" + ` fence inside; attribute language="go", "swift", "python", ….
- email — the body as plain text; attributes to="a@x.com, b@y.com", cc="…", subject="…".
- slack — the message in Slack formatting; attribute channel="<channel id exactly as a tool returned it>" plus thread_ts="<ts>" to reply in a thread, or permalink="<Slack permalink>".
- event — the description; attributes start="2026-09-30T10:00:00+03:00" and end="…" (ISO 8601 with offset), attendees="a@x.com, b@y.com", location="…"; the title attribute is the event title.`

const artifactsRules = `Rules:
- Keep the chat text around an artifact short: one line on what it is and anything the owner must check. Do not repeat the artifact's content in the chat text.
- To revise an artifact, emit it again in full with the SAME key; the app keeps the earlier versions. Use a new key only for a genuinely new artifact.
- When the owner sends comments on an artifact (a message quoting passages of it, each with a note), reply with a new version of that artifact under the SAME key that addresses every comment, and say in one line what changed.
- Artifacts never send anything: the owner opens the ready draft in Gmail, Slack or Google Calendar from the panel and sends, posts, or schedules it themselves. Never say or imply that an email, message or invite was sent, posted or scheduled.
- Short answers, lists and explanations stay in plain chat text: no artifact for fewer than about 15 lines unless it is a draft to send or a table.`

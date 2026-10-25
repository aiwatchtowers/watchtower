# Media knowledge (images and links in the knowledge index)

## Codex image input

Checked 2026-10-25 with codex-cli 0.145.0 and `gpt-5.6-sol`: `codex exec ... -c features.view_image=false --image <png> -` with the prompt on stdin
answers a synthetic red square with an `agent_message` of "Red". Image input therefore works in our wiring, and
`(*CodexGenerator).GenerateWithImage` (`internal/codex/generator.go`) implements `digest.ImageGenerator`.

- argv is `execArgs(strong)` + the system-prompt file override + `--image <path> -`; prompts stay on stdin or in a 0600 file. `features.view_image=false`
  stays: that flag is the model's disk-reading tool, not image input.
- Strong tier always. The child starts in a fresh empty 0700 directory under the `digest.WithWorkDir` root, removed when the call returns; a call
  without the root fails before starting anything.
- Codex sniffs the file, so the media type argument is unused.

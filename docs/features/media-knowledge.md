# Media knowledge (images and links in the knowledge index)

## Codex image input

Checked 2026-10-25 with codex-cli 0.145.0 and `gpt-5.6-sol`: `codex exec ... -c features.view_image=false --image <png> -` with the prompt on stdin
answers a synthetic red square with an `agent_message` of "Red". Image input therefore works in our wiring, and
`(*CodexGenerator).GenerateWithImage` (`internal/codex/generator.go`) implements `digest.ImageGenerator`.

- argv is `execArgs(strong)` + the hardening below + `--image=<path>` (before the instructions override; a comma in the path is refused) + the system-prompt file override + `-`; prompts stay on stdin or in a 0600 file. `features.view_image=false`
  stays: that flag is the model's disk-reading tool, not image input.
- Strong tier always. The child starts in a fresh empty 0700 directory under the `digest.WithWorkDir` root, removed when the call returns; a call
  without the root fails before starting anything.
- Codex sniffs the file, so the media type argument is unused.
- Disabled for this call, beyond `execArgs` (shell, unified exec, view_image, computer_use, browser_use, apps, plugins): `web_search`, every MCP server in the
  owner's codex config (fail closed: an unreadable config means no child), and the features `multi_agent`, `image_generation`, `skill_search`, `hooks`.
- The image is checked first (`digest.CheckImageFile`: exists, regular file, within the input cap), so a missing image never goes out as a text-only prompt.
- Residual risk: the list is a denylist; a codex feature that becomes default-on in a later release is not disabled until it is added here and in `buildImageArgs`.

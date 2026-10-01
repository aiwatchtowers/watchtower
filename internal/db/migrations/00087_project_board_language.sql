-- +goose Up
-- Board language (board item #122): the language every session writes the
-- project's targets, intents and comments in. '' = follow the session (the
-- language the owner uses with the agent); otherwise a language name or tag
-- such as 'Russian' or 'pt-BR', validated by db.NormalizeBoardLanguage. Set by
-- `watchtower project update --board-language`, the Desktop project page
-- (through that command) and the project-session MCP `update_project`.
ALTER TABLE projects ADD COLUMN board_language TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE projects DROP COLUMN board_language;

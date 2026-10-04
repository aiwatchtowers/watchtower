-- +goose Up
-- Order a turn's Stop and its tool results by the turn they belong to, not
-- by when their hook processes started (board #368). Go is the only writer;
-- the Desktop never reads either column.
--
-- agent_turn_end: the Claude Code transcript's size in bytes when the sync
-- Stop hook last let a turn end; NULL = no Stop seen in this process run. A
-- main-thread PostToolUse whose tool call sits before it in the transcript
-- belongs to an ended turn and writes nothing.
-- agent_tool_run: 1 when the stored state was written by a main-thread
-- PostToolUse; the Stop hook replaces such a `working` whatever its time.
ALTER TABLE terminal_sessions ADD COLUMN agent_turn_end INTEGER;
ALTER TABLE terminal_sessions ADD COLUMN agent_tool_run INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN agent_tool_run;
ALTER TABLE terminal_sessions DROP COLUMN agent_turn_end;

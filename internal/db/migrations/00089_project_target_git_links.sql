-- +goose Up
-- Project targets link to the git work that carries them (board target #131,
-- PROJ-07 in docs/inventory/projects.md): `branch` is the git branch the
-- work happens on, `pr` the pull request (a number or a URL). Both are free
-- text set by the agent's create_targets/update_target; '' = not linked.
-- `watchtower project check` compares them with the folder's git state to
-- find board drift (a merged branch whose target is still open, a done
-- target whose branch is not merged). Personal targets never carry them.
ALTER TABLE targets ADD COLUMN branch TEXT NOT NULL DEFAULT '';
ALTER TABLE targets ADD COLUMN pr TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE targets DROP COLUMN pr;
ALTER TABLE targets DROP COLUMN branch;

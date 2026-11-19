-- +goose Up
-- Coach repo edits as pull requests: a repo_* Accept opens a GitHub PR instead
-- of writing the owner's working copy. pr_url = the PR an Accept opened ('' =
-- not a PR row); revert_pr_url = the PR a Rollback opened to undo it.
ALTER TABLE coach_proposals ADD COLUMN pr_url TEXT NOT NULL DEFAULT '';
ALTER TABLE coach_proposals ADD COLUMN revert_pr_url TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE coach_proposals DROP COLUMN revert_pr_url;
ALTER TABLE coach_proposals DROP COLUMN pr_url;

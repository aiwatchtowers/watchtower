-- +goose Up
-- A sent review round records how the owner closed it: 'changes' (Send) or
-- 'approved' (Approve); '' for rounds that predate the column or are not sent.
ALTER TABLE review_rounds ADD COLUMN outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'changes', 'approved'));

-- +goose Down
ALTER TABLE review_rounds DROP COLUMN outcome;

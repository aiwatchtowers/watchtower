-- +goose Up
-- Data-only cleanup: earlier builds of the target-link suggester wrote
-- external_ref values in a malformed "slack:<full permalink URL>" format
-- (kind prefix glued onto a raw URL) that nothing can resolve. Blank them.
--
-- Two guards around the blanking UPDATE, both required by table constraints:
--   1. CHECK (target_target_id IS NOT NULL OR external_ref != '') — a
--      malformed row with no target_target_id cannot be blanked, and a link
--      with neither side is meaningless, so delete it.
--   2. UNIQUE(source_target_id, target_target_id, external_ref, relation) —
--      blanking would collide when a clean ref-less duplicate of the same
--      link already exists, so delete the malformed duplicate instead.
DELETE FROM target_links
WHERE external_ref LIKE 'slack:http%'
  AND (
    target_target_id IS NULL
    OR EXISTS (
      SELECT 1 FROM target_links t2
      WHERE t2.source_target_id = target_links.source_target_id
        AND t2.target_target_id = target_links.target_target_id
        AND t2.relation = target_links.relation
        AND t2.external_ref = ''
    )
  );

UPDATE target_links SET external_ref = '' WHERE external_ref LIKE 'slack:http%';

-- +goose Down
-- Irreversible data cleanup: the malformed refs cannot be reconstructed. No-op.
SELECT 1;

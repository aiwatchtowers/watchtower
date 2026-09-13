-- +goose Up
-- The three "weekly"/"staggered" memory steps had no memo of having run.
-- dueForRewrite/dueForReflect are day-granular AND stateless (a pure hash of
-- the node id / workspace id against the UTC day number), so on their slot day
-- they answer "due" for EVERY daemon cycle — the same first
-- memory.semantic.rewrite_max_entities pages (ListMemoryNodes is ORDER BY id)
-- were re-rewritten by the strong model every ~70 minutes, and the weekly
-- reflection pass re-ran end to end every cycle of its slot day. The strong map
-- render had no gate at all: its WRITE is change-gated (Vault.WriteFile returns
-- early on byte-identical content) but the AI call that produced those bytes
-- ran once per cycle, forever.
--
-- memory_step_state is the shared memo: one row per (step, node_id), where
-- node_id is the entity id for the per-node 'rewrite' step and '' for the
-- workspace-wide 'reflect' and 'map' steps. last_run_at answers "already
-- attempted in this UTC day" for rewrite/reflect; fingerprint holds the sha256
-- of the rendered map prompt input, so the map skips the CALL when the input it
-- would render from is byte-identical to the one already rendered.
--
-- NO foreign key onto memory_nodes, deliberately: DropMemoryIndex disables FK
-- enforcement around its DELETE FROM memory_nodes precisely so the exempt side
-- tables survive, and a stale row for a deleted node is harmless here (it is
-- overwritten by the next stamp and read only by a step that iterates live
-- nodes). Nothing in this table carries a correctness claim that referential
-- integrity would protect.
--
-- Deliberately NOT added to DropMemoryIndex's delete list (MEM-02 exclusion,
-- alongside memory_node_stats / memory_entity_hints / memory_dispute_flags /
-- memory_engagement): this is runtime cadence state, not derivable from the
-- vault files. If `watchtower memory reindex` erased it, that routine
-- maintenance command would re-trigger the exact strong-tier cost spike this
-- table removes.
CREATE TABLE IF NOT EXISTS memory_step_state (
    step        TEXT NOT NULL,            -- 'rewrite' | 'reflect' | 'map'
    node_id     TEXT NOT NULL DEFAULT '', -- entity id for 'rewrite'; '' for the workspace-wide steps
    last_run_at TEXT NOT NULL DEFAULT '', -- RFC3339 UTC of the last ATTEMPT (rewrite/reflect)
    fingerprint TEXT NOT NULL DEFAULT '', -- sha256 of the map prompt input; '' for the other steps
    PRIMARY KEY (step, node_id)
);

-- +goose Down
DROP TABLE IF EXISTS memory_step_state;

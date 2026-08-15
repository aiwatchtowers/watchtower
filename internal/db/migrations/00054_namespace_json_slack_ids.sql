-- +goose Up
-- Migration 00048 namespaced every scalar Slack id column but deliberately left
-- JSON-embedded ids alone, so any row written before it still carries bare ids
-- that can never match a namespaced column again — silently, since every
-- consumer treats a miss as "no signal" rather than an error.
--
-- Raw Slack ids are alphanumeric and never contain ':', so `NOT GLOB '[0-9]*:*'`
-- identifies the not-yet-namespaced elements; already-namespaced ones are left
-- alone, which also makes this migration safe to re-run.
--
-- Driver note (verified against modernc.org/sqlite v1.49.1, the version
-- pinned in go.mod, and matched by the system sqlite3 CLI, so this is
-- upstream JSON1 behavior, not a modernc bug): json_each's `value` column
-- is a DECODED SQL value, not JSON source text. For a string element it is
-- the dequoted string, which is no longer valid JSON on its own — feeding
-- it back into json_type()/json_extract() as if it were JSON text throws
-- "malformed JSON" (e.g. json_type('C1') fails standalone, no table
-- involved, for the same reason). `je.type` (the column json_each already
-- provides) sidesteps this for the flat-array statements below, since it
-- reports the decoded type directly with no re-parse.
--
-- json_each.value for an OBJECT element (tracks.participants' shape) does
-- stay valid JSON text after decoding — objects/arrays round-trip, only
-- bare strings don't — but tracks.participants is unvalidated model JSON
-- (checked only for json.Valid before it's stored), so an element can be a
-- bare string instead of the expected object, or a field can hold a JSON
-- object/array where a string id is expected. The participants statements
-- below therefore never touch je.value for parsing at all: every
-- json_type()/json_extract() call addresses the OUTER document
-- (tracks.participants, already known valid JSON — the top-level WHERE
-- guards that) by a computed path (`'$[' || je.key || '].user_id'`)
-- instead of re-parsing the per-element fragment, which is what makes a
-- non-object element (path lookup on it just misses, no re-parse) and an
-- object/array-valued user_id (json_type on the path correctly reports
-- 'object'/'array', so it's skipped rather than stringified) both safe.

-- Flat arrays of ids.
UPDATE tracks
SET channel_ids = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
                THEN '1:' || je.value
            ELSE je.value
        END
    )
    FROM json_each(tracks.channel_ids) je
)
WHERE json_valid(channel_ids) AND json_type(channel_ids) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(tracks.channel_ids) je
      WHERE je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
  );

UPDATE user_profile
SET reports = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
                THEN '1:' || je.value
            ELSE je.value
        END
    )
    FROM json_each(user_profile.reports) je
)
WHERE json_valid(reports) AND json_type(reports) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(user_profile.reports) je
      WHERE je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
  );

UPDATE user_profile
SET peers = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
                THEN '1:' || je.value
            ELSE je.value
        END
    )
    FROM json_each(user_profile.peers) je
)
WHERE json_valid(peers) AND json_type(peers) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(user_profile.peers) je
      WHERE je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
  );

UPDATE user_profile
SET starred_channels = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
                THEN '1:' || je.value
            ELSE je.value
        END
    )
    FROM json_each(user_profile.starred_channels) je
)
WHERE json_valid(starred_channels) AND json_type(starred_channels) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(user_profile.starred_channels) je
      WHERE je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
  );

UPDATE user_profile
SET starred_people = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
                THEN '1:' || je.value
            ELSE je.value
        END
    )
    FROM json_each(user_profile.starred_people) je
)
WHERE json_valid(starred_people) AND json_type(starred_people) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(user_profile.starred_people) je
      WHERE je.type = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
  );

-- Array of participant objects: only $.user_id is rewritten, every other
-- field of the object is preserved. json_group_array(json_set(json(...)))
-- preserves the JSON subtype in this build (verified: json_type() on the
-- rebuilt array's elements reports 'object', not 'text' / double-encoded).
-- Every json_type()/json_extract() call below addresses tracks.participants
-- (the outer document) by path, never je.value — see the driver note above.
UPDATE tracks
SET participants = (
    SELECT json_group_array(
        CASE
            WHEN json_type(tracks.participants, '$[' || je.key || '].user_id') = 'text'
             AND json_extract(tracks.participants, '$[' || je.key || '].user_id') != ''
             AND json_extract(tracks.participants, '$[' || je.key || '].user_id') NOT GLOB '[0-9]*:*'
                THEN json_set(json(je.value), '$.user_id', '1:' || json_extract(tracks.participants, '$[' || je.key || '].user_id'))
            ELSE je.value
        END
    )
    FROM json_each(tracks.participants) je
)
WHERE json_valid(participants) AND json_type(participants) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(tracks.participants) je
      WHERE json_type(tracks.participants, '$[' || je.key || '].user_id') = 'text'
        AND json_extract(tracks.participants, '$[' || je.key || '].user_id') != ''
        AND json_extract(tracks.participants, '$[' || je.key || '].user_id') NOT GLOB '[0-9]*:*'
  );

-- +goose Down
-- Strip the account-1 prefix back off, mirroring the Up block. Elements that
-- were already namespaced before the Up ran are indistinguishable from ones
-- it created, so Down returns every '1:'-prefixed element to its bare form —
-- the pre-00048 shape.

UPDATE tracks
SET channel_ids = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value GLOB '1:*'
                THEN substr(je.value, 3)
            ELSE je.value
        END
    )
    FROM json_each(tracks.channel_ids) je
)
WHERE json_valid(channel_ids) AND json_type(channel_ids) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(tracks.channel_ids) je
      WHERE je.type = 'text' AND je.value GLOB '1:*'
  );

UPDATE user_profile
SET reports = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value GLOB '1:*'
                THEN substr(je.value, 3)
            ELSE je.value
        END
    )
    FROM json_each(user_profile.reports) je
)
WHERE json_valid(reports) AND json_type(reports) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(user_profile.reports) je
      WHERE je.type = 'text' AND je.value GLOB '1:*'
  );

UPDATE user_profile
SET peers = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value GLOB '1:*'
                THEN substr(je.value, 3)
            ELSE je.value
        END
    )
    FROM json_each(user_profile.peers) je
)
WHERE json_valid(peers) AND json_type(peers) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(user_profile.peers) je
      WHERE je.type = 'text' AND je.value GLOB '1:*'
  );

UPDATE user_profile
SET starred_channels = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value GLOB '1:*'
                THEN substr(je.value, 3)
            ELSE je.value
        END
    )
    FROM json_each(user_profile.starred_channels) je
)
WHERE json_valid(starred_channels) AND json_type(starred_channels) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(user_profile.starred_channels) je
      WHERE je.type = 'text' AND je.value GLOB '1:*'
  );

UPDATE user_profile
SET starred_people = (
    SELECT json_group_array(
        CASE
            WHEN je.type = 'text' AND je.value GLOB '1:*'
                THEN substr(je.value, 3)
            ELSE je.value
        END
    )
    FROM json_each(user_profile.starred_people) je
)
WHERE json_valid(starred_people) AND json_type(starred_people) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(user_profile.starred_people) je
      WHERE je.type = 'text' AND je.value GLOB '1:*'
  );

UPDATE tracks
SET participants = (
    SELECT json_group_array(
        CASE
            WHEN json_type(tracks.participants, '$[' || je.key || '].user_id') = 'text'
             AND json_extract(tracks.participants, '$[' || je.key || '].user_id') GLOB '1:*'
                THEN json_set(json(je.value), '$.user_id', substr(json_extract(tracks.participants, '$[' || je.key || '].user_id'), 3))
            ELSE je.value
        END
    )
    FROM json_each(tracks.participants) je
)
WHERE json_valid(participants) AND json_type(participants) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(tracks.participants) je
      WHERE json_type(tracks.participants, '$[' || je.key || '].user_id') = 'text'
        AND json_extract(tracks.participants, '$[' || je.key || '].user_id') GLOB '1:*'
  );

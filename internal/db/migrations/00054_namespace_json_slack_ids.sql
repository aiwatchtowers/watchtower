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
-- Driver quirk (verified empirically against modernc.org/sqlite v1.49.1,
-- the version pinned in go.mod): calling json_type() as a function on a
-- json_each() row's `value` corrupts the virtual-table cursor as soon as the
-- same statement's table scan also touches ANY row whose own array is empty
-- (0 elements) — it throws "malformed JSON" even though every value
-- involved is well-formed JSON. Since every column here defaults to '[]',
-- an empty array sitting next to a populated one in the same table is the
-- normal case, not an edge case. `je.type` (the column json_each already
-- provides) and `typeof(json_extract(...))` do not trigger it and are used
-- throughout instead of `json_type(je.value)` / `json_type(je.value, path)`.

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
UPDATE tracks
SET participants = (
    SELECT json_group_array(
        CASE
            WHEN typeof(json_extract(je.value, '$.user_id')) = 'text'
             AND json_extract(je.value, '$.user_id') != ''
             AND json_extract(je.value, '$.user_id') NOT GLOB '[0-9]*:*'
                THEN json_set(json(je.value), '$.user_id', '1:' || json_extract(je.value, '$.user_id'))
            ELSE json(je.value)
        END
    )
    FROM json_each(tracks.participants) je
)
WHERE json_valid(participants) AND json_type(participants) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(tracks.participants) je
      WHERE typeof(json_extract(je.value, '$.user_id')) = 'text'
        AND json_extract(je.value, '$.user_id') != ''
        AND json_extract(je.value, '$.user_id') NOT GLOB '[0-9]*:*'
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
            WHEN typeof(json_extract(je.value, '$.user_id')) = 'text'
             AND json_extract(je.value, '$.user_id') GLOB '1:*'
                THEN json_set(json(je.value), '$.user_id', substr(json_extract(je.value, '$.user_id'), 3))
            ELSE json(je.value)
        END
    )
    FROM json_each(tracks.participants) je
)
WHERE json_valid(participants) AND json_type(participants) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(tracks.participants) je
      WHERE typeof(json_extract(je.value, '$.user_id')) = 'text'
        AND json_extract(je.value, '$.user_id') GLOB '1:*'
  );

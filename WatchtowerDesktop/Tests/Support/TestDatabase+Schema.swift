import Foundation

/// The full watchtower schema mirror, split out of TestDatabase.swift to keep
/// that file under the file_length / type_body_length limits (schema is data, not logic).
extension TestDatabase {
    package static let schema = """
    CREATE TABLE IF NOT EXISTS workspace (
        id                TEXT PRIMARY KEY,
        name              TEXT NOT NULL,
        domain            TEXT NOT NULL DEFAULT '',
        synced_at         TEXT,
        -- current_user_id / search_last_date moved to slack_accounts
        -- (migration 00048). Mirror kept in sync with the real post-migration
        -- schema so tests can't accidentally read a dropped column.
        inbox_last_processed_ts REAL NOT NULL DEFAULT 0,
        secretary_profile TEXT NOT NULL DEFAULT '',
        style_profile TEXT NOT NULL DEFAULT '',
        style_profile_updated_at TEXT NOT NULL DEFAULT '',
        compose_last_run_ts REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS users (
        id            TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        display_name  TEXT NOT NULL DEFAULT '',
        real_name     TEXT NOT NULL DEFAULT '',
        email         TEXT NOT NULL DEFAULT '',
        is_bot        INTEGER NOT NULL DEFAULT 0,
        is_deleted    INTEGER NOT NULL DEFAULT 0,
        is_bot_override INTEGER DEFAULT NULL,
        profile_json  TEXT NOT NULL DEFAULT '{}',
        updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS channels (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        type         TEXT NOT NULL CHECK(type IN ('public', 'private', 'dm', 'group_dm')),
        topic        TEXT NOT NULL DEFAULT '',
        purpose      TEXT NOT NULL DEFAULT '',
        is_archived  INTEGER NOT NULL DEFAULT 0,
        is_member    INTEGER NOT NULL DEFAULT 0,
        dm_user_id   TEXT,
        num_members  INTEGER NOT NULL DEFAULT 0,
        updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS messages (
        channel_id   TEXT NOT NULL,
        ts           TEXT NOT NULL,
        user_id      TEXT NOT NULL DEFAULT '',
        text         TEXT NOT NULL DEFAULT '',
        thread_ts    TEXT,
        reply_count  INTEGER NOT NULL DEFAULT 0,
        is_edited    INTEGER NOT NULL DEFAULT 0,
        is_deleted   INTEGER NOT NULL DEFAULT 0,
        subtype      TEXT NOT NULL DEFAULT '',
        permalink    TEXT NOT NULL DEFAULT '',
        ts_unix      REAL GENERATED ALWAYS AS (
            CASE WHEN INSTR(ts, '.') > 0
            THEN CAST(SUBSTR(ts, 1, INSTR(ts, '.') - 1) AS REAL)
            ELSE CAST(ts AS REAL) END) STORED,
        raw_json     TEXT NOT NULL DEFAULT '{}',
        PRIMARY KEY (channel_id, ts)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        text,
        channel_id UNINDEXED,
        ts UNINDEXED,
        user_id UNINDEXED,
        tokenize='porter unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages
    WHEN NEW.text != '' AND NEW.is_deleted = 0
    BEGIN
        DELETE FROM messages_fts WHERE channel_id = NEW.channel_id AND ts = NEW.ts;
        INSERT INTO messages_fts(text, channel_id, ts, user_id)
        VALUES (NEW.text, NEW.channel_id, NEW.ts, NEW.user_id);
    END;
    CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages
    BEGIN
        DELETE FROM messages_fts WHERE channel_id = OLD.channel_id AND ts = OLD.ts;
    END;
    CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF text, is_deleted ON messages
    WHEN OLD.text != NEW.text OR OLD.is_deleted != NEW.is_deleted
    BEGIN
        DELETE FROM messages_fts WHERE channel_id = OLD.channel_id AND ts = OLD.ts;
        INSERT INTO messages_fts(text, channel_id, ts, user_id)
        SELECT NEW.text, NEW.channel_id, NEW.ts, NEW.user_id
        WHERE NEW.text != '' AND NEW.is_deleted = 0;
    END;
    CREATE TABLE IF NOT EXISTS sync_state (
        channel_id              TEXT PRIMARY KEY,
        last_synced_ts          TEXT NOT NULL DEFAULT '',
        oldest_synced_ts        TEXT NOT NULL DEFAULT '',
        is_initial_sync_complete INTEGER NOT NULL DEFAULT 0,
        cursor                  TEXT NOT NULL DEFAULT '',
        messages_synced         INTEGER NOT NULL DEFAULT 0,
        last_sync_at            TEXT,
        error                   TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS watch_list (
        entity_type TEXT NOT NULL CHECK(entity_type IN ('channel', 'user')),
        entity_id   TEXT NOT NULL,
        entity_name TEXT NOT NULL DEFAULT '',
        priority    TEXT NOT NULL DEFAULT 'normal' CHECK(priority IN ('high', 'normal', 'low')),
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (entity_type, entity_id)
    );
    CREATE TABLE IF NOT EXISTS digests (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id    TEXT NOT NULL DEFAULT '',
        period_from   REAL NOT NULL,
        period_to     REAL NOT NULL,
        type          TEXT NOT NULL CHECK(type IN ('channel', 'daily', 'weekly')),
        summary       TEXT NOT NULL,
        topics        TEXT NOT NULL DEFAULT '[]',
        decisions     TEXT NOT NULL DEFAULT '[]',
        action_items  TEXT NOT NULL DEFAULT '[]',
        message_count INTEGER NOT NULL DEFAULT 0,
        model         TEXT NOT NULL DEFAULT '',
        input_tokens  INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cost_usd      REAL NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        read_at       TEXT,
        prompt_version INTEGER NOT NULL DEFAULT 0,
        people_signals TEXT NOT NULL DEFAULT '[]',
        situations     TEXT NOT NULL DEFAULT '[]',
        running_summary TEXT NOT NULL DEFAULT '',
        UNIQUE(channel_id, type, period_from, period_to)
    );
    CREATE TABLE IF NOT EXISTS digest_participants (
        digest_id      INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
        user_id        TEXT NOT NULL,
        situation_idx  INTEGER NOT NULL DEFAULT 0,
        role           TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (digest_id, user_id, situation_idx)
    );
    CREATE INDEX IF NOT EXISTS idx_digest_participants_user ON digest_participants(user_id);
    CREATE TABLE IF NOT EXISTS digest_topics (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        digest_id     INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
        idx           INTEGER NOT NULL DEFAULT 0,
        title         TEXT NOT NULL,
        summary       TEXT NOT NULL DEFAULT '',
        decisions     TEXT NOT NULL DEFAULT '[]',
        action_items  TEXT NOT NULL DEFAULT '[]',
        situations    TEXT NOT NULL DEFAULT '[]',
        key_messages  TEXT NOT NULL DEFAULT '[]',
        UNIQUE(digest_id, idx)
    );
    CREATE INDEX IF NOT EXISTS idx_digest_topics_digest ON digest_topics(digest_id);
    CREATE TABLE IF NOT EXISTS decision_reads (
        digest_id    INTEGER NOT NULL,
        decision_idx INTEGER NOT NULL,
        read_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (digest_id, decision_idx)
    );
    CREATE TABLE IF NOT EXISTS decision_importance_corrections (
        id                   INTEGER PRIMARY KEY AUTOINCREMENT,
        digest_id            INTEGER NOT NULL,
        decision_idx         INTEGER NOT NULL,
        topic_id             INTEGER NOT NULL DEFAULT 0,
        decision_text        TEXT NOT NULL DEFAULT '',
        original_importance  TEXT NOT NULL CHECK(original_importance IN ('high', 'medium', 'low')),
        new_importance       TEXT NOT NULL CHECK(new_importance IN ('high', 'medium', 'low')),
        created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS user_analyses (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id             TEXT NOT NULL,
        period_from         REAL NOT NULL,
        period_to           REAL NOT NULL,
        message_count       INTEGER NOT NULL DEFAULT 0,
        channels_active     INTEGER NOT NULL DEFAULT 0,
        threads_initiated   INTEGER NOT NULL DEFAULT 0,
        threads_replied     INTEGER NOT NULL DEFAULT 0,
        avg_message_length  REAL NOT NULL DEFAULT 0,
        active_hours_json   TEXT NOT NULL DEFAULT '{}',
        volume_change_pct   REAL NOT NULL DEFAULT 0,
        summary             TEXT NOT NULL DEFAULT '',
        communication_style TEXT NOT NULL DEFAULT '',
        decision_role       TEXT NOT NULL DEFAULT '',
        red_flags           TEXT NOT NULL DEFAULT '[]',
        highlights          TEXT NOT NULL DEFAULT '[]',
        style_details       TEXT NOT NULL DEFAULT '',
        recommendations     TEXT NOT NULL DEFAULT '[]',
        concerns            TEXT NOT NULL DEFAULT '[]',
        accomplishments     TEXT NOT NULL DEFAULT '[]',
        model               TEXT NOT NULL DEFAULT '',
        input_tokens        INTEGER NOT NULL DEFAULT 0,
        output_tokens       INTEGER NOT NULL DEFAULT 0,
        cost_usd            REAL NOT NULL DEFAULT 0,
        prompt_version      INTEGER NOT NULL DEFAULT 0,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(user_id, period_from, period_to)
    );
    CREATE TABLE IF NOT EXISTS period_summaries (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        period_from   REAL NOT NULL,
        period_to     REAL NOT NULL,
        summary       TEXT NOT NULL DEFAULT '',
        attention     TEXT NOT NULL DEFAULT '[]',
        model         TEXT NOT NULL DEFAULT '',
        input_tokens  INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cost_usd      REAL NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(period_from, period_to)
    );
    CREATE TABLE IF NOT EXISTS custom_emojis (
        name       TEXT PRIMARY KEY,
        url        TEXT NOT NULL,
        alias_for  TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS tracks (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        assignee_user_id    TEXT NOT NULL DEFAULT '',
        text                TEXT NOT NULL,
        context             TEXT NOT NULL DEFAULT '',
        category            TEXT NOT NULL DEFAULT 'task',
        ownership           TEXT NOT NULL DEFAULT 'mine' CHECK(ownership IN ('mine','delegated','watching')),
        ball_on             TEXT NOT NULL DEFAULT '',
        owner_user_id       TEXT NOT NULL DEFAULT '',
        requester_name      TEXT NOT NULL DEFAULT '',
        requester_user_id   TEXT NOT NULL DEFAULT '',
        blocking            TEXT NOT NULL DEFAULT '',
        decision_summary    TEXT NOT NULL DEFAULT '',
        decision_options    TEXT NOT NULL DEFAULT '[]',
        sub_items           TEXT NOT NULL DEFAULT '[]',
        participants        TEXT NOT NULL DEFAULT '[]',
        source_refs         TEXT NOT NULL DEFAULT '[]',
        tags                TEXT NOT NULL DEFAULT '[]',
        channel_ids         TEXT NOT NULL DEFAULT '[]',
        related_digest_ids  TEXT NOT NULL DEFAULT '[]',
        priority            TEXT NOT NULL DEFAULT 'medium',
        due_date            REAL,
        fingerprint         TEXT NOT NULL DEFAULT '[]',
        read_at             TEXT,
        has_updates         INTEGER NOT NULL DEFAULT 0,
        dismissed_at        TEXT NOT NULL DEFAULT '',
        model               TEXT NOT NULL DEFAULT '',
        input_tokens        INTEGER NOT NULL DEFAULT 0,
        output_tokens       INTEGER NOT NULL DEFAULT 0,
        cost_usd            REAL NOT NULL DEFAULT 0,
        prompt_version      INTEGER NOT NULL DEFAULT 0,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        linked_target_id    INTEGER REFERENCES targets(id) ON DELETE SET NULL
    );
    CREATE TABLE IF NOT EXISTS track_states (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id           INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        text               TEXT NOT NULL,
        context            TEXT NOT NULL DEFAULT '',
        category           TEXT NOT NULL,
        ownership          TEXT NOT NULL,
        ball_on            TEXT NOT NULL DEFAULT '',
        owner_user_id      TEXT NOT NULL DEFAULT '',
        requester_name     TEXT NOT NULL DEFAULT '',
        requester_user_id  TEXT NOT NULL DEFAULT '',
        blocking           TEXT NOT NULL DEFAULT '',
        decision_summary   TEXT NOT NULL DEFAULT '',
        decision_options   TEXT NOT NULL DEFAULT '[]',
        sub_items          TEXT NOT NULL DEFAULT '[]',
        participants       TEXT NOT NULL DEFAULT '[]',
        tags               TEXT NOT NULL DEFAULT '[]',
        priority           TEXT NOT NULL,
        due_date           REAL,
        source             TEXT NOT NULL CHECK(source IN ('extraction','manual')),
        model              TEXT NOT NULL DEFAULT '',
        prompt_version     INTEGER NOT NULL DEFAULT 0,
        created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_track_states_track ON track_states(track_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS inbox_items (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id      TEXT NOT NULL,
        message_ts      TEXT NOT NULL,
        thread_ts       TEXT NOT NULL DEFAULT '',
        sender_user_id  TEXT NOT NULL,
        trigger_type    TEXT NOT NULL CHECK(trigger_type IN (
            'mention','dm','thread_reply','reaction',
            'jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change',
            'calendar_invite','calendar_time_change','calendar_cancelled',
            'decision_made','briefing_ready',
            'target_due',
            'stream',
            'email_received','email_cc'
        )),
        snippet         TEXT NOT NULL DEFAULT '',
        context         TEXT NOT NULL DEFAULT '',
        raw_text        TEXT NOT NULL DEFAULT '',
        permalink       TEXT NOT NULL DEFAULT '',
        status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed','snoozed')),
        priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
        ai_reason       TEXT NOT NULL DEFAULT '',
        resolved_reason TEXT NOT NULL DEFAULT '',
        snooze_until    TEXT NOT NULL DEFAULT '',
        waiting_user_ids TEXT NOT NULL DEFAULT '',
        target_id       INTEGER,
        read_at         TEXT,
        created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        item_class      TEXT NOT NULL DEFAULT 'actionable' CHECK(item_class IN ('actionable','ambient')),
        archived_at     TEXT,
        archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
        why_matters     TEXT NOT NULL DEFAULT '',
        thread_digest   TEXT NOT NULL DEFAULT '',
        draft_reply     TEXT NOT NULL DEFAULT '',
        card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
        card_generated_at TEXT,
        composed_at     TEXT,
        UNIQUE(channel_id, message_ts)
    );
    CREATE INDEX IF NOT EXISTS idx_inbox_status ON inbox_items(status);
    CREATE INDEX IF NOT EXISTS idx_inbox_priority ON inbox_items(priority);
    CREATE INDEX IF NOT EXISTS idx_inbox_updated ON inbox_items(updated_at DESC);
    CREATE INDEX IF NOT EXISTS idx_inbox_sender ON inbox_items(sender_user_id);
    CREATE INDEX IF NOT EXISTS idx_inbox_snooze ON inbox_items(snooze_until);
    CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
    CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

    CREATE TABLE IF NOT EXISTS inbox_learned_rules (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        rule_type      TEXT NOT NULL CHECK(rule_type IN ('source_mute','source_boost','trigger_downgrade','trigger_boost')),
        scope_key      TEXT NOT NULL,
        weight         REAL NOT NULL,
        source         TEXT NOT NULL CHECK(source IN ('implicit','explicit_feedback','user_rule')),
        evidence_count INTEGER NOT NULL DEFAULT 0,
        last_updated   TEXT NOT NULL,
        pipeline       TEXT NOT NULL DEFAULT 'inbox',
        UNIQUE(rule_type, scope_key)
    );
    CREATE INDEX IF NOT EXISTS idx_inbox_learned_rules_scope ON inbox_learned_rules(rule_type, scope_key);

    CREATE TABLE IF NOT EXISTS inbox_feedback (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        inbox_item_id INTEGER NOT NULL,
        rating        INTEGER NOT NULL CHECK(rating IN (-1,1)),
        reason        TEXT DEFAULT '',
        created_at    TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_inbox_feedback_item ON inbox_feedback(inbox_item_id);

    CREATE TABLE IF NOT EXISTS slack_accounts (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        team_id           TEXT NOT NULL DEFAULT '',
        team_name         TEXT NOT NULL DEFAULT '',
        team_domain       TEXT NOT NULL DEFAULT '',
        label             TEXT NOT NULL DEFAULT '',
        current_user_id   TEXT NOT NULL DEFAULT '',
        status            TEXT NOT NULL DEFAULT 'ok',
        error             TEXT NOT NULL DEFAULT '',
        enabled           INTEGER NOT NULL DEFAULT 1,
        search_last_date  TEXT NOT NULL DEFAULT '',
        created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS jira_accounts (
        id                            INTEGER PRIMARY KEY AUTOINCREMENT,
        cloud_id                      TEXT NOT NULL DEFAULT '',
        site_url                      TEXT NOT NULL DEFAULT '',
        site_name                     TEXT NOT NULL DEFAULT '',
        label                         TEXT NOT NULL DEFAULT '',
        status                        TEXT NOT NULL DEFAULT 'ok',
        error                         TEXT NOT NULL DEFAULT '',
        enabled                       INTEGER NOT NULL DEFAULT 1,
        memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0,
        created_at                    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS google_accounts (
        id                             INTEGER PRIMARY KEY AUTOINCREMENT,
        email                          TEXT NOT NULL DEFAULT '',
        label                          TEXT NOT NULL DEFAULT '',
        client_id                      TEXT NOT NULL DEFAULT '',
        calendar_enabled               INTEGER NOT NULL DEFAULT 0,
        gmail_enabled                  INTEGER NOT NULL DEFAULT 0,
        status                         TEXT NOT NULL DEFAULT 'ok',
        error                          TEXT NOT NULL DEFAULT '',
        gmail_last_internal_date       REAL NOT NULL DEFAULT 0,
        memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0,
        created_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS calendar_calendars (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        is_primary  INTEGER NOT NULL DEFAULT 0,
        is_selected INTEGER NOT NULL DEFAULT 1,
        color       TEXT NOT NULL DEFAULT '',
        synced_at   TEXT NOT NULL DEFAULT '',
        account_id  INTEGER REFERENCES google_accounts(id)
    );

    CREATE TABLE IF NOT EXISTS calendar_events (
        id              TEXT PRIMARY KEY,
        calendar_id     TEXT NOT NULL REFERENCES calendar_calendars(id),
        title           TEXT NOT NULL DEFAULT '',
        description     TEXT NOT NULL DEFAULT '',
        location        TEXT NOT NULL DEFAULT '',
        start_time      TEXT NOT NULL,
        end_time        TEXT NOT NULL,
        organizer_email TEXT NOT NULL DEFAULT '',
        attendees       TEXT NOT NULL DEFAULT '[]',
        is_recurring    INTEGER NOT NULL DEFAULT 0,
        is_all_day      INTEGER NOT NULL DEFAULT 0,
        event_status    TEXT NOT NULL DEFAULT 'confirmed',
        event_type      TEXT NOT NULL DEFAULT '',
        html_link       TEXT NOT NULL DEFAULT '',
        raw_json        TEXT NOT NULL DEFAULT '{}',
        synced_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at      TEXT NOT NULL DEFAULT '',
        ical_uid        TEXT NOT NULL DEFAULT '',
        conference_url  TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_calendar_events_calendar ON calendar_events(calendar_id);
    CREATE INDEX IF NOT EXISTS idx_calendar_events_start ON calendar_events(start_time);
    CREATE INDEX IF NOT EXISTS idx_calendar_events_end ON calendar_events(end_time);

    CREATE TABLE IF NOT EXISTS calendar_attendee_map (
        email          TEXT PRIMARY KEY,
        slack_user_id  TEXT NOT NULL DEFAULT '',
        resolved_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS gmail_messages (
        account_id     INTEGER NOT NULL REFERENCES google_accounts(id) ON DELETE CASCADE,
        id             TEXT NOT NULL,
        thread_id      TEXT NOT NULL DEFAULT '',
        from_email     TEXT NOT NULL DEFAULT '',
        from_name      TEXT NOT NULL DEFAULT '',
        to_json        TEXT NOT NULL DEFAULT '[]',
        cc_json        TEXT NOT NULL DEFAULT '[]',
        subject        TEXT NOT NULL DEFAULT '',
        snippet        TEXT NOT NULL DEFAULT '',
        body_text      TEXT NOT NULL DEFAULT '',
        internal_date  TEXT NOT NULL DEFAULT '',
        labels_json    TEXT NOT NULL DEFAULT '[]',
        is_unread      INTEGER NOT NULL DEFAULT 0,
        permalink      TEXT NOT NULL DEFAULT '',
        synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (account_id, id)
    );
    CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
    CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);

    CREATE TABLE IF NOT EXISTS feedback (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL CHECK(entity_type IN
            ('digest', 'track', 'decision', 'user_analysis', 'briefing', 'task', 'inbox', 'catchup_theme', 'situation')),
        entity_id   TEXT NOT NULL,
        rating      INTEGER NOT NULL CHECK(rating IN (-1, 1)),
        comment     TEXT NOT NULL DEFAULT '',
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_feedback_entity ON feedback(entity_type, entity_id);
    CREATE INDEX IF NOT EXISTS idx_feedback_rating ON feedback(entity_type, rating);
    CREATE TABLE IF NOT EXISTS prompts (
        id         TEXT PRIMARY KEY,
        template   TEXT NOT NULL,
        version    INTEGER NOT NULL DEFAULT 1,
        language   TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS prompt_history (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        prompt_id  TEXT NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
        version    INTEGER NOT NULL,
        template   TEXT NOT NULL,
        reason     TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_prompt_history_prompt ON prompt_history(prompt_id);
    CREATE INDEX IF NOT EXISTS idx_prompt_history_version ON prompt_history(prompt_id, version);
    CREATE TABLE IF NOT EXISTS user_interactions (
        user_a              TEXT NOT NULL,
        user_b              TEXT NOT NULL,
        period_from         REAL NOT NULL,
        period_to           REAL NOT NULL,
        messages_to         INTEGER NOT NULL DEFAULT 0,
        messages_from       INTEGER NOT NULL DEFAULT 0,
        shared_channels     INTEGER NOT NULL DEFAULT 0,
        thread_replies_to   INTEGER NOT NULL DEFAULT 0,
        thread_replies_from INTEGER NOT NULL DEFAULT 0,
        shared_channel_ids  TEXT NOT NULL DEFAULT '[]',
        dm_messages_to      INTEGER NOT NULL DEFAULT 0,
        dm_messages_from    INTEGER NOT NULL DEFAULT 0,
        mentions_to         INTEGER NOT NULL DEFAULT 0,
        mentions_from       INTEGER NOT NULL DEFAULT 0,
        reactions_to        INTEGER NOT NULL DEFAULT 0,
        reactions_from      INTEGER NOT NULL DEFAULT 0,
        interaction_score   REAL NOT NULL DEFAULT 0,
        connection_type     TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (user_a, user_b, period_from, period_to)
    );
    CREATE INDEX IF NOT EXISTS idx_user_interactions_a ON user_interactions(user_a, period_from, period_to);

    CREATE TABLE IF NOT EXISTS communication_guides (
        id                        INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id                   TEXT NOT NULL,
        period_from               REAL NOT NULL,
        period_to                 REAL NOT NULL,
        message_count             INTEGER NOT NULL DEFAULT 0,
        channels_active           INTEGER NOT NULL DEFAULT 0,
        threads_initiated         INTEGER NOT NULL DEFAULT 0,
        threads_replied           INTEGER NOT NULL DEFAULT 0,
        avg_message_length        REAL NOT NULL DEFAULT 0,
        active_hours_json         TEXT NOT NULL DEFAULT '{}',
        volume_change_pct         REAL NOT NULL DEFAULT 0,
        summary                   TEXT NOT NULL DEFAULT '',
        communication_preferences TEXT NOT NULL DEFAULT '',
        availability_patterns     TEXT NOT NULL DEFAULT '',
        decision_process          TEXT NOT NULL DEFAULT '',
        situational_tactics       TEXT NOT NULL DEFAULT '[]',
        effective_approaches      TEXT NOT NULL DEFAULT '[]',
        recommendations           TEXT NOT NULL DEFAULT '[]',
        relationship_context      TEXT NOT NULL DEFAULT '',
        model                     TEXT NOT NULL DEFAULT '',
        input_tokens              INTEGER NOT NULL DEFAULT 0,
        output_tokens             INTEGER NOT NULL DEFAULT 0,
        cost_usd                  REAL NOT NULL DEFAULT 0,
        prompt_version            INTEGER NOT NULL DEFAULT 0,
        created_at                TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(user_id, period_from, period_to)
    );
    CREATE INDEX IF NOT EXISTS idx_communication_guides_user   ON communication_guides(user_id);
    CREATE INDEX IF NOT EXISTS idx_communication_guides_period ON communication_guides(period_from, period_to);

    CREATE TABLE IF NOT EXISTS guide_summaries (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        period_from    REAL NOT NULL,
        period_to      REAL NOT NULL,
        summary        TEXT NOT NULL DEFAULT '',
        tips           TEXT NOT NULL DEFAULT '[]',
        model          TEXT NOT NULL DEFAULT '',
        input_tokens   INTEGER NOT NULL DEFAULT 0,
        output_tokens  INTEGER NOT NULL DEFAULT 0,
        cost_usd       REAL NOT NULL DEFAULT 0,
        prompt_version INTEGER NOT NULL DEFAULT 0,
        created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(period_from, period_to)
    );

    CREATE TABLE IF NOT EXISTS people_cards (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id             TEXT NOT NULL,
        period_from         REAL NOT NULL,
        period_to           REAL NOT NULL,
        message_count       INTEGER NOT NULL DEFAULT 0,
        channels_active     INTEGER NOT NULL DEFAULT 0,
        threads_initiated   INTEGER NOT NULL DEFAULT 0,
        threads_replied     INTEGER NOT NULL DEFAULT 0,
        avg_message_length  REAL NOT NULL DEFAULT 0,
        active_hours_json   TEXT NOT NULL DEFAULT '{}',
        volume_change_pct   REAL NOT NULL DEFAULT 0,
        summary             TEXT NOT NULL DEFAULT '',
        communication_style TEXT NOT NULL DEFAULT '',
        decision_role       TEXT NOT NULL DEFAULT '',
        red_flags           TEXT NOT NULL DEFAULT '[]',
        highlights          TEXT NOT NULL DEFAULT '[]',
        accomplishments     TEXT NOT NULL DEFAULT '[]',
        communication_guide TEXT NOT NULL DEFAULT '',
        decision_style      TEXT NOT NULL DEFAULT '',
        tactics             TEXT NOT NULL DEFAULT '[]',
        relationship_context TEXT NOT NULL DEFAULT '',
        status              TEXT NOT NULL DEFAULT 'active',
        model               TEXT NOT NULL DEFAULT '',
        input_tokens        INTEGER NOT NULL DEFAULT 0,
        output_tokens       INTEGER NOT NULL DEFAULT 0,
        cost_usd            REAL NOT NULL DEFAULT 0,
        prompt_version      INTEGER NOT NULL DEFAULT 0,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(user_id, period_from, period_to)
    );
    CREATE TABLE IF NOT EXISTS people_card_summaries (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        period_from   REAL NOT NULL,
        period_to     REAL NOT NULL,
        summary       TEXT NOT NULL DEFAULT '',
        attention     TEXT NOT NULL DEFAULT '[]',
        tips          TEXT NOT NULL DEFAULT '[]',
        model         TEXT NOT NULL DEFAULT '',
        input_tokens  INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cost_usd      REAL NOT NULL DEFAULT 0,
        prompt_version INTEGER NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(period_from, period_to)
    );

    CREATE TABLE IF NOT EXISTS briefings (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id     TEXT NOT NULL DEFAULT '',
        user_id          TEXT NOT NULL,
        date             TEXT NOT NULL,
        role             TEXT NOT NULL DEFAULT '',
        attention        TEXT NOT NULL DEFAULT '[]',
        your_day         TEXT NOT NULL DEFAULT '[]',
        what_happened    TEXT NOT NULL DEFAULT '[]',
        team_pulse       TEXT NOT NULL DEFAULT '[]',
        coaching         TEXT NOT NULL DEFAULT '[]',
        model            TEXT NOT NULL DEFAULT '',
        input_tokens     INTEGER NOT NULL DEFAULT 0,
        output_tokens    INTEGER NOT NULL DEFAULT 0,
        cost_usd         REAL NOT NULL DEFAULT 0,
        prompt_version   INTEGER NOT NULL DEFAULT 0,
        read_at          TEXT,
        created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(user_id, date)
    );
    CREATE INDEX IF NOT EXISTS idx_briefings_user_date ON briefings(user_id, date DESC);

    CREATE TABLE IF NOT EXISTS pipeline_runs (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        pipeline         TEXT NOT NULL,
        source           TEXT NOT NULL DEFAULT 'cli',
        model            TEXT NOT NULL DEFAULT '',
        status           TEXT NOT NULL DEFAULT 'running' CHECK(status IN ('running', 'done', 'error')),
        error_msg        TEXT NOT NULL DEFAULT '',
        items_found      INTEGER NOT NULL DEFAULT 0,
        input_tokens     INTEGER NOT NULL DEFAULT 0,
        output_tokens    INTEGER NOT NULL DEFAULT 0,
        cost_usd         REAL NOT NULL DEFAULT 0,
        total_api_tokens INTEGER NOT NULL DEFAULT 0,
        period_from      REAL,
        period_to        REAL,
        started_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        finished_at      TEXT,
        duration_seconds REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS pipeline_steps (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id           INTEGER NOT NULL REFERENCES pipeline_runs(id) ON DELETE CASCADE,
        step             INTEGER NOT NULL,
        total            INTEGER NOT NULL,
        status           TEXT NOT NULL DEFAULT '',
        channel_id       TEXT NOT NULL DEFAULT '',
        channel_name     TEXT NOT NULL DEFAULT '',
        input_tokens     INTEGER NOT NULL DEFAULT 0,
        output_tokens    INTEGER NOT NULL DEFAULT 0,
        cost_usd         REAL NOT NULL DEFAULT 0,
        total_api_tokens INTEGER NOT NULL DEFAULT 0,
        message_count    INTEGER NOT NULL DEFAULT 0,
        period_from      REAL,
        period_to        REAL,
        duration_seconds REAL NOT NULL DEFAULT 0,
        created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS channel_settings (
        channel_id         TEXT PRIMARY KEY,
        is_muted_for_llm   INTEGER NOT NULL DEFAULT 0,
        is_favorite        INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS user_profile (
        id                    INTEGER PRIMARY KEY,
        slack_user_id         TEXT NOT NULL UNIQUE,
        role                  TEXT NOT NULL DEFAULT '',
        team                  TEXT NOT NULL DEFAULT '',
        responsibilities      TEXT NOT NULL DEFAULT '[]',
        reports               TEXT NOT NULL DEFAULT '[]',
        peers                 TEXT NOT NULL DEFAULT '[]',
        manager               TEXT NOT NULL DEFAULT '',
        starred_channels      TEXT NOT NULL DEFAULT '[]',
        starred_people        TEXT NOT NULL DEFAULT '[]',
        pain_points           TEXT NOT NULL DEFAULT '[]',
        track_focus           TEXT NOT NULL DEFAULT '[]',
        onboarding_done       INTEGER NOT NULL DEFAULT 0,
        custom_prompt_context TEXT NOT NULL DEFAULT '',
        created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS day_plans (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id             TEXT NOT NULL,
        plan_date           TEXT NOT NULL,
        status              TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
        has_conflicts       INTEGER NOT NULL DEFAULT 0,
        conflict_summary    TEXT,
        generated_at        TEXT NOT NULL,
        last_regenerated_at TEXT,
        regenerate_count    INTEGER NOT NULL DEFAULT 0,
        feedback_history    TEXT,
        prompt_version      TEXT,
        briefing_id         INTEGER,
        read_at             TEXT,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE (user_id, plan_date)
    );
    CREATE TABLE IF NOT EXISTS day_plan_items (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        day_plan_id  INTEGER NOT NULL REFERENCES day_plans(id) ON DELETE CASCADE,
        kind         TEXT NOT NULL CHECK (kind IN ('timeblock','backlog')),
        source_type  TEXT NOT NULL CHECK (source_type IN ('task','briefing_attention','jira','calendar','manual','focus')),
        source_id    TEXT,
        title        TEXT NOT NULL,
        description  TEXT,
        rationale    TEXT,
        start_time   TEXT,
        end_time     TEXT,
        duration_min INTEGER,
        priority     TEXT CHECK (priority IS NULL OR priority IN ('high','medium','low')),
        status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','skipped')),
        order_index  INTEGER NOT NULL DEFAULT 0,
        tags         TEXT,
        created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS targets (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        text                TEXT NOT NULL,
        intent              TEXT NOT NULL DEFAULT '',
        level               TEXT NOT NULL DEFAULT 'day'
                            CHECK(level IN ('quarter','month','week','day','custom')),
        custom_label        TEXT NOT NULL DEFAULT '',
        period_start        TEXT NOT NULL DEFAULT '',
        period_end          TEXT NOT NULL DEFAULT '',
        parent_id           INTEGER REFERENCES targets(id) ON DELETE SET NULL,
        status              TEXT NOT NULL DEFAULT 'todo'
                            CHECK(status IN ('todo','in_progress','blocked','done','dismissed','snoozed')),
        priority            TEXT NOT NULL DEFAULT 'medium'
                            CHECK(priority IN ('high','medium','low')),
        ownership           TEXT NOT NULL DEFAULT 'mine'
                            CHECK(ownership IN ('mine','delegated','watching')),
        ball_on             TEXT NOT NULL DEFAULT '',
        due_date            TEXT NOT NULL DEFAULT '',
        snooze_until        TEXT NOT NULL DEFAULT '',
        blocking            TEXT NOT NULL DEFAULT '',
        tags                TEXT NOT NULL DEFAULT '[]',
        sub_items           TEXT NOT NULL DEFAULT '[]',
        notes               TEXT NOT NULL DEFAULT '[]',
        progress            REAL NOT NULL DEFAULT 0.0,
        source_type         TEXT NOT NULL DEFAULT 'manual'
                            CHECK(source_type IN ('extract','track','digest','briefing','manual','chat',
                                                   'inbox','jira','slack','promoted_subitem','idea')),
        source_id           TEXT NOT NULL DEFAULT '',
        ai_level_confidence REAL DEFAULT NULL,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        notified_at         TEXT NOT NULL DEFAULT '',
        next_step           TEXT NOT NULL DEFAULT '',
        next_step_at        TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_targets_level       ON targets(level);
    CREATE INDEX IF NOT EXISTS idx_targets_parent      ON targets(parent_id);
    CREATE INDEX IF NOT EXISTS idx_targets_period      ON targets(period_start, period_end);
    CREATE INDEX IF NOT EXISTS idx_targets_status      ON targets(status);
    CREATE INDEX IF NOT EXISTS idx_targets_priority    ON targets(priority);
    CREATE INDEX IF NOT EXISTS idx_targets_due         ON targets(due_date);
    CREATE INDEX IF NOT EXISTS idx_targets_source      ON targets(source_type, source_id);
    CREATE INDEX IF NOT EXISTS idx_targets_updated     ON targets(updated_at DESC);
    CREATE INDEX IF NOT EXISTS idx_targets_due_unfired ON targets(due_date)
        WHERE notified_at = '' AND due_date != '';

    CREATE TABLE IF NOT EXISTS target_links (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        source_target_id    INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
        target_target_id    INTEGER REFERENCES targets(id) ON DELETE CASCADE,
        external_ref        TEXT NOT NULL DEFAULT '',
        relation            TEXT NOT NULL
                            CHECK(relation IN ('contributes_to','blocks','related','duplicates')),
        confidence          REAL DEFAULT NULL,
        created_by          TEXT NOT NULL DEFAULT 'ai'
                            CHECK(created_by IN ('ai','user')),
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX IF NOT EXISTS idx_target_links_source ON target_links(source_target_id);
    CREATE INDEX IF NOT EXISTS idx_target_links_target ON target_links(target_target_id);

    CREATE TABLE IF NOT EXISTS catchup_recaps (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        period_from     REAL NOT NULL,
        period_to       REAL NOT NULL,
        status          TEXT NOT NULL CHECK(status IN ('building','ready','failed')),
        tldr            TEXT NOT NULL DEFAULT '',
        body_json       TEXT NOT NULL DEFAULT '{}',
        coverage_json   TEXT NOT NULL DEFAULT '{}',
        error           TEXT NOT NULL DEFAULT '',
        regen_of_id     INTEGER REFERENCES catchup_recaps(id) ON DELETE SET NULL,
        acknowledged_at TEXT,
        model           TEXT NOT NULL DEFAULT '',
        input_tokens    INTEGER NOT NULL DEFAULT 0,
        output_tokens   INTEGER NOT NULL DEFAULT 0,
        cost_usd        REAL NOT NULL DEFAULT 0,
        created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX IF NOT EXISTS idx_catchup_recaps_ack ON catchup_recaps(acknowledged_at, period_to DESC);

    CREATE TABLE IF NOT EXISTS situations (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        title           TEXT NOT NULL,
        kind            TEXT NOT NULL DEFAULT 'external' CHECK(kind IN ('external','target_update','track_update','mixed')),
        status          TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','done','dismissed','converted','stale','snoozed')),
        snooze_until    TEXT NOT NULL DEFAULT '',
        priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
        rank            REAL NOT NULL DEFAULT 0,
        ai_reason       TEXT NOT NULL DEFAULT '',
        summary         TEXT NOT NULL DEFAULT '',
        why_matters     TEXT NOT NULL DEFAULT '',
        chronology      TEXT NOT NULL DEFAULT '',
        card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
        card_generated_at TEXT,
        target_id       INTEGER,
        track_id        INTEGER,
        converted_target_id INTEGER,
        converted_track_id  INTEGER,
        last_signal_at  TEXT NOT NULL DEFAULT '',
        resolved_reason TEXT NOT NULL DEFAULT '',
        suggested_resolution TEXT NOT NULL DEFAULT '',
        created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_situations_status_rank ON situations(status, rank DESC);
    CREATE INDEX IF NOT EXISTS idx_situations_updated ON situations(updated_at DESC);

    CREATE TABLE IF NOT EXISTS situation_signals (
        situation_id   INTEGER NOT NULL REFERENCES situations(id) ON DELETE CASCADE,
        inbox_item_id  INTEGER NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
        UNIQUE(situation_id, inbox_item_id)
    );
    CREATE INDEX IF NOT EXISTS idx_situation_signals_item ON situation_signals(inbox_item_id);

    CREATE TABLE IF NOT EXISTS meeting_prep_cache (
        event_id      TEXT PRIMARY KEY,
        result_json   TEXT NOT NULL DEFAULT '',
        user_notes    TEXT NOT NULL DEFAULT '',
        generated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS meeting_recaps (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id      TEXT UNIQUE REFERENCES calendar_events(id) ON DELETE SET NULL,
        transcript_id INTEGER REFERENCES meeting_transcripts(id) ON DELETE SET NULL,
        source_text   TEXT NOT NULL,
        recap_json    TEXT NOT NULL,
        created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    -- Meeting transcripts: locally-transcribed meeting audio (WhisperKit in the
    -- Desktop app). One row per recording. event_id is NULL for ad-hoc recordings
    -- and survives event deletion (SET NULL) — a transcript must outlive its
    -- calendar event. audio_path is NULLed by the daemon retention phase once the
    -- audio file is deleted; transcript_text is kept forever. summary_json holds
    -- the recap for ad-hoc recordings only (event-linked recaps live in
    -- meeting_recaps).
    CREATE TABLE IF NOT EXISTS meeting_transcripts (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id        TEXT REFERENCES calendar_events(id) ON DELETE SET NULL,
        title           TEXT NOT NULL,
        audio_path      TEXT,
        duration_sec    INTEGER NOT NULL DEFAULT 0,
        lang_stats      TEXT NOT NULL DEFAULT '',
        transcript_text TEXT NOT NULL,
        summary_json    TEXT,
        notes_md        TEXT,
        segments_json   TEXT,
        speakers_json   TEXT,
        chapters_json   TEXT,
        created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_meeting_transcripts_event ON meeting_transcripts(event_id);
    CREATE TABLE IF NOT EXISTS voice_prints (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        person_key   TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        embedding    BLOB NOT NULL,
        sample_count INTEGER NOT NULL DEFAULT 1,
        updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS feed_items (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        item_type   TEXT NOT NULL CHECK (item_type IN ('situation','meeting','briefing','meeting_recap','day_plan')),
        source_id   TEXT NOT NULL,
        event_ts    TEXT NOT NULL,
        importance  INTEGER NOT NULL DEFAULT 50,
        hidden_at   TEXT,
        seen_at     TEXT,
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(item_type, source_id)
    );
    CREATE INDEX IF NOT EXISTS idx_feed_items_event_ts ON feed_items(event_ts DESC);

    CREATE TABLE IF NOT EXISTS memory_nodes (
        id            TEXT PRIMARY KEY,
        type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
        tier          TEXT NOT NULL DEFAULT 'long' CHECK (tier IN ('short','long')),
        status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone','shaken','retired')),
        redirect_to   TEXT,
        title         TEXT NOT NULL DEFAULT '',
        path          TEXT NOT NULL DEFAULT '',
        content_hash  TEXT NOT NULL DEFAULT '',
        indexed_at    TEXT NOT NULL DEFAULT '',
        subject       TEXT NOT NULL DEFAULT '',
        confidence    REAL NOT NULL DEFAULT 0,
        importance_score REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS memory_aliases (
        alias    TEXT PRIMARY KEY COLLATE NOCASE,
        node_id  TEXT NOT NULL REFERENCES memory_nodes(id)
    );
    CREATE TABLE IF NOT EXISTS memory_provenance (
        node_id     TEXT NOT NULL REFERENCES memory_nodes(id),
        scheme      TEXT NOT NULL DEFAULT '',
        channel_id  TEXT NOT NULL,
        ts_raw      TEXT NOT NULL,
        ts_unix     REAL NOT NULL,
        sender_id   TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (node_id, channel_id, ts_raw)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
        id UNINDEXED, title, body
    );
    CREATE TABLE IF NOT EXISTS memory_dispute_flags (
        node_id     TEXT PRIMARY KEY REFERENCES memory_nodes(id),
        flagged_at  TEXT NOT NULL,
        reason      TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS email_accounts (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        provider       TEXT NOT NULL CHECK(provider IN ('imap','outlook')),
        email_address  TEXT NOT NULL DEFAULT '',
        host           TEXT NOT NULL DEFAULT '',
        port           INTEGER NOT NULL DEFAULT 0,
        security       TEXT NOT NULL DEFAULT 'ssl' CHECK(security IN ('ssl','starttls','none')),
        folder         TEXT NOT NULL DEFAULT 'INBOX',
        label          TEXT NOT NULL DEFAULT '',
        status         TEXT NOT NULL DEFAULT 'ok',
        error          TEXT NOT NULL DEFAULT '',
        last_uid       INTEGER NOT NULL DEFAULT 0,
        uidvalidity    INTEGER NOT NULL DEFAULT 0,
        created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS calendar_accounts (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        provider       TEXT NOT NULL CHECK(provider IN ('caldav','ics')),
        username       TEXT NOT NULL DEFAULT '',
        url            TEXT NOT NULL DEFAULT '',
        label          TEXT NOT NULL DEFAULT '',
        status         TEXT NOT NULL DEFAULT 'ok',
        error          TEXT NOT NULL DEFAULT '',
        created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS imap_messages (
        account_id     INTEGER NOT NULL REFERENCES email_accounts(id) ON DELETE CASCADE,
        uid            INTEGER NOT NULL,
        uidvalidity    INTEGER NOT NULL DEFAULT 0,
        from_email     TEXT NOT NULL DEFAULT '',
        from_name      TEXT NOT NULL DEFAULT '',
        to_json        TEXT NOT NULL DEFAULT '[]',
        cc_json        TEXT NOT NULL DEFAULT '[]',
        subject        TEXT NOT NULL DEFAULT '',
        snippet        TEXT NOT NULL DEFAULT '',
        body_text      TEXT NOT NULL DEFAULT '',
        internal_date  TEXT NOT NULL DEFAULT '',
        is_unread      INTEGER NOT NULL DEFAULT 0,
        permalink      TEXT NOT NULL DEFAULT '',
        synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (account_id, uidvalidity, uid)
    );

    CREATE TABLE IF NOT EXISTS ideas (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        kind            TEXT NOT NULL CHECK(kind IN ('idea','decision','note')),
        title           TEXT NOT NULL,
        essence         TEXT NOT NULL DEFAULT '',
        status          TEXT NOT NULL DEFAULT 'proposed'
                        CHECK(status IN ('proposed','active','rejected','not_now',
                                         'converted','dropped','merged','superseded','reversed')),
        source          TEXT NOT NULL DEFAULT 'mined' CHECK(source IN ('mined','owner')),
        snooze_until    TEXT NOT NULL DEFAULT '',
        needs_review    INTEGER NOT NULL DEFAULT 0,
        review_reason   TEXT NOT NULL DEFAULT '',
        similar_to_id   INTEGER,
        merged_into_id  INTEGER,
        superseded_by_id INTEGER,
        converted_target_id INTEGER,
        owner_rating    INTEGER NOT NULL DEFAULT 0,
        rating_comment  TEXT NOT NULL DEFAULT '',
        last_mention_at TEXT NOT NULL DEFAULT '',
        created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        seen_at         TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_ideas_status ON ideas(status, updated_at DESC);
    CREATE INDEX IF NOT EXISTS idx_ideas_kind ON ideas(kind, status);

    CREATE TABLE IF NOT EXISTS idea_mentions (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
        source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner')),
        ref         TEXT NOT NULL DEFAULT '',
        quote       TEXT NOT NULL DEFAULT '',
        author      TEXT NOT NULL DEFAULT '',
        said_at     TEXT NOT NULL DEFAULT '',
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX IF NOT EXISTS idx_idea_mentions_idea ON idea_mentions(idea_id);

    CREATE TABLE IF NOT EXISTS stream_digests (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        source       TEXT NOT NULL CHECK(source IN ('gmail','jira')),
        account_id   INTEGER NOT NULL,
        scope        TEXT NOT NULL DEFAULT '',
        period_from  TEXT NOT NULL,
        period_to    TEXT NOT NULL,
        topics_json  TEXT NOT NULL DEFAULT '[]',
        created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        read_at      TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_stream_digests_source ON stream_digests(source, account_id);
    CREATE TABLE IF NOT EXISTS agent_actions (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        tool            TEXT    NOT NULL,
        external        INTEGER NOT NULL DEFAULT 0,
        args_json       TEXT    NOT NULL,
        reason          TEXT    NOT NULL DEFAULT '',
        surface         TEXT    NOT NULL DEFAULT '',
        conversation_id INTEGER NOT NULL DEFAULT 0,
        context_type    TEXT    NOT NULL DEFAULT '',
        context_id      TEXT    NOT NULL DEFAULT '',
        turn_id         TEXT    NOT NULL DEFAULT '',
        status          TEXT    NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected','applied','failed','executing')),
        trust_at_create TEXT    NOT NULL DEFAULT 'ask' CHECK(trust_at_create IN ('ask','execute')),
        result_json     TEXT    NOT NULL DEFAULT '',
        error           TEXT    NOT NULL DEFAULT '',
        created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        decided_at      TEXT    NOT NULL DEFAULT '',
        applied_at      TEXT    NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS tool_trust (
        tool       TEXT PRIMARY KEY,
        trust      TEXT NOT NULL CHECK(trust IN ('ask','execute')), updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE TABLE IF NOT EXISTS external_connections (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT    NOT NULL UNIQUE,
        kind       TEXT    NOT NULL DEFAULT 'stdio'
                   CHECK(kind IN ('stdio','http')),
        command    TEXT    NOT NULL DEFAULT '',
        args_json  TEXT    NOT NULL DEFAULT '[]',
        url        TEXT    NOT NULL DEFAULT '',
        enabled    INTEGER NOT NULL DEFAULT 0,
        status     TEXT    NOT NULL DEFAULT 'ok',
        error      TEXT    NOT NULL DEFAULT '',
        created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE TABLE IF NOT EXISTS reaction_command_map (
        emoji      TEXT PRIMARY KEY,
        kind       TEXT    NOT NULL DEFAULT 'builtin_tool'
                   CHECK(kind IN ('builtin_tool','agent')),
        tool       TEXT    NOT NULL DEFAULT '',
        handler_id INTEGER NOT NULL DEFAULT 0,
        enabled    INTEGER NOT NULL DEFAULT 1,
        created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        updated_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE TABLE IF NOT EXISTS reminders (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id  INTEGER NOT NULL DEFAULT 0,
        message_ref TEXT    NOT NULL DEFAULT '',
        note        TEXT    NOT NULL DEFAULT '',
        remind_at   TEXT    NOT NULL,
        status      TEXT    NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','done','dismissed')),
        created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        done_at     TEXT    NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(status, remind_at);
    """
}

-- Canonical Geul application schema.
-- Apply directly with psql to a fresh database; no migration runtime or
-- database schema-version metadata is required.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgroonga;
CREATE EXTENSION IF NOT EXISTS ip4r;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pgmq;

DO $$
DECLARE
    reader pg_roles%ROWTYPE;
BEGIN
    SELECT * INTO reader
    FROM pg_roles
    WHERE rolname = 'geul_observability_reader';

    IF NOT FOUND THEN
        CREATE ROLE geul_observability_reader
            NOLOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            INHERIT
            NOREPLICATION
            NOBYPASSRLS;
    ELSIF reader.rolcanlogin
        OR reader.rolsuper
        OR reader.rolcreatedb
        OR reader.rolcreaterole
        OR reader.rolreplication
        OR reader.rolbypassrls THEN
        RAISE EXCEPTION 'geul_observability_reader exists with unsafe privileges';
    END IF;
END $$;

DO $$
DECLARE
    role_name text;
    existing_role pg_roles%ROWTYPE;
BEGIN
    FOREACH role_name IN ARRAY ARRAY[
        'geul_pgmq_api',
        'geul_pgmq_collab',
        'geul_pgmq_transcoder',
        'geul_pgmq_asset_optimizer',
        'geul_pgmq_og',
        'geul_pgmq_replay_operator'
    ]
    LOOP
        SELECT * INTO existing_role
        FROM pg_roles
        WHERE rolname = role_name;

        IF NOT FOUND THEN
            EXECUTE format(
                'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS',
                role_name
            );
        ELSIF existing_role.rolcanlogin
            OR existing_role.rolsuper
            OR existing_role.rolcreatedb
            OR existing_role.rolcreaterole
            OR existing_role.rolreplication
            OR existing_role.rolbypassrls THEN
            RAISE EXCEPTION '% exists with unsafe privileges', role_name;
        END IF;
    END LOOP;
END $$;

--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: observability; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA observability;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: form_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.form_status AS ENUM (
    'FORM_STATUS_DRAFT',
    'FORM_STATUS_PUBLISHED'
);


--
-- Name: mail_adapter_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.mail_adapter_type AS ENUM (
    'MAIL_ADAPTER_TYPE_LOGGING',
    'MAIL_ADAPTER_TYPE_SES',
    'MAIL_ADAPTER_TYPE_SMTP'
);


--
-- Name: post_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.post_status AS ENUM (
    'POST_STATUS_DRAFT',
    'POST_STATUS_SCHEDULED',
    'POST_STATUS_PUBLISHED',
    'POST_STATUS_ARCHIVED'
);


--
-- Name: release_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.release_type AS ENUM (
    'RELEASE_TYPE_ALBUM',
    'RELEASE_TYPE_EP',
    'RELEASE_TYPE_SINGLE',
    'RELEASE_TYPE_COMPILATION'
);


--
-- Name: translation_provider_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.translation_provider_type AS ENUM (
    'TRANSLATION_PROVIDER_TYPE_LLM',
    'TRANSLATION_PROVIDER_TYPE_DEEPL'
);


--
-- Name: work_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.work_type AS ENUM (
    'WORK_TYPE_MUSIC_PROJECT',
    'WORK_TYPE_PORTFOLIO',
    'WORK_TYPE_ARTICLE',
    'WORK_TYPE_CONTRIBUTION'
);


--
-- Name: assert_email_delivery_run_target_definition(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assert_email_delivery_run_target_definition(checked_run_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    checked_run email_delivery_run%ROWTYPE;
    user_tag_count BIGINT;
    user_role_count BIGINT;
    excluded_member_count BIGINT;
BEGIN
    SELECT *
    INTO checked_run
    FROM email_delivery_run
    WHERE id = checked_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF NOT checked_run.definition_sealed THEN
        RAISE EXCEPTION USING
            ERRCODE = 'check_violation',
            MESSAGE = format(
                'email delivery run %s definition must be sealed before commit',
                checked_run_id
            );
    END IF;

    SELECT COUNT(*)
    INTO user_tag_count
    FROM email_delivery_run_target_user_tag
    WHERE run_id = checked_run_id;

    SELECT COUNT(*)
    INTO user_role_count
    FROM email_delivery_run_target_user_role
    WHERE run_id = checked_run_id;

    SELECT COUNT(*)
    INTO excluded_member_count
    FROM email_delivery_run_target_excluded_member
    WHERE run_id = checked_run_id;

    IF (
        checked_run.target_mode = 'all_users'
        AND (
            user_tag_count <> 0
            OR user_role_count <> 0
            OR excluded_member_count <> 0
            OR checked_run.target_created_after IS NOT NULL
            OR checked_run.target_created_before IS NOT NULL
        )
    ) OR (
        checked_run.target_mode = 'user_tags'
        AND (
            user_tag_count = 0
            OR user_role_count <> 0
            OR excluded_member_count <> 0
            OR checked_run.target_created_after IS NOT NULL
            OR checked_run.target_created_before IS NOT NULL
        )
    ) OR (
        checked_run.target_mode = 'users_by_filter'
        AND user_tag_count <> 0
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'check_violation',
            MESSAGE = format(
                'email delivery run %s target associations do not match target_mode',
                checked_run_id
            );
    END IF;
END
$$;


--
-- Name: advance_post_configuration_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.advance_post_configuration_revision() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF ROW(NEW.slug, NEW.comments_enabled, NEW.map_place_id, NEW.document_layout)
       IS DISTINCT FROM
       ROW(OLD.slug, OLD.comments_enabled, OLD.map_place_id, OLD.document_layout) THEN
        NEW.configuration_revision := pg_catalog.gen_random_uuid();
    ELSE
        NEW.configuration_revision := OLD.configuration_revision;
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: geul_email_block_props_are_valid(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_email_block_props_are_valid(block_type text, props jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    allowed_keys TEXT[];
    prop_entry RECORD;
BEGIN
    allowed_keys := CASE block_type
        WHEN 'paragraph'
            THEN ARRAY[
                'backgroundColor',
                'textColor',
                'textAlignment'
            ]::TEXT[]
        WHEN 'heading'
            THEN ARRAY[
                'backgroundColor',
                'textColor',
                'textAlignment',
                'level',
                'isToggleable'
            ]::TEXT[]
        WHEN 'bulletListItem'
            THEN ARRAY[
                'backgroundColor',
                'textColor',
                'textAlignment'
            ]::TEXT[]
        WHEN 'numberedListItem'
            THEN ARRAY[
                'backgroundColor',
                'textColor',
                'textAlignment',
                'start'
            ]::TEXT[]
        WHEN 'checkListItem'
            THEN ARRAY[
                'backgroundColor',
                'textColor',
                'textAlignment',
                'checked'
            ]::TEXT[]
        WHEN 'quote'
            THEN ARRAY['backgroundColor', 'textColor']::TEXT[]
        WHEN 'divider'
            THEN ARRAY[]::TEXT[]
        WHEN 'table'
            THEN ARRAY['textColor']::TEXT[]
        WHEN 'codeBlock'
            THEN ARRAY['language']::TEXT[]
        ELSE NULL
    END;

    IF allowed_keys IS NULL
       OR NOT geul_json_object_has_only_keys(props, allowed_keys) THEN
        RETURN FALSE;
    END IF;

    FOR prop_entry IN
        SELECT key, value
        FROM jsonb_each(props)
    LOOP
        IF (
            prop_entry.key IN (
                'backgroundColor',
                'textColor',
                'textAlignment',
                'language'
            )
            AND jsonb_typeof(prop_entry.value) <> 'string'
        ) OR (
            prop_entry.key IN ('isToggleable', 'checked')
            AND jsonb_typeof(prop_entry.value) <> 'boolean'
        ) OR (
            prop_entry.key IN ('level', 'start')
            AND jsonb_typeof(prop_entry.value) <> 'number'
        ) THEN
            RETURN FALSE;
        END IF;
    END LOOP;

    RETURN TRUE;
END
$$;


--
-- Name: geul_email_content_blocks_are_valid(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_email_content_blocks_are_valid(blocks jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    block JSONB;
BEGIN
    IF jsonb_typeof(blocks) <> 'array'
       OR geul_json_has_relationship_authority(blocks)
       OR geul_json_has_media_block_type(blocks) THEN
        RETURN FALSE;
    END IF;

    FOR block IN
        SELECT value
        FROM jsonb_array_elements(blocks)
    LOOP
        IF NOT geul_json_object_has_only_keys(
            block,
            ARRAY['id', 'type', 'props', 'content', 'children']::TEXT[]
        )
           OR NOT (
                block ? 'id'
                AND block ? 'type'
                AND block ? 'props'
                AND block ? 'children'
           )
           OR jsonb_typeof(block->'id') <> 'string'
           OR NULLIF(BTRIM(block->>'id'), '') IS NULL
           OR jsonb_typeof(block->'type') <> 'string'
           OR block->>'type' NOT IN (
                'paragraph',
                'heading',
                'bulletListItem',
                'numberedListItem',
                'checkListItem',
                'quote',
                'divider',
                'table',
                'codeBlock'
           )
           OR NOT geul_email_block_props_are_valid(
                block->>'type',
                block->'props'
           )
           OR jsonb_typeof(block->'children') <> 'array'
           OR NOT geul_email_content_blocks_are_valid(
                block->'children'
           ) THEN
            RETURN FALSE;
        END IF;

        IF block->>'type' = 'divider' THEN
            IF block ? 'content'
               AND block->'content' <> 'null'::JSONB
               AND block->'content' <> '[]'::JSONB THEN
                RETURN FALSE;
            END IF;
        ELSIF block->>'type' = 'table' THEN
            IF NOT (block ? 'content')
               OR NOT geul_email_table_content_is_valid(
                    block->'content'
               ) THEN
                RETURN FALSE;
            END IF;
        ELSIF NOT (block ? 'content')
              OR NOT geul_email_inline_content_is_valid(
                    block->'content',
                    TRUE
              ) THEN
            RETURN FALSE;
        END IF;
    END LOOP;

    RETURN TRUE;
END
$$;


--
-- Name: geul_email_inline_content_is_valid(jsonb, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_email_inline_content_is_valid(inline_content jsonb, links_allowed boolean) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    inline_entry JSONB;
BEGIN
    IF jsonb_typeof(inline_content) <> 'array' THEN
        RETURN FALSE;
    END IF;

    FOR inline_entry IN
        SELECT value
        FROM jsonb_array_elements(inline_content)
    LOOP
        IF jsonb_typeof(inline_entry) <> 'object'
           OR jsonb_typeof(inline_entry->'type') <> 'string' THEN
            RETURN FALSE;
        END IF;

        IF inline_entry->>'type' = 'text' THEN
            IF NOT geul_json_object_has_only_keys(
                inline_entry,
                ARRAY['type', 'text', 'styles']::TEXT[]
            )
               OR NOT (
                    inline_entry ? 'text'
                    AND inline_entry ? 'styles'
               )
               OR jsonb_typeof(inline_entry->'text') <> 'string'
               OR NOT geul_email_text_styles_are_valid(
                    inline_entry->'styles'
               ) THEN
                RETURN FALSE;
            END IF;
        ELSIF inline_entry->>'type' = 'link' AND links_allowed THEN
            IF NOT geul_json_object_has_only_keys(
                inline_entry,
                ARRAY['type', 'href', 'content']::TEXT[]
            )
               OR NOT (
                    inline_entry ? 'href'
                    AND inline_entry ? 'content'
               )
               OR jsonb_typeof(inline_entry->'href') <> 'string'
               OR NULLIF(BTRIM(inline_entry->>'href'), '') IS NULL
               OR NOT geul_email_inline_content_is_valid(
                    inline_entry->'content',
                    FALSE
               ) THEN
                RETURN FALSE;
            END IF;
        ELSE
            RETURN FALSE;
        END IF;
    END LOOP;

    RETURN TRUE;
END
$$;


--
-- Name: geul_email_render_snapshot_is_valid(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_email_render_snapshot_is_valid(payload jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
BEGIN
    IF NOT geul_json_object_has_only_keys(
        payload,
        ARRAY[
            'subject',
            'content_html',
            'source_locale',
            'translations',
            'layout_source_locale',
            'layout_translations'
        ]::TEXT[]
    )
       OR geul_json_has_relationship_authority(payload)
       OR NOT (
            payload ? 'subject'
            AND payload ? 'content_html'
            AND payload ? 'source_locale'
            AND payload ? 'translations'
       )
       OR jsonb_typeof(payload->'subject') <> 'string'
       OR jsonb_typeof(payload->'content_html') <> 'string'
       OR jsonb_typeof(payload->'source_locale') <> 'string'
       OR NULLIF(BTRIM(payload->>'source_locale'), '') IS NULL
       OR NOT geul_render_translation_array_is_valid(
            payload->'translations',
            FALSE,
            payload->>'source_locale'
       )
       OR (
            (payload ? 'layout_source_locale')
            <> (payload ? 'layout_translations')
       )
       OR (
            payload ? 'layout_source_locale'
            AND (
                jsonb_typeof(payload->'layout_source_locale') <> 'string'
                OR NULLIF(
                    BTRIM(payload->>'layout_source_locale'),
                    ''
                ) IS NULL
            )
       )
       OR (
            payload ? 'layout_translations'
            AND NOT geul_render_translation_array_is_valid(
                payload->'layout_translations',
                TRUE,
                payload->>'layout_source_locale'
            )
       ) THEN
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END
$$;


--
-- Name: geul_email_table_cell_props_are_valid(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_email_table_cell_props_are_valid(props jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    prop_entry RECORD;
BEGIN
    IF NOT geul_json_object_has_only_keys(
        props,
        ARRAY[
            'backgroundColor',
            'textColor',
            'textAlignment',
            'colspan',
            'rowspan'
        ]::TEXT[]
    ) THEN
        RETURN FALSE;
    END IF;

    FOR prop_entry IN
        SELECT key, value
        FROM jsonb_each(props)
    LOOP
        IF (
            prop_entry.key IN (
                'backgroundColor',
                'textColor',
                'textAlignment'
            )
            AND jsonb_typeof(prop_entry.value) <> 'string'
        ) OR (
            prop_entry.key IN ('colspan', 'rowspan')
            AND jsonb_typeof(prop_entry.value) <> 'number'
        ) THEN
            RETURN FALSE;
        END IF;
    END LOOP;

    RETURN TRUE;
END
$$;


--
-- Name: geul_email_table_content_is_valid(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_email_table_content_is_valid(table_content jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    column_width JSONB;
    table_row JSONB;
    table_cell JSONB;
BEGIN
    IF NOT geul_json_object_has_only_keys(
        table_content,
        ARRAY[
            'type',
            'columnWidths',
            'headerRows',
            'headerCols',
            'rows'
        ]::TEXT[]
    )
       OR NOT (
            table_content ? 'type'
            AND table_content ? 'columnWidths'
            AND table_content ? 'rows'
       )
       OR table_content->>'type' <> 'tableContent'
       OR jsonb_typeof(table_content->'columnWidths') <> 'array'
       OR jsonb_typeof(table_content->'rows') <> 'array'
       OR (
            table_content ? 'headerRows'
            AND jsonb_typeof(table_content->'headerRows') <> 'number'
       )
       OR (
            table_content ? 'headerCols'
            AND jsonb_typeof(table_content->'headerCols') <> 'number'
       ) THEN
        RETURN FALSE;
    END IF;

    FOR column_width IN
        SELECT value
        FROM jsonb_array_elements(table_content->'columnWidths')
    LOOP
        IF jsonb_typeof(column_width) NOT IN ('number', 'null') THEN
            RETURN FALSE;
        END IF;
    END LOOP;

    FOR table_row IN
        SELECT value
        FROM jsonb_array_elements(table_content->'rows')
    LOOP
        IF NOT geul_json_object_has_only_keys(
            table_row,
            ARRAY['cells']::TEXT[]
        )
           OR NOT (table_row ? 'cells')
           OR jsonb_typeof(table_row->'cells') <> 'array' THEN
            RETURN FALSE;
        END IF;

        FOR table_cell IN
            SELECT value
            FROM jsonb_array_elements(table_row->'cells')
        LOOP
            IF jsonb_typeof(table_cell) = 'array' THEN
                IF NOT geul_email_inline_content_is_valid(
                    table_cell,
                    TRUE
                ) THEN
                    RETURN FALSE;
                END IF;
            ELSIF jsonb_typeof(table_cell) = 'object' THEN
                IF NOT geul_json_object_has_only_keys(
                    table_cell,
                    ARRAY['type', 'props', 'content']::TEXT[]
                )
                   OR NOT (
                        table_cell ? 'type'
                        AND table_cell ? 'props'
                        AND table_cell ? 'content'
                   )
                   OR table_cell->>'type' <> 'tableCell'
                   OR NOT geul_email_table_cell_props_are_valid(
                        table_cell->'props'
                   )
                   OR NOT geul_email_inline_content_is_valid(
                        table_cell->'content',
                        TRUE
                   ) THEN
                    RETURN FALSE;
                END IF;
            ELSE
                RETURN FALSE;
            END IF;
        END LOOP;
    END LOOP;

    RETURN TRUE;
END
$$;


--
-- Name: geul_email_template_data_is_valid(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_email_template_data_is_valid(checked_run_kind text, checked_event_key text, payload jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
DECLARE
    required_keys TEXT[];
    required_key TEXT;
BEGIN
    IF payload IS NULL
       OR jsonb_typeof(payload) <> 'object'
       OR geul_json_has_relationship_authority(payload) THEN
        RETURN FALSE;
    END IF;

    IF checked_run_kind = 'campaign' THEN
        RETURN payload = '{}'::JSONB;
    END IF;

    IF checked_run_kind <> 'legal_notice' THEN
        RETURN FALSE;
    END IF;

    required_keys := CASE checked_event_key
        WHEN 'terms_update'
            THEN ARRAY['policy_title', 'effective_date', 'preview_url']::TEXT[]
        WHEN 'privacy_update'
            THEN ARRAY['policy_title', 'effective_date', 'preview_url']::TEXT[]
        WHEN 'terms_effective'
            THEN ARRAY['terms_url']::TEXT[]
        WHEN 'privacy_effective'
            THEN ARRAY['privacy_url']::TEXT[]
        ELSE NULL
    END;

    IF required_keys IS NULL
       OR NOT geul_json_object_has_only_keys(payload, required_keys) THEN
        RETURN FALSE;
    END IF;

    FOREACH required_key IN ARRAY required_keys
    LOOP
        IF NOT (payload ? required_key)
           OR jsonb_typeof(payload->required_key) <> 'string'
           OR NULLIF(BTRIM(payload->>required_key), '') IS NULL THEN
            RETURN FALSE;
        END IF;
    END LOOP;

    RETURN TRUE;
END
$$;


--
-- Name: geul_email_text_styles_are_valid(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_email_text_styles_are_valid(styles jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    style_entry RECORD;
BEGIN
    IF NOT geul_json_object_has_only_keys(
        styles,
        ARRAY[
            'bold',
            'italic',
            'underline',
            'strike',
            'code',
            'textColor',
            'backgroundColor'
        ]::TEXT[]
    ) THEN
        RETURN FALSE;
    END IF;

    FOR style_entry IN
        SELECT key, value
        FROM jsonb_each(styles)
    LOOP
        IF (
            style_entry.key IN (
                'bold',
                'italic',
                'underline',
                'strike',
                'code'
            )
            AND jsonb_typeof(style_entry.value) <> 'boolean'
        ) OR (
            style_entry.key IN ('textColor', 'backgroundColor')
            AND jsonb_typeof(style_entry.value) <> 'string'
        ) THEN
            RETURN FALSE;
        END IF;
    END LOOP;

    RETURN TRUE;
END
$$;


--
-- Name: geul_json_has_media_block_type(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_json_has_media_block_type(payload jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    payload_entry RECORD;
    array_entry JSONB;
BEGIN
    IF jsonb_typeof(payload) = 'object' THEN
        IF jsonb_typeof(payload->'type') = 'string'
           AND payload->>'type' IN ('image', 'audio', 'video', 'file') THEN
            RETURN TRUE;
        END IF;

        FOR payload_entry IN
            SELECT value
            FROM jsonb_each(payload)
        LOOP
            IF jsonb_typeof(payload_entry.value) IN ('object', 'array')
               AND geul_json_has_media_block_type(payload_entry.value) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
    ELSIF jsonb_typeof(payload) = 'array' THEN
        FOR array_entry IN
            SELECT value
            FROM jsonb_array_elements(payload)
        LOOP
            IF jsonb_typeof(array_entry) IN ('object', 'array')
               AND geul_json_has_media_block_type(array_entry) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
    END IF;

    RETURN FALSE;
END
$$;


--
-- Name: geul_json_has_relationship_authority(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_json_has_relationship_authority(payload jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    payload_entry RECORD;
    array_entry JSONB;
    canonical_key TEXT;
BEGIN
    IF jsonb_typeof(payload) = 'object' THEN
        FOR payload_entry IN
            SELECT key, value
            FROM jsonb_each(payload)
        LOOP
            canonical_key := TRANSLATE(
                TRANSLATE(
                    payload_entry.key,
                    'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                    'abcdefghijklmnopqrstuvwxyz'
                ),
                '_-'
                    || CHR(9)
                    || CHR(10)
                    || CHR(11)
                    || CHR(12)
                    || CHR(13)
                    || CHR(32)
                    || CHR(133)
                    || CHR(160)
                    || CHR(5760)
                    || CHR(8192)
                    || CHR(8193)
                    || CHR(8194)
                    || CHR(8195)
                    || CHR(8196)
                    || CHR(8197)
                    || CHR(8198)
                    || CHR(8199)
                    || CHR(8200)
                    || CHR(8201)
                    || CHR(8202)
                    || CHR(8232)
                    || CHR(8233)
                    || CHR(8239)
                    || CHR(8287)
                    || CHR(12288),
                ''
            );

            IF canonical_key = ANY (ARRAY[
                'audience',
                'audiences',
                'audiencesegment',
                'audiencesegments',
                'audiencesegmentid',
                'audiencesegmentids',
                'audienceid',
                'audienceids',
                'asset',
                'assets',
                'assetid',
                'assetids',
                'attachment',
                'attachments',
                'attachmentid',
                'attachmentids',
                'audio',
                'audios',
                'audioid',
                'audioids',
                'block',
                'blocks',
                'blockid',
                'blockids',
                'campaign',
                'campaigns',
                'campaignid',
                'campaignids',
                'campaigntranslation',
                'campaigntranslations',
                'campaigntranslationid',
                'campaigntranslationids',
                'category',
                'categories',
                'categoryid',
                'categoryids',
                'client',
                'clients',
                'clientid',
                'clientids',
                'contentblock',
                'contentblocks',
                'contentblockid',
                'contentblockids',
                'createdafter',
                'createdbefore',
                'createdby',
                'definitionsealed',
                'deliveryrecipient',
                'deliveryrecipients',
                'deliveryrecipientid',
                'deliveryrecipientids',
                'deliveryrun',
                'deliveryruns',
                'deliveryrunid',
                'deliveryrunids',
                'editedby',
                'emaildeliveryrecipient',
                'emaildeliveryrecipients',
                'emaildeliveryrecipientid',
                'emaildeliveryrecipientids',
                'emaildeliveryrun',
                'emaildeliveryruns',
                'emaildeliveryrunid',
                'emaildeliveryrunids',
                'emaillayout',
                'emaillayouts',
                'emaillayoutid',
                'emaillayoutids',
                'emaillayouttranslation',
                'emaillayouttranslations',
                'emaillayouttranslationid',
                'emaillayouttranslationids',
                'emailsendoutbox',
                'emailsendoutboxes',
                'emailsendoutboxid',
                'emailsendoutboxids',
                'emailtemplate',
                'emailtemplates',
                'emailtemplateid',
                'emailtemplateids',
                'emailtemplatetranslation',
                'emailtemplatetranslations',
                'emailtemplatetranslationid',
                'emailtemplatetranslationids',
                'entity',
                'entities',
                'entityid',
                'entityids',
                'entitytype',
                'eventkey',
                'eventkeys',
                'excludedidentity',
                'excludedidentities',
                'excludedidentityid',
                'excludedidentityids',
                'excludeuser',
                'excludeusers',
                'excludeuserid',
                'excludeuserids',
                'file',
                'files',
                'fileid',
                'fileids',
                'filederivative',
                'filederivatives',
                'filederivativeid',
                'filederivativeids',
                'fileingestbinding',
                'fileingestbindings',
                'fileingestbindingid',
                'fileingestbindingids',
                'form',
                'forms',
                'formid',
                'formids',
                'identity',
                'identities',
                'identityid',
                'identityids',
                'ignoresubscriptionstatus',
                'layout',
                'layouts',
                'layoutid',
                'layoutids',
                'mapplace',
                'mapplaces',
                'mapplaceid',
                'mapplaceids',
                'media',
                'medias',
                'mediaid',
                'mediaids',
                'mediaasset',
                'mediaassets',
                'mediaassetid',
                'mediaassetids',
                'mediageneration',
                'mediagenerations',
                'mediagenerationid',
                'mediagenerationids',
                'menu',
                'menus',
                'menuid',
                'menuids',
                'menuitem',
                'menuitems',
                'menuitemid',
                'menuitemids',
                'ogasset',
                'ogassets',
                'ogassetid',
                'ogassetids',
                'outbox',
                'outboxes',
                'outboxid',
                'outboxids',
                'owner',
                'owners',
                'ownerid',
                'ownerids',
                'ownertype',
                'page',
                'pages',
                'pageid',
                'pageids',
                'parentid',
                'parentids',
                'post',
                'posts',
                'postid',
                'postids',
                'privacy',
                'privacies',
                'privacyhistories',
                'privacyhistory',
                'privacyhistoryid',
                'privacyhistoryids',
                'privacyid',
                'privacyids',
                'program',
                'programs',
                'programid',
                'programids',
                'programevent',
                'programevents',
                'programeventid',
                'programeventids',
                'provider',
                'providers',
                'providerid',
                'providerids',
                'providersource',
                'providersources',
                'providersourceid',
                'providersourceids',
                'publicasset',
                'publicassets',
                'publicassetid',
                'publicassetids',
                'recipientcontexttype',
                'recipientcontextdata',
                'recipient',
                'recipients',
                'recipientid',
                'recipientids',
                'reference',
                'references',
                'referenceid',
                'referenceids',
                'referencetype',
                'release',
                'releases',
                'releaseid',
                'releaseids',
                'role',
                'roles',
                'roleid',
                'roleids',
                'run',
                'runs',
                'runid',
                'runids',
                'runkind',
                'segment',
                'segments',
                'segmentid',
                'segmentids',
                'segmenttype',
                'series',
                'seriesid',
                'seriesids',
                'site',
                'sites',
                'siteid',
                'siteids',
                'sitesettings',
                'sitesettingsid',
                'source',
                'sources',
                'sourceid',
                'sourceids',
                'sourcecampaign',
                'sourcecampaigns',
                'sourcecampaignid',
                'sourcecampaignids',
                'sourcecampaignupdatedat',
                'sourcefile',
                'sourcefiles',
                'sourcefileid',
                'sourcefileids',
                'sourcelayout',
                'sourcelayouts',
                'sourcelayoutid',
                'sourcelayoutids',
                'sourcelayoutupdatedat',
                'sourceprivacy',
                'sourceprivacies',
                'sourceprivacyid',
                'sourceprivacyids',
                'sourceprivacyversion',
                'sourcetemplate',
                'sourcetemplates',
                'sourcetemplateid',
                'sourcetemplateids',
                'sourcetemplateupdatedat',
                'sourceterms',
                'sourcetermsid',
                'sourcetermsids',
                'sourcetermsversion',
                'subscriber',
                'subscribers',
                'subscriberid',
                'subscriberids',
                'subscribertag',
                'subscribertags',
                'subscribertagid',
                'subscribertagids',
                'tag',
                'tags',
                'tagid',
                'tagids',
                'target',
                'targets',
                'targetcreatedafter',
                'targetcreatedbefore',
                'targetexcludedidentity',
                'targetexcludedidentities',
                'targetexcludedidentityid',
                'targetexcludedidentityids',
                'targetid',
                'targetids',
                'targetignoresubscriptionstatus',
                'targetmode',
                'targetqueryversion',
                'targetsubscribertag',
                'targetsubscribertags',
                'targetsubscribertagid',
                'targetsubscribertagids',
                'targetuserrole',
                'targetuserroles',
                'targetusertag',
                'targetusertags',
                'targetusertagid',
                'targetusertagids',
                'rendersnapshot',
                'snapshotschemaversion',
                'templatedata',
                'templateeventkey',
                'templateeventkeys',
                'template',
                'templates',
                'templateid',
                'templateids',
                'terms',
                'termshistories',
                'termshistory',
                'termshistoryid',
                'termshistoryids',
                'termsid',
                'termsids',
                'track',
                'tracks',
                'trackid',
                'trackids',
                'translationid',
                'translationids',
                'updatedby',
                'user',
                'users',
                'userid',
                'userids',
                'userrole',
                'userroles',
                'usertag',
                'usertags',
                'usertagid',
                'usertagids',
                'video',
                'videos',
                'videoid',
                'videoids',
                'work',
                'works',
                'workid',
                'workids'
            ]::TEXT[]) THEN
                RETURN TRUE;
            END IF;

            IF jsonb_typeof(payload_entry.value) IN ('object', 'array')
               AND geul_json_has_relationship_authority(
                   payload_entry.value
               ) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
    ELSIF jsonb_typeof(payload) = 'array' THEN
        FOR array_entry IN
            SELECT value
            FROM jsonb_array_elements(payload)
        LOOP
            IF jsonb_typeof(array_entry) IN ('object', 'array')
               AND geul_json_has_relationship_authority(array_entry) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
    END IF;

    RETURN FALSE;
END
$$;


--
-- Name: geul_json_object_has_only_keys(jsonb, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_json_object_has_only_keys(payload jsonb, allowed_keys text[]) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
BEGIN
    IF jsonb_typeof(payload) <> 'object' THEN
        RETURN FALSE;
    END IF;

    RETURN NOT EXISTS (
        SELECT 1
        FROM jsonb_object_keys(payload) AS payload_key(key)
        WHERE NOT (payload_key.key = ANY (allowed_keys))
    );
END
$$;


--
-- Name: geul_pgmq_replay_file_ingest_projection(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_pgmq_replay_file_ingest_projection(stable_message_id text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pgmq'
    AS $_$
DECLARE
    queue_name constant text := 'release.track_original_audio.projection';
    archive_table text := pgmq.format_table_name(queue_name, 'a');
    replayed_transport_id bigint;
BEGIN
    IF stable_message_id IS NULL OR btrim(stable_message_id) = '' THEN
        RAISE EXCEPTION 'stable message id is required'
            USING ERRCODE = '22023';
    END IF;

    EXECUTE format(
        $query$
        WITH archived AS (
            DELETE FROM pgmq.%I
            WHERE msg_id = (
                SELECT msg_id
                FROM pgmq.%I
                WHERE message ->> 'message_id' = $1
                  AND archived_at >= clock_timestamp() - interval '7 days'
                ORDER BY archived_at, msg_id
                LIMIT 1
            )
            RETURNING message, headers
        )
        SELECT pgmq.send($2, message, headers, 0)
        FROM archived
        $query$,
        archive_table,
        archive_table
    )
    USING stable_message_id, queue_name
    INTO replayed_transport_id;

    RETURN replayed_transport_id;
END;
$_$;


--
-- Name: geul_render_translation_array_is_valid(jsonb, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geul_render_translation_array_is_valid(translations jsonb, layout_translation boolean, source_locale text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    translation JSONB;
    allowed_keys TEXT[];
    source_translation_count INTEGER := 0;
    seen_locales TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF jsonb_typeof(translations) <> 'array' THEN
        RETURN FALSE;
    END IF;

    allowed_keys := CASE
        WHEN layout_translation THEN
            ARRAY[
                'locale',
                'html_content'
            ]::TEXT[]
        ELSE
            ARRAY[
                'locale',
                'subject',
                'content_html'
            ]::TEXT[]
    END;

    FOR translation IN
        SELECT value
        FROM jsonb_array_elements(translations)
    LOOP
        IF NOT geul_json_object_has_only_keys(
            translation,
            allowed_keys
        )
           OR NOT (translation ? 'locale')
           OR jsonb_typeof(translation->'locale') <> 'string'
           OR NULLIF(BTRIM(translation->>'locale'), '') IS NULL
           OR (
                NOT layout_translation
                AND (
                    NOT (
                        translation ? 'subject'
                        AND translation ? 'content_html'
                    )
                    OR jsonb_typeof(translation->'subject') <> 'string'
                    OR jsonb_typeof(translation->'content_html') <> 'string'
                )
            )
           OR (
                layout_translation
                AND (
                    NOT (translation ? 'html_content')
                    OR jsonb_typeof(translation->'html_content') <> 'string'
                )
            ) THEN
            RETURN FALSE;
        END IF;

        IF translation->>'locale' = ANY(seen_locales) THEN
            RETURN FALSE;
        END IF;
        seen_locales := array_append(seen_locales, translation->>'locale');

        IF translation->>'locale' = source_locale THEN
            source_translation_count := source_translation_count + 1;
        END IF;
    END LOOP;

    RETURN source_translation_count = 1;
END
$$;


--
-- Name: email_array_is_normalized_sorted_unique(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.email_array_is_normalized_sorted_unique(input_array text[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
    SELECT input_array IS NOT NULL
       AND input_array = ARRAY(
           SELECT DISTINCT lower(btrim(candidate.email))
           FROM unnest(input_array) AS candidate(email)
           WHERE NULLIF(btrim(candidate.email), '') IS NOT NULL
             AND length(lower(btrim(candidate.email))) <= 254
           ORDER BY lower(btrim(candidate.email))
       );
$$;


--
-- Name: enforce_content_block_parent_acyclic(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_content_block_parent_acyclic() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
    current_document_id uuid;
    current_parent_id uuid;
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.document_id IS NOT DISTINCT FROM OLD.document_id
       AND NEW.parent_block_id IS NOT DISTINCT FROM OLD.parent_block_id THEN
        RETURN NULL;
    END IF;

    SELECT block.document_id, block.parent_block_id
    INTO current_document_id, current_parent_id
    FROM public.content_block AS block
    WHERE block.id = NEW.id;

    IF NOT FOUND OR current_parent_id IS NULL THEN
        RETURN NULL;
    END IF;

    IF EXISTS (
        WITH RECURSIVE ancestry AS (
            SELECT
                parent.id,
                parent.parent_block_id,
                ARRAY[parent.id]::uuid[] AS visited
            FROM public.content_block AS parent
            WHERE parent.document_id = current_document_id
              AND parent.id = current_parent_id

            UNION ALL

            SELECT
                parent.id,
                parent.parent_block_id,
                ancestry.visited || parent.id
            FROM ancestry
            JOIN public.content_block AS parent
              ON parent.document_id = current_document_id
             AND parent.id = ancestry.parent_block_id
            WHERE parent.id <> ALL (ancestry.visited)
        )
        SELECT 1
        FROM ancestry
        WHERE id = NEW.id
    ) THEN
        RAISE EXCEPTION 'content block tree contains a parent cycle'
            USING ERRCODE = '23514';
    END IF;

    RETURN NULL;
END;
$$;


--
-- Name: enforce_content_document_owner_contract(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_content_document_owner_contract() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    expected_profile text;
    actual_profile text;
    owner_count integer;
BEGIN
    expected_profile := CASE TG_TABLE_NAME
        WHEN 'post' THEN 'post'
        WHEN 'page' THEN 'page'
        WHEN 'work' THEN 'work'
        WHEN 'program_event' THEN 'program_event'
        WHEN 'campaign' THEN 'email'
        WHEN 'email_template' THEN 'email'
        WHEN 'privacy_history' THEN 'policy'
        WHEN 'terms_history' THEN 'policy'
        ELSE 'compact'
    END;

    SELECT profile INTO actual_profile
    FROM public.content_document
    WHERE id = NEW.content_document_id;
    IF actual_profile IS DISTINCT FROM expected_profile THEN
        RAISE EXCEPTION 'content document % profile %, expected % for %',
            NEW.content_document_id, actual_profile, expected_profile, TG_TABLE_NAME;
    END IF;

    SELECT
        (SELECT count(*) FROM public.post WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.page WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.work WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.program_event WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.artist WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.label WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.release WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.campaign WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.email_template WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.email_layout WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.form WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.menu WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.privacy_history WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.series WHERE content_document_id = NEW.content_document_id) +
        (SELECT count(*) FROM public.terms_history WHERE content_document_id = NEW.content_document_id)
    INTO owner_count;
    IF owner_count <> 1 THEN
        RAISE EXCEPTION 'content document % has % owners', NEW.content_document_id, owner_count;
    END IF;
    RETURN NULL;
END
$$;


--
-- Name: purge_pgmq_archives(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.purge_pgmq_archives(reference_time timestamp with time zone DEFAULT now()) RETURNS TABLE(queue_name text, retention interval, deleted_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pgmq'
    AS $_$
DECLARE
    target_queue text;
    retention_interval interval;
    archive_table text;
BEGIN
    FOR target_queue, retention_interval IN
        VALUES
            ('email.auth'::text, interval '1 hour'),
            ('release.track_original_audio.projection'::text, interval '7 days')
    LOOP
        archive_table := pgmq.format_table_name(target_queue, 'a');
        EXECUTE format(
            $query$
            WITH expired AS (
                SELECT msg_id
                FROM pgmq.%I
                WHERE archived_at < $1 - $2
                ORDER BY archived_at, msg_id
                LIMIT 1000
            )
            DELETE FROM pgmq.%I AS archive
            USING expired
            WHERE archive.msg_id = expired.msg_id
            $query$,
            archive_table,
            archive_table
        )
        USING reference_time, retention_interval;

        GET DIAGNOSTICS deleted_count = ROW_COUNT;
        queue_name := target_queue;
        retention := retention_interval;
        RETURN NEXT;
    END LOOP;
END;
$_$;


--
-- Name: reject_audience_segment_hard_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_audience_segment_hard_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = 'object_not_in_prerequisite_state',
        MESSAGE = format(
            'audience segment %s cannot be hard-deleted; use archive lifecycle',
            OLD.id
        );
END
$$;


--
-- Name: validate_content_block_attachment_download_policy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_content_block_attachment_download_policy() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    target_block_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'content_block' THEN
        target_block_id := CASE
            WHEN TG_OP = 'DELETE' THEN OLD.id
            ELSE NEW.id
        END;
    ELSE
        target_block_id := CASE
            WHEN TG_OP = 'DELETE' THEN OLD.block_id
            ELSE NEW.block_id
        END;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.content_block_attachment AS attachment
        JOIN public.content_block AS block ON block.id = attachment.block_id
        WHERE attachment.block_id = target_block_id
          AND (
              (
                  attachment.download_audience <> 'disabled'
                  AND (
                      attachment.selector_kind <> 'active'
                      OR block.kind <> 'file'
                      OR attachment.reference_path <> 'file'
                  )
              )
              OR (
                  attachment.download_audience <> 'restricted'
                  AND EXISTS (
                      SELECT 1
                      FROM public.content_block_attachment_download_audience_segment AS policy_segment
                      WHERE policy_segment.block_id = attachment.block_id
                        AND policy_segment.reference_path = attachment.reference_path
                  )
              )
          )
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'check_violation',
            MESSAGE = format(
                'content block %s has an invalid attachment download policy',
                target_block_id
            );
    END IF;

    RETURN NULL;
END
$$;


--
-- Name: validate_track_download_policy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_track_download_policy() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    target_track_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'track' THEN
        target_track_id := CASE
            WHEN TG_OP = 'DELETE' THEN OLD.id
            ELSE NEW.id
        END;
    ELSE
        target_track_id := CASE
            WHEN TG_OP = 'DELETE' THEN OLD.track_id
            ELSE NEW.track_id
        END;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.track
        WHERE id = target_track_id
          AND (
              (download_audience <> 'disabled' AND audio_original_file_id IS NULL)
              OR (
                  download_audience <> 'restricted'
                  AND EXISTS (
                      SELECT 1
                      FROM public.track_download_audience_segment AS policy_segment
                      WHERE policy_segment.track_id = target_track_id
                  )
              )
          )
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'check_violation',
            MESSAGE = format(
                'track %s has an invalid original-audio download policy',
                target_track_id
            );
    END IF;

    RETURN NULL;
END
$$;


--
-- Name: reject_email_delivery_recipient_attribution_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_email_delivery_recipient_attribution_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.run_id IS DISTINCT FROM OLD.run_id
       OR NEW.recipient_email IS DISTINCT FROM OLD.recipient_email
       OR NEW.normalized_recipient_email
            IS DISTINCT FROM OLD.normalized_recipient_email
       OR NEW.identity_id IS DISTINCT FROM OLD.identity_id
       OR NEW.member_id IS DISTINCT FROM OLD.member_id
       OR NEW.locale IS DISTINCT FROM OLD.locale
       OR NEW.recipient_context_type
            IS DISTINCT FROM OLD.recipient_context_type
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION USING
            ERRCODE = 'object_not_in_prerequisite_state',
            MESSAGE = 'email delivery recipient attribution is immutable';
    END IF;

    RETURN NEW;
END
$$;


--
-- Name: reject_email_delivery_recipient_direct_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_email_delivery_recipient_direct_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM email_delivery_run
        WHERE id = OLD.run_id
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'object_not_in_prerequisite_state',
            MESSAGE = 'email delivery recipient history can only be deleted with its run';
    END IF;

    RETURN OLD;
END
$$;


--
-- Name: reject_email_delivery_run_definition_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_email_delivery_run_definition_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    terminal_template_detach BOOLEAN;
    terminal_layout_detach BOOLEAN;
BEGIN
    terminal_template_detach := (
        OLD.status NOT IN ('scheduled', 'sending')
        AND OLD.source_template_id IS NOT NULL
        AND NEW.source_template_id IS NULL
    );
    terminal_layout_detach := (
        OLD.status NOT IN ('scheduled', 'sending')
        AND OLD.source_layout_id IS NOT NULL
        AND NEW.source_layout_id IS NULL
    );

    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.run_kind IS DISTINCT FROM OLD.run_kind
       OR NEW.campaign_id IS DISTINCT FROM OLD.campaign_id
       OR NEW.terms_id IS DISTINCT FROM OLD.terms_id
       OR NEW.privacy_id IS DISTINCT FROM OLD.privacy_id
       OR NEW.template_event_key IS DISTINCT FROM OLD.template_event_key
       OR NEW.template_data IS DISTINCT FROM OLD.template_data
       OR NEW.render_snapshot IS DISTINCT FROM OLD.render_snapshot
       OR (
            NEW.source_template_id IS DISTINCT FROM OLD.source_template_id
            AND NOT terminal_template_detach
       )
       OR (
            NEW.source_layout_id IS DISTINCT FROM OLD.source_layout_id
            AND NOT terminal_layout_detach
       )
       OR NEW.audience_segment_id IS DISTINCT FROM OLD.audience_segment_id
       OR NEW.source_campaign_updated_at
            IS DISTINCT FROM OLD.source_campaign_updated_at
       OR NEW.source_template_updated_at
            IS DISTINCT FROM OLD.source_template_updated_at
       OR NEW.source_layout_updated_at
            IS DISTINCT FROM OLD.source_layout_updated_at
       OR NEW.source_terms_version IS DISTINCT FROM OLD.source_terms_version
       OR NEW.source_privacy_version
            IS DISTINCT FROM OLD.source_privacy_version
       OR NEW.snapshot_schema_version
            IS DISTINCT FROM OLD.snapshot_schema_version
       OR NEW.target_query_version IS DISTINCT FROM OLD.target_query_version
       OR NEW.target_mode IS DISTINCT FROM OLD.target_mode
       OR NEW.target_recipient_scope
            IS DISTINCT FROM OLD.target_recipient_scope
       OR NEW.target_created_after IS DISTINCT FROM OLD.target_created_after
       OR NEW.target_created_before IS DISTINCT FROM OLD.target_created_before
       OR NEW.scheduled_at IS DISTINCT FROM OLD.scheduled_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR (
            OLD.definition_sealed
            AND NOT NEW.definition_sealed
       ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'object_not_in_prerequisite_state',
            MESSAGE = 'email delivery run source and target definition is immutable';
    END IF;

    RETURN NEW;
END
$$;


--
-- Name: reject_sealed_email_delivery_run_target_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_sealed_email_delivery_run_target_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    checked_run_id UUID;
    run_definition_sealed BOOLEAN;
BEGIN
    FOR checked_run_id, run_definition_sealed IN
        SELECT
            delivery_run.id,
            delivery_run.definition_sealed
        FROM email_delivery_run AS delivery_run
        JOIN (
            SELECT DISTINCT owner_id
            FROM UNNEST(
                CASE
                    WHEN TG_OP = 'INSERT'
                        THEN ARRAY[NEW.run_id]
                    WHEN TG_OP = 'DELETE'
                        THEN ARRAY[OLD.run_id]
                    ELSE ARRAY[OLD.run_id, NEW.run_id]
                END
            ) AS owners(owner_id)
        ) AS changed_owner
          ON changed_owner.owner_id = delivery_run.id
        ORDER BY delivery_run.id
        FOR UPDATE OF delivery_run
    LOOP
        IF run_definition_sealed THEN
            RAISE EXCEPTION USING
                ERRCODE = 'object_not_in_prerequisite_state',
                MESSAGE = 'sealed email delivery run target definition is immutable';
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: translation_protected_terms_are_valid(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.translation_protected_terms_are_valid(input_array text[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT COALESCE(
        bool_and(
            NULLIF(btrim(term), '') IS NOT NULL
            AND term = btrim(term)
        ),
        true
    )
    AND count(*) = count(DISTINCT btrim(term))
    FROM unnest(input_array) AS terms(term)
$$;


--
-- Name: uuid_array_is_sorted_unique(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.uuid_array_is_sorted_unique(input_array uuid[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT input_array = COALESCE(
        array_agg(DISTINCT value ORDER BY value),
        '{}'::uuid[]
    )
    FROM unnest(input_array) AS entries(value)
$$;


--
-- Name: validate_email_delivery_recipient_capture(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_email_delivery_recipient_capture() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.member AS member_row
        WHERE member_row.id = NEW.member_id
          AND member_row.account_identity_id = NEW.identity_id
          AND member_row.deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'foreign_key_violation',
            MESSAGE = format(
                'email delivery recipient member %s and identity %s are not an active bilateral pair at capture time',
                NEW.member_id,
                NEW.identity_id
            );
    END IF;

    RETURN NEW;
END
$$;


--
-- Name: validate_email_delivery_run_excluded_member_capture(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_email_delivery_run_excluded_member_capture() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.member AS member_row
        WHERE member_row.id = NEW.member_id
          AND member_row.account_identity_id = NEW.identity_id
          AND member_row.deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'foreign_key_violation',
            MESSAGE = format(
                'email delivery run exclusion member %s and identity %s are not an active bilateral pair at capture time',
                NEW.member_id,
                NEW.identity_id
            );
    END IF;

    RETURN NEW;
END
$$;


--
-- Name: validate_email_delivery_run_target_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_email_delivery_run_target_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    checked_run_id UUID;
BEGIN
    IF TG_TABLE_NAME = 'email_delivery_run' THEN
        IF TG_OP = 'DELETE' THEN
            checked_run_id := OLD.id;
        ELSE
            checked_run_id := NEW.id;
        END IF;
        PERFORM assert_email_delivery_run_target_definition(checked_run_id);
    ELSE
        FOR checked_run_id IN
            SELECT DISTINCT owner_id
            FROM UNNEST(
                CASE
                    WHEN TG_OP = 'INSERT'
                        THEN ARRAY[NEW.run_id]
                    WHEN TG_OP = 'DELETE'
                        THEN ARRAY[OLD.run_id]
                    ELSE ARRAY[OLD.run_id, NEW.run_id]
                END
            ) AS owners(owner_id)
            ORDER BY owner_id
        LOOP
            PERFORM assert_email_delivery_run_target_definition(
                checked_run_id
            );
        END LOOP;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: domain_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.domain_audit (
    audit_id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    actor_kind character varying(16) NOT NULL,
    actor_member_id uuid,
    actor_service character varying(64),
    action character varying(128) NOT NULL,
    target_type character varying(64) NOT NULL,
    target_id text NOT NULL,
    request_id uuid,
    trace_id character(32),
    span_id character(16),
    attributes jsonb NOT NULL,
    CONSTRAINT chk_domain_audit_action CHECK (((action)::text ~ '^[a-z0-9_]+(\.[a-z0-9_]+)+$'::text)),
    CONSTRAINT chk_domain_audit_actor CHECK (((((actor_kind)::text = 'anonymous'::text) AND (actor_member_id IS NULL) AND (actor_service IS NULL)) OR (((actor_kind)::text = 'member'::text) AND (actor_member_id IS NOT NULL) AND (actor_service IS NULL)) OR (((actor_kind)::text = 'system'::text) AND (actor_member_id IS NULL) AND (actor_service IS NOT NULL) AND ((actor_service)::text ~ '^[a-z0-9_-]{1,64}$'::text)))),
    CONSTRAINT chk_domain_audit_attributes CHECK ((jsonb_typeof(attributes) = 'object'::text)),
    CONSTRAINT chk_domain_audit_occurred_at CHECK (isfinite(occurred_at)),
    CONSTRAINT chk_domain_audit_target CHECK ((((target_type)::text ~ '^[a-z0-9_]{1,64}$'::text) AND ((char_length(target_id) >= 1) AND (char_length(target_id) <= 255)))),
    CONSTRAINT chk_domain_audit_trace CHECK (((((trace_id IS NULL) AND (span_id IS NULL)) OR ((trace_id ~ '^[0-9a-f]{32}$'::text) AND (trace_id !~ '^0+$'::text) AND (span_id ~ '^[0-9a-f]{16}$'::text) AND (span_id !~ '^0+$'::text))) IS TRUE))
);


--
-- Name: member; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.member (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_identity_id uuid,
    nickname text NOT NULL COLLATE pg_catalog."C",
    onboarded boolean DEFAULT false NOT NULL,
    primary_email character varying(254),
    available_emails text[] DEFAULT '{}'::text[] NOT NULL,
    bio text,
    website text,
    social_links jsonb DEFAULT '{}'::jsonb NOT NULL,
    preferred_locale text,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_member_active_profile CHECK (((account_identity_id IS NULL) OR ((deleted_at IS NULL) AND (primary_email IS NOT NULL) AND (cardinality(available_emails) > 0)))),
    CONSTRAINT chk_member_available_emails CHECK (public.email_array_is_normalized_sorted_unique(available_emails)),
    CONSTRAINT chk_member_deleted_tombstone CHECK (((deleted_at IS NULL) OR ((account_identity_id IS NULL) AND (bio IS NULL) AND (website IS NULL) AND (social_links = '{}'::jsonb) AND (preferred_locale IS NULL)))),
    CONSTRAINT chk_member_distinct_identity CHECK (((account_identity_id IS NULL) OR (id <> account_identity_id))),
    CONSTRAINT chk_member_email_selection CHECK ((((primary_email IS NULL) AND (cardinality(available_emails) = 0)) OR ((primary_email IS NOT NULL) AND ((primary_email)::text = ANY (available_emails))))),
    CONSTRAINT chk_member_nickname CHECK (((nickname = btrim(nickname)) AND ((char_length(nickname) >= 1) AND (char_length(nickname) <= 100)))),
    CONSTRAINT chk_member_primary_email CHECK (((primary_email IS NULL) OR ((NULLIF(btrim((primary_email)::text), ''::text) IS NOT NULL) AND ((primary_email)::text = lower(btrim((primary_email)::text)))))),
    CONSTRAINT chk_member_social_links_object CHECK ((jsonb_typeof(social_links) = 'object'::text)),
    CONSTRAINT chk_member_timestamps CHECK ((isfinite(created_at) AND isfinite(updated_at) AND (updated_at >= created_at) AND ((deleted_at IS NULL) OR (isfinite(deleted_at) AND (deleted_at >= created_at)))))
);


--
-- Name: member_personal_access_token; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.member_personal_access_token (
    selector text NOT NULL COLLATE pg_catalog."C",
    member_id uuid NOT NULL,
    secret_hash bytea NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    last_used_at timestamp with time zone,
    CONSTRAINT chk_member_personal_access_token_secret_hash CHECK (((octet_length(secret_hash) = 32) AND (secret_hash <> decode(repeat('00'::text, 32), 'hex'::text)))),
    CONSTRAINT chk_member_personal_access_token_selector CHECK ((selector ~ '^[A-Za-z0-9_-]{21}[AQgw]$'::text)),
    CONSTRAINT chk_member_personal_access_token_timestamps CHECK ((isfinite(created_at) AND isfinite(updated_at) AND (updated_at >= created_at) AND ((last_used_at IS NULL) OR isfinite(last_used_at))))
);


COMMENT ON TABLE public.member_personal_access_token IS 'The current Member-owned personal access token; one credential per Member, with deletion revoking and regeneration replacing the verifier in place without terminal history.';


COMMENT ON COLUMN public.member_personal_access_token.selector IS 'Canonical unpadded base64url selector for the 16-byte public credential identifier; never the bearer secret.';


COMMENT ON COLUMN public.member_personal_access_token.secret_hash IS 'SHA-256 verifier of the secret portion; plaintext bearer values are never stored.';


--
-- Name: security_access; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.security_access (
    access_id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    action character varying(128) NOT NULL,
    actor_kind character varying(16) NOT NULL,
    actor_member_id uuid,
    request_id uuid NOT NULL,
    trace_id character(32),
    span_id character(16),
    source_ip inet NOT NULL,
    attributes jsonb NOT NULL,
    CONSTRAINT chk_security_access_action CHECK (((action)::text ~ '^[a-z0-9_]+(\.[a-z0-9_]+)+$'::text)),
    CONSTRAINT chk_security_access_actor CHECK (((((actor_kind)::text = 'anonymous'::text) AND (actor_member_id IS NULL)) OR (((actor_kind)::text = 'member'::text) AND (actor_member_id IS NOT NULL)))),
    CONSTRAINT chk_security_access_attributes CHECK ((jsonb_typeof(attributes) = 'object'::text)),
    CONSTRAINT chk_security_access_occurred_at CHECK (isfinite(occurred_at)),
    CONSTRAINT chk_security_access_source_ip CHECK ((((family(source_ip) = 4) AND (masklen(source_ip) = 32)) OR ((family(source_ip) = 6) AND (masklen(source_ip) = 128)))),
    CONSTRAINT chk_security_access_trace CHECK (((((trace_id IS NULL) AND (span_id IS NULL)) OR ((trace_id ~ '^[0-9a-f]{32}$'::text) AND (trace_id !~ '^0+$'::text) AND (span_id ~ '^[0-9a-f]{16}$'::text) AND (span_id !~ '^0+$'::text))) IS TRUE))
);


--
-- Name: durable_record; Type: VIEW; Schema: observability; Owner: -
--

CREATE VIEW observability.durable_record AS
 SELECT 'domain_audit'::text AS record_class,
    audit.audit_id AS record_id,
    audit.occurred_at,
    (audit.actor_kind)::text AS actor_kind,
    audit.actor_member_id,
    (member.primary_email)::text AS actor_email,
    (audit.actor_service)::text AS actor_service,
    (audit.action)::text AS action,
    (audit.target_type)::text AS target_type,
    audit.target_id,
    NULL::text AS subject_type,
    NULL::text AS subject_id,
    NULL::inet AS source_ip,
    audit.request_id,
    (audit.trace_id)::text AS trace_id,
    (audit.span_id)::text AS span_id,
    (audit.attributes -> 'changed_fields'::text) AS changed_fields,
    (audit.attributes -> 'contributor_member_ids'::text) AS contributor_member_ids,
    (audit.attributes ->> 'collection_operation'::text) AS collection_operation,
    (audit.attributes ->> 'previous_state'::text) AS previous_state,
    (audit.attributes ->> 'new_state'::text) AS new_state,
    NULL::text AS flow_kind,
    NULL::text AS authentication_method,
    NULL::text AS principal_state,
    NULL::text AS provider,
    NULL::text AS reason,
    NULL::text AS attempted_action,
    NULL::text AS permission,
    NULL::text AS access_kind,
    NULL::text AS data_category,
    audit.attributes
   FROM (public.domain_audit audit
     LEFT JOIN public.member member ON ((member.id = audit.actor_member_id)))
UNION ALL
 SELECT 'security_access'::text AS record_class,
    access.access_id AS record_id,
    access.occurred_at,
    (access.actor_kind)::text AS actor_kind,
    access.actor_member_id,
    (member.primary_email)::text AS actor_email,
    NULL::text AS actor_service,
    (access.action)::text AS action,
    NULL::text AS target_type,
    NULL::text AS target_id,
    (access.attributes ->> 'subject_type'::text) AS subject_type,
    (access.attributes ->> 'subject_id'::text) AS subject_id,
    access.source_ip,
    access.request_id,
    (access.trace_id)::text AS trace_id,
    (access.span_id)::text AS span_id,
    NULL::jsonb AS changed_fields,
    NULL::jsonb AS contributor_member_ids,
    NULL::text AS collection_operation,
    NULL::text AS previous_state,
    NULL::text AS new_state,
    (access.attributes ->> 'flow_kind'::text) AS flow_kind,
    (access.attributes ->> 'authentication_method'::text) AS authentication_method,
    (access.attributes ->> 'principal_state'::text) AS principal_state,
    (access.attributes ->> 'provider'::text) AS provider,
    (access.attributes ->> 'reason'::text) AS reason,
    (access.attributes ->> 'attempted_action'::text) AS attempted_action,
    (access.attributes ->> 'permission'::text) AS permission,
    (access.attributes ->> 'access_kind'::text) AS access_kind,
    (access.attributes ->> 'data_category'::text) AS data_category,
    access.attributes
   FROM (public.security_access access
     LEFT JOIN public.member member ON ((member.id = access.actor_member_id)));


--
-- Name: account_email_change_request; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_email_change_request (
    id uuid NOT NULL,
    identity_id uuid NOT NULL,
    previous_email_address character varying(254) NOT NULL,
    requested_email_address character varying(254) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    member_id uuid NOT NULL,
    CONSTRAINT chk_account_email_change_request_distinct_addresses CHECK (((NULLIF(btrim((previous_email_address)::text), ''::text) IS NOT NULL) AND (NULLIF(btrim((requested_email_address)::text), ''::text) IS NOT NULL) AND ((previous_email_address)::text = lower(btrim((previous_email_address)::text))) AND ((requested_email_address)::text = lower(btrim((requested_email_address)::text))) AND ((previous_email_address)::text <> (requested_email_address)::text))),
    CONSTRAINT chk_account_email_change_request_distinct_ids CHECK ((member_id <> identity_id)),
    CONSTRAINT chk_account_email_change_request_timestamps CHECK (isfinite(created_at))
);


--
-- Name: account_identity; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_identity (
    id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: artist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.artist (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug character varying(255),
    real_name character varying(255),
    parent_artist_id uuid,
    country_code character varying(2),
    website character varying(500),
    social_links jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    status character varying(30) DEFAULT 'ARTIST_STATUS_DRAFT'::character varying NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    CONSTRAINT chk_artist_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0))),
    CONSTRAINT chk_artist_status CHECK (((status)::text = ANY (ARRAY['ARTIST_STATUS_DRAFT'::text, 'ARTIST_STATUS_PUBLISHED'::text])))
);


--
-- Name: artist_file; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.artist_file (
    artist_id uuid NOT NULL,
    file_id uuid NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: artist_label; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.artist_label (
    artist_id uuid NOT NULL,
    label_id uuid NOT NULL,
    sort_order integer
);


--
-- Name: artist_manager; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.artist_manager (
    artist_id uuid NOT NULL,
    member_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: artist_owner; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.artist_owner (
    artist_id uuid NOT NULL,
    member_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: artist_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.artist_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid
);


--
-- Name: audience_segment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audience_segment (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    segment_type character varying(30) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_after timestamp with time zone,
    created_before timestamp with time zone,
    archived_at timestamp with time zone,
    CONSTRAINT chk_audience_segment_archived_at CHECK (((archived_at IS NULL) OR (isfinite(archived_at) AND (archived_at >= '0001-01-01 00:00:00+00'::timestamp with time zone) AND (archived_at <= '9999-12-31 23:59:59.999999+00'::timestamp with time zone)))),
    CONSTRAINT chk_audience_segment_created_bounds CHECK ((((created_after IS NULL) OR (isfinite(created_after) AND (created_after >= '0001-01-01 00:00:00+00'::timestamp with time zone) AND (created_after <= '9999-12-31 23:59:59.999999+00'::timestamp with time zone))) AND ((created_before IS NULL) OR (isfinite(created_before) AND (created_before >= '0001-01-01 00:00:00+00'::timestamp with time zone) AND (created_before <= '9999-12-31 23:59:59.999999+00'::timestamp with time zone))) AND ((created_after IS NULL) OR (created_before IS NULL) OR (created_after <= created_before)))),
    CONSTRAINT chk_audience_segment_type CHECK (((segment_type)::text = ANY (ARRAY['SEGMENT_TYPE_ALL_MEMBERS'::text, 'SEGMENT_TYPE_MEMBER_TAGS'::text, 'SEGMENT_TYPE_MEMBERS_BY_FILTER'::text])))
);


--
-- Name: audience_segment_excluded_member; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audience_segment_excluded_member (
    audience_segment_id uuid NOT NULL,
    member_id uuid NOT NULL
);


--
-- Name: audience_segment_user_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audience_segment_user_role (
    audience_segment_id uuid NOT NULL,
    role character varying(16) NOT NULL,
    CONSTRAINT chk_audience_segment_user_role CHECK (((role)::text = ANY (ARRAY[('admin'::character varying)::text, ('author'::character varying)::text, ('user'::character varying)::text])))
);


--
-- Name: audience_segment_user_tag; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audience_segment_user_tag (
    audience_segment_id uuid NOT NULL,
    user_tag_id uuid NOT NULL
);


--
-- Name: auth_bootstrap_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_bootstrap_state (
    key text NOT NULL,
    identity_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    member_id uuid,
    CONSTRAINT chk_auth_bootstrap_state_member_link CHECK (((identity_id IS NULL) OR ((member_id IS NOT NULL) AND (member_id <> identity_id))))
);


--
-- Name: auth_code_issuance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_code_issuance (
    token text NOT NULL,
    purpose text NOT NULL,
    recipient_digest text NOT NULL,
    subject_digest text NOT NULL,
    client_ip_digest text NOT NULL,
    issued_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT auth_code_issuance_digest_shape CHECK (((recipient_digest ~ '^[0-9a-f]{64}$'::text) AND (subject_digest ~ '^[0-9a-f]{64}$'::text) AND (client_ip_digest ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT auth_code_issuance_expiry_order CHECK ((expires_at > issued_at)),
    CONSTRAINT auth_code_issuance_purpose_check CHECK ((purpose = ANY (ARRAY['login_code'::text, 'registration_code'::text, 'verification_code'::text]))),
    CONSTRAINT auth_code_issuance_token_shape CHECK ((token ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: campaign; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaign (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subject character varying(500) DEFAULT ''::character varying NOT NULL,
    content_html text,
    status character varying(30) DEFAULT 'CAMPAIGN_STATUS_DRAFT'::character varying NOT NULL,
    segment_id uuid,
    layout_id uuid,
    scheduled_at timestamp with time zone,
    sent_at timestamp with time zone,
    sent_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    name character varying(255) DEFAULT ''::character varying NOT NULL,
    target_mode character varying(16) NOT NULL,
    recipient_scope character varying(32) DEFAULT 'SUBSCRIBED_USERS'::character varying NOT NULL,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    CONSTRAINT chk_campaign_recipient_scope CHECK (((recipient_scope)::text = ANY (ARRAY[('SUBSCRIBED_USERS'::character varying)::text, ('ALL_MATCHING_USERS'::character varying)::text]))),
    CONSTRAINT chk_campaign_status CHECK (((status)::text = ANY (ARRAY['CAMPAIGN_STATUS_DRAFT'::text, 'CAMPAIGN_STATUS_SCHEDULED'::text, 'CAMPAIGN_STATUS_SENDING'::text, 'CAMPAIGN_STATUS_SENT'::text, 'CAMPAIGN_STATUS_FAILED'::text]))),
    CONSTRAINT chk_campaign_target_mode CHECK (((((target_mode)::text = 'all'::text) AND (segment_id IS NULL)) OR (((target_mode)::text = 'segment'::text) AND (segment_id IS NOT NULL))))
);


--
-- Name: campaign_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaign_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    subject text,
    content_html text,
    content_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.category (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(100) NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_category_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0)))
);


--
-- Name: client; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    website character varying(255),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    logo_light_file_id uuid,
    logo_dark_file_id uuid
);


--
-- Name: comment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comment (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    member_id uuid,
    parent_id uuid,
    content text NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: content_block; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_block (
    id uuid NOT NULL,
    document_id uuid NOT NULL,
    parent_block_id uuid,
    container_slot text NOT NULL,
    "position" integer NOT NULL,
    kind text NOT NULL,
    shared_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_content_block_container_slot CHECK ((container_slot ~ '^[a-z][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT chk_content_block_kind CHECK ((kind ~ '^[A-Za-z][A-Za-z0-9_-]{0,63}$'::text)),
    CONSTRAINT chk_content_block_parent_not_self CHECK (((parent_block_id IS NULL) OR (parent_block_id <> id))),
    CONSTRAINT chk_content_block_position CHECK (("position" >= 0)),
    CONSTRAINT chk_content_block_shared_data CHECK ((jsonb_typeof(shared_data) = 'object'::text))
);


--
-- Name: content_block_attachment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_block_attachment (
    block_id uuid NOT NULL,
    reference_path text NOT NULL,
    selector_kind text NOT NULL,
    file_id uuid,
    missing_kind text,
    download_audience text DEFAULT 'disabled'::text NOT NULL,
    CONSTRAINT chk_content_block_attachment_download_audience CHECK ((download_audience = ANY (ARRAY['disabled'::text, 'public'::text, 'authenticated'::text, 'restricted'::text]))),
    CONSTRAINT chk_content_block_attachment_download_selector CHECK (((selector_kind = 'active'::text) OR (download_audience = 'disabled'::text))),
    CONSTRAINT chk_content_block_attachment_reference_path CHECK (((reference_path = btrim(reference_path)) AND ((char_length(reference_path) >= 1) AND (char_length(reference_path) <= 512)) AND (reference_path !~ '[[:cntrl:]]'::text))),
    CONSTRAINT chk_content_block_attachment_selector CHECK ((((selector_kind = 'active'::text) AND (file_id IS NOT NULL) AND (missing_kind IS NULL)) OR ((selector_kind = 'missing'::text) AND (file_id IS NULL) AND (missing_kind = ANY (ARRAY['image'::text, 'audio'::text, 'video'::text, 'file'::text])))))
);


--
-- Name: content_block_attachment_download_audience_segment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_block_attachment_download_audience_segment (
    block_id uuid NOT NULL,
    reference_path text NOT NULL,
    audience_segment_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: content_block_locale; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_block_locale (
    block_id uuid NOT NULL,
    locale text NOT NULL,
    localized_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT chk_content_block_locale_localized_data CHECK ((jsonb_typeof(localized_data) = 'object'::text))
);


--
-- Name: content_document; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_document (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    profile text NOT NULL,
    revision uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_content_document_profile CHECK ((profile = ANY (ARRAY['post'::text, 'page'::text, 'work'::text, 'program_event'::text, 'compact'::text, 'email'::text, 'policy'::text])))
);


--
-- Name: country; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.country (
    code character varying(2) NOT NULL,
    name character varying(100) NOT NULL,
    native_name character varying(100)
);


--
-- Name: email_delivery_recipient; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_delivery_recipient (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    run_id uuid NOT NULL,
    recipient_email character varying(255) NOT NULL,
    normalized_recipient_email character varying(255) NOT NULL,
    identity_id uuid NOT NULL,
    locale character varying(20),
    recipient_context_type character varying(50) NOT NULL,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    error_type character varying(100),
    terminal_at timestamp with time zone,
    delivery_claim_id uuid,
    delivery_claim_expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    provider_message_id text,
    member_id uuid NOT NULL,
    CONSTRAINT chk_email_delivery_recipient_context CHECK (((recipient_context_type)::text = ANY (ARRAY[('newsletter_subscription'::character varying)::text, ('account_current'::character varying)::text]))),
    CONSTRAINT chk_email_delivery_recipient_distinct_ids CHECK ((member_id <> identity_id)),
    CONSTRAINT chk_email_delivery_recipient_result_values CHECK ((((provider_message_id IS NULL) OR (NULLIF(btrim(provider_message_id), ''::text) IS NOT NULL)) AND ((error_type IS NULL) OR (NULLIF(btrim((error_type)::text), ''::text) IS NOT NULL)))),
    CONSTRAINT chk_email_delivery_recipient_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('sent'::character varying)::text, ('delivered'::character varying)::text, ('skipped'::character varying)::text, ('permanent_failed'::character varying)::text, ('blocked'::character varying)::text, ('suppressed'::character varying)::text, ('bounced'::character varying)::text, ('complained'::character varying)::text]))),
    CONSTRAINT chk_email_delivery_recipient_terminal_result CHECK (((((status)::text = 'pending'::text) AND (terminal_at IS NULL) AND (provider_message_id IS NULL) AND (error_type IS NULL)) OR (((status)::text = ANY (ARRAY[('sent'::character varying)::text, ('delivered'::character varying)::text])) AND (terminal_at IS NOT NULL) AND isfinite(terminal_at) AND (error_type IS NULL)) OR (((status)::text = ANY (ARRAY[('skipped'::character varying)::text, ('permanent_failed'::character varying)::text, ('blocked'::character varying)::text, ('suppressed'::character varying)::text, ('bounced'::character varying)::text, ('complained'::character varying)::text])) AND (terminal_at IS NOT NULL) AND isfinite(terminal_at)))),
    CONSTRAINT chk_email_delivery_recipient_delivery_claim_pair CHECK (((delivery_claim_id IS NULL) = (delivery_claim_expires_at IS NULL)))
);


--
-- Name: email_delivery_run; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_delivery_run (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid,
    status character varying(50) NOT NULL,
    scheduled_at timestamp with time zone NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    template_event_key character varying(255),
    template_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    render_snapshot jsonb NOT NULL,
    target_count integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    failed_count integer DEFAULT 0 NOT NULL,
    blocked_count integer DEFAULT 0 NOT NULL,
    suppressed_count integer DEFAULT 0 NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    run_kind character varying(50) NOT NULL,
    terms_id uuid,
    privacy_id uuid,
    source_template_id uuid,
    source_layout_id uuid,
    audience_segment_id uuid,
    source_campaign_updated_at timestamp with time zone,
    source_template_updated_at timestamp with time zone,
    source_layout_updated_at timestamp with time zone,
    source_terms_version integer,
    source_privacy_version integer,
    snapshot_schema_version smallint NOT NULL,
    definition_sealed boolean DEFAULT false NOT NULL,
    target_query_version smallint NOT NULL,
    target_mode character varying(40) NOT NULL,
    target_created_after timestamp with time zone,
    target_created_before timestamp with time zone,
    target_recipient_scope character varying(32) NOT NULL,
    CONSTRAINT chk_email_delivery_run_kind CHECK (((run_kind)::text = ANY (ARRAY[('campaign'::character varying)::text, ('legal_notice'::character varying)::text]))),
    CONSTRAINT chk_email_delivery_run_recipient_scope CHECK (((target_recipient_scope)::text = ANY (ARRAY[('SUBSCRIBED_USERS'::character varying)::text, ('ALL_MATCHING_USERS'::character varying)::text]))),
    CONSTRAINT chk_email_delivery_run_render_snapshot CHECK (public.geul_email_render_snapshot_is_valid(render_snapshot)),
    CONSTRAINT chk_email_delivery_run_snapshot_schema_version CHECK ((snapshot_schema_version = 1)),
    CONSTRAINT chk_email_delivery_run_source_contract CHECK (((((run_kind)::text = 'campaign'::text) AND (campaign_id IS NOT NULL) AND (terms_id IS NULL) AND (privacy_id IS NULL) AND (source_campaign_updated_at IS NOT NULL) AND isfinite(source_campaign_updated_at) AND (source_campaign_updated_at >= '0001-01-01 00:00:00+00'::timestamp with time zone) AND (source_campaign_updated_at <= '9999-12-31 23:59:59.999999+00'::timestamp with time zone) AND (source_terms_version IS NULL) AND (source_privacy_version IS NULL) AND (source_template_id IS NULL) AND (source_template_updated_at IS NULL) AND (template_event_key IS NULL) AND (((target_mode)::text = 'all_users'::text) OR (audience_segment_id IS NOT NULL))) OR (((run_kind)::text = 'legal_notice'::text) AND (campaign_id IS NULL) AND (source_campaign_updated_at IS NULL) AND (num_nonnulls(terms_id, privacy_id) = 1) AND (((terms_id IS NOT NULL) AND (source_terms_version IS NOT NULL) AND (source_terms_version > 0) AND (privacy_id IS NULL) AND (source_privacy_version IS NULL)) OR ((privacy_id IS NOT NULL) AND (source_privacy_version IS NOT NULL) AND (source_privacy_version > 0) AND (terms_id IS NULL) AND (source_terms_version IS NULL))) AND ((source_template_id IS NOT NULL) OR ((status)::text <> ALL (ARRAY[('scheduled'::character varying)::text, ('sending'::character varying)::text]))) AND (source_template_updated_at IS NOT NULL) AND isfinite(source_template_updated_at) AND (source_template_updated_at >= '0001-01-01 00:00:00+00'::timestamp with time zone) AND (source_template_updated_at <= '9999-12-31 23:59:59.999999+00'::timestamp with time zone) AND (NULLIF(btrim((template_event_key)::text), ''::text) IS NOT NULL) AND (audience_segment_id IS NULL) AND ((target_mode)::text = 'all_users'::text) AND ((target_recipient_scope)::text = 'ALL_MATCHING_USERS'::text)))),
    CONSTRAINT chk_email_delivery_run_source_layout_pair CHECK ((((source_layout_id IS NULL) AND (source_layout_updated_at IS NULL)) OR ((source_layout_updated_at IS NOT NULL) AND isfinite(source_layout_updated_at) AND (source_layout_updated_at >= '0001-01-01 00:00:00+00'::timestamp with time zone) AND (source_layout_updated_at <= '9999-12-31 23:59:59.999999+00'::timestamp with time zone) AND ((source_layout_id IS NOT NULL) OR ((status)::text <> ALL (ARRAY[('scheduled'::character varying)::text, ('sending'::character varying)::text])))))),
    CONSTRAINT chk_email_delivery_run_status CHECK (((status)::text = ANY (ARRAY[('scheduled'::character varying)::text, ('sending'::character varying)::text, ('sent'::character varying)::text, ('failed'::character varying)::text, ('cancelled'::character varying)::text, ('skipped'::character varying)::text]))),
    CONSTRAINT chk_email_delivery_run_target_created_bounds CHECK ((((target_created_after IS NULL) OR (isfinite(target_created_after) AND (target_created_after >= '0001-01-01 00:00:00+00'::timestamp with time zone) AND (target_created_after <= '9999-12-31 23:59:59.999999+00'::timestamp with time zone))) AND ((target_created_before IS NULL) OR (isfinite(target_created_before) AND (target_created_before >= '0001-01-01 00:00:00+00'::timestamp with time zone) AND (target_created_before <= '9999-12-31 23:59:59.999999+00'::timestamp with time zone))) AND ((target_created_after IS NULL) OR (target_created_before IS NULL) OR (target_created_after <= target_created_before)))),
    CONSTRAINT chk_email_delivery_run_target_mode CHECK (((target_mode)::text = ANY (ARRAY[('all_users'::character varying)::text, ('user_tags'::character varying)::text, ('users_by_filter'::character varying)::text]))),
    CONSTRAINT chk_email_delivery_run_target_query_version CHECK ((target_query_version = 2)),
    CONSTRAINT chk_email_delivery_run_template_data CHECK (public.geul_email_template_data_is_valid((run_kind)::text, (template_event_key)::text, template_data))
);


--
-- Name: email_delivery_run_target_excluded_member; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_delivery_run_target_excluded_member (
    run_id uuid NOT NULL,
    identity_id uuid NOT NULL,
    member_id uuid NOT NULL,
    CONSTRAINT chk_email_delivery_run_target_excluded_member_distinct_ids CHECK ((member_id <> identity_id))
);


--
-- Name: email_delivery_run_target_user_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_delivery_run_target_user_role (
    run_id uuid NOT NULL,
    role character varying(16) NOT NULL,
    CONSTRAINT chk_email_delivery_run_target_user_role CHECK (((role)::text = ANY (ARRAY[('admin'::character varying)::text, ('author'::character varying)::text, ('user'::character varying)::text])))
);


--
-- Name: email_delivery_run_target_user_tag; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_delivery_run_target_user_tag (
    run_id uuid NOT NULL,
    user_tag_id uuid NOT NULL
);


--
-- Name: email_layout; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_layout (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    key character varying(100) NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    content_document_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_layout_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_layout_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    html_content text,
    content_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_suppression; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_suppression (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying(255) NOT NULL,
    reason character varying(50) NOT NULL,
    source character varying(50) NOT NULL,
    reference_id character varying(255),
    last_error text,
    suppressed_at timestamp with time zone DEFAULT now() NOT NULL,
    released_at timestamp with time zone,
    released_by character varying(255),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_email_suppression_reason CHECK (((reason)::text = ANY (ARRAY[('invalid_recipient'::character varying)::text, ('bounce'::character varying)::text, ('complaint'::character varying)::text, ('manual'::character varying)::text]))),
    CONSTRAINT chk_email_suppression_source CHECK (((source)::text = ANY (ARRAY[('email_worker'::character varying)::text, ('ses_callback'::character varying)::text, ('admin'::character varying)::text])))
);


--
-- Name: email_template; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_template (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key character varying(100) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    variables jsonb DEFAULT '[]'::jsonb,
    is_system boolean DEFAULT false,
    is_active boolean DEFAULT true,
    event_key character varying(100),
    layout_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL
);


--
-- Name: email_template_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_template_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    subject text,
    content_html text,
    content_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: file; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.file (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    file_name text NOT NULL,
    mime_type text NOT NULL,
    file_size bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    ingest_slot_id text,
    ingest_attempt_id text,
    client_media_bundle_id uuid,
    duration_seconds integer,
    extension text NOT NULL,
    sha256 bytea,
    delete_requested_at timestamp with time zone,
    folder_id uuid,
    uploaded_by_member_id uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_file_extension CHECK (((extension IS NULL) OR (extension ~ '^[a-z0-9][a-z0-9]{0,15}$'::text))),
    CONSTRAINT chk_file_name_basename CHECK (((file_name = btrim(file_name)) AND ((char_length(file_name) >= 1) AND (char_length(file_name) <= 255)) AND (strpos(file_name, '/'::text) = 0) AND (strpos(file_name, chr(92)) = 0) AND (lower("right"(file_name, (char_length(extension) + 1))) <> ('.'::text || lower(extension))))),
    CONSTRAINT chk_file_sha256 CHECK (((sha256 IS NULL) OR (octet_length(sha256) = 32)))
);


--
-- Name: file_derivative; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.file_derivative (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    file_id uuid NOT NULL,
    type text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    asset_id uuid,
    media_generation_id uuid,
    CONSTRAINT chk_file_derivative_delivery_ref_xor CHECK ((num_nonnulls(asset_id, media_generation_id) = 1))
);


-- Name: file_folder; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.file_folder (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    parent_id uuid,
    name text NOT NULL,
    created_by_member_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_file_folder_name CHECK (((name = btrim(name)) AND ((char_length(name) >= 1) AND (char_length(name) <= 255)) AND (name <> ALL (ARRAY['.'::text, '..'::text])) AND (strpos(name, '/'::text) = 0) AND (strpos(name, chr(92)) = 0)))
);


--
-- Name: file_ingest_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.file_ingest_binding (
    file_id uuid NOT NULL,
    upload_type text NOT NULL,
    entity_type text,
    entity_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_file_ingest_binding_entity_target CHECK ((((upload_type = 'UPLOAD_TYPE_GENERAL_FILE'::text) AND (entity_type IS NULL) AND (entity_id IS NULL)) OR ((upload_type = ANY (ARRAY['UPLOAD_TYPE_EDITOR_IMAGE'::text, 'UPLOAD_TYPE_EDITOR_AUDIO'::text, 'UPLOAD_TYPE_EDITOR_VIDEO'::text, 'UPLOAD_TYPE_EDITOR_ATTACHMENT'::text, 'UPLOAD_TYPE_EDITOR_MESH'::text])) AND (((entity_type IS NULL) AND (entity_id IS NULL)) OR (NULLIF(btrim(entity_id), ''::text) IS NOT NULL))) OR ((upload_type <> ALL (ARRAY['UPLOAD_TYPE_GENERAL_FILE'::text, 'UPLOAD_TYPE_EDITOR_IMAGE'::text, 'UPLOAD_TYPE_EDITOR_AUDIO'::text, 'UPLOAD_TYPE_EDITOR_VIDEO'::text, 'UPLOAD_TYPE_EDITOR_ATTACHMENT'::text, 'UPLOAD_TYPE_EDITOR_MESH'::text])) AND (NULLIF(btrim(entity_id), ''::text) IS NOT NULL)))),
    CONSTRAINT chk_file_ingest_binding_upload_type CHECK ((NULLIF(upload_type, ''::text) IS NOT NULL))
);


--
-- Name: form; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.form (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug character varying(255),
    status public.form_status DEFAULT 'FORM_STATUS_DRAFT'::public.form_status NOT NULL,
    is_public boolean DEFAULT false NOT NULL,
    require_auth boolean DEFAULT false,
    allowed_roles text[],
    allow_duplicate_submission boolean DEFAULT true,
    access_password character varying(255),
    max_submissions integer,
    opens_at timestamp with time zone,
    closes_at timestamp with time zone,
    featured_image_file_id uuid,
    source_locale text DEFAULT 'en'::text NOT NULL,
    content_document_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid,
    CONSTRAINT chk_form_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0)))
);


--
-- Name: form_submission; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.form_submission (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    form_id uuid NOT NULL,
    member_id uuid,
    data jsonb NOT NULL,
    ip_address character varying(45),
    country_code character varying(2),
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: form_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.form_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    content_json jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    content_text text,
    og_asset_id uuid
);


--
-- Name: format; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.format (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(50) NOT NULL,
    slug character varying(50) NOT NULL,
    CONSTRAINT chk_format_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0)))
);


--
-- Name: genre; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genre (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(100) NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_genre_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0)))
);


--
-- Name: geoip_location; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.geoip_location (
    geoname_id integer NOT NULL,
    continent_code character(2),
    continent_name character varying(50),
    country_iso_code character(2),
    country_name character varying(100),
    subdivision_1_iso_code character varying(10),
    subdivision_1_name character varying(100),
    subdivision_2_iso_code character varying(10),
    subdivision_2_name character varying(100),
    city_name character varying(100),
    metro_code smallint,
    time_zone character varying(50),
    is_in_european_union boolean NOT NULL
);


--
-- Name: geoip_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.geoip_metadata (
    id integer NOT NULL,
    database_type character varying(50) NOT NULL,
    build_epoch timestamp without time zone,
    imported_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    record_count_location integer,
    record_count_network integer
);


--
-- Name: geoip_metadata_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.geoip_metadata_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: geoip_metadata_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.geoip_metadata_id_seq OWNED BY public.geoip_metadata.id;


--
-- Name: geoip_network; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.geoip_network (
    network public.iprange NOT NULL,
    geoname_id integer,
    registered_country_geoname_id integer,
    represented_country_geoname_id integer,
    is_anonymous_proxy boolean NOT NULL,
    is_satellite_provider boolean NOT NULL,
    postal_code character varying(50),
    location public.geography(Point,4326),
    accuracy_radius smallint
);


--
-- Name: label; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.label (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug character varying(255),
    country_code character varying(2),
    website character varying(500),
    social_links jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    parent_label_id uuid,
    status character varying(30) DEFAULT 'LABEL_STATUS_DRAFT'::character varying NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    logo_light_file_id uuid,
    logo_dark_file_id uuid,
    og_asset_id uuid,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    CONSTRAINT chk_label_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0))),
    CONSTRAINT chk_label_status CHECK (((status)::text = ANY (ARRAY['LABEL_STATUS_DRAFT'::text, 'LABEL_STATUS_PUBLISHED'::text])))
);


--
-- Name: label_manager; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.label_manager (
    label_id uuid NOT NULL,
    member_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: label_owner; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.label_owner (
    label_id uuid NOT NULL,
    member_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: label_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.label_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mail_adapter; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mail_adapter (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    type public.mail_adapter_type NOT NULL,
    is_active boolean DEFAULT false NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: map_place; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.map_place (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    address text NOT NULL,
    address_components jsonb,
    lat numeric(10,8) NOT NULL,
    lng numeric(11,8) NOT NULL,
    geom public.geometry(Point,4326) GENERATED ALWAYS AS (public.st_setsrid(public.st_makepoint((lng)::double precision, (lat)::double precision), 4326)) STORED,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by_member_id uuid,
    updated_by_member_id uuid,
    google_place_id character varying(255),
    image_file_id uuid
);


--
-- Name: map_theme; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.map_theme (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    callout_scale real DEFAULT 1 NOT NULL,
    callout_offset_x integer DEFAULT 0 NOT NULL,
    callout_offset_y integer DEFAULT 0 NOT NULL,
    callout_fields text[] DEFAULT ARRAY['name'::text, 'address'::text] NOT NULL,
    attribution_font_size integer DEFAULT 11 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    show_area_labels boolean DEFAULT true NOT NULL,
    show_poi_labels boolean DEFAULT false NOT NULL,
    light_background_color character varying(50) NOT NULL,
    light_water_color character varying(50) NOT NULL,
    light_land_color character varying(50) NOT NULL,
    light_road_color character varying(50) NOT NULL,
    light_building_fill_color character varying(50) NOT NULL,
    light_building_stroke_enabled boolean NOT NULL,
    light_building_stroke_color character varying(50) NOT NULL,
    light_callout_line_color character varying(50) NOT NULL,
    light_callout_text_color character varying(50) NOT NULL,
    light_callout_background_color character varying(50) NOT NULL,
    light_callout_description_color character varying(50) NOT NULL,
    light_attribution_color character varying(50) NOT NULL,
    light_label_text_color character varying(50) NOT NULL,
    light_cluster_color character varying(50) NOT NULL,
    light_cluster_hover_color character varying(50) NOT NULL,
    light_cluster_text_color character varying(50) NOT NULL,
    light_cluster_text_hover_color character varying(50) NOT NULL,
    light_callout_hover_line_color character varying(50) NOT NULL,
    light_callout_hover_text_color character varying(50) NOT NULL,
    light_callout_hover_description_color character varying(50) NOT NULL,
    light_callout_hover_background_color character varying(50) NOT NULL,
    dark_background_color character varying(50) NOT NULL,
    dark_water_color character varying(50) NOT NULL,
    dark_land_color character varying(50) NOT NULL,
    dark_road_color character varying(50) NOT NULL,
    dark_building_fill_color character varying(50) NOT NULL,
    dark_building_stroke_enabled boolean NOT NULL,
    dark_building_stroke_color character varying(50) NOT NULL,
    dark_callout_line_color character varying(50) NOT NULL,
    dark_callout_text_color character varying(50) NOT NULL,
    dark_callout_background_color character varying(50) NOT NULL,
    dark_callout_description_color character varying(50) NOT NULL,
    dark_attribution_color character varying(50) NOT NULL,
    dark_label_text_color character varying(50) NOT NULL,
    dark_cluster_color character varying(50) NOT NULL,
    dark_cluster_hover_color character varying(50) NOT NULL,
    dark_cluster_text_color character varying(50) NOT NULL,
    dark_cluster_text_hover_color character varying(50) NOT NULL,
    dark_callout_hover_line_color character varying(50) NOT NULL,
    dark_callout_hover_text_color character varying(50) NOT NULL,
    dark_callout_hover_description_color character varying(50) NOT NULL,
    dark_callout_hover_background_color character varying(50) NOT NULL,
    edit_version bigint DEFAULT 1 NOT NULL,
    CONSTRAINT chk_map_theme_edit_version CHECK ((edit_version > 0))
);


--
-- Name: media_generation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_generation (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    file_id uuid NOT NULL,
    kind text DEFAULT 'hls'::text NOT NULL,
    object_prefix text NOT NULL,
    manifest_name text DEFAULT 'master.m3u8'::text NOT NULL,
    manifest_sha256 bytea,
    object_count integer,
    total_size bigint,
    status text DEFAULT 'allocated'::text NOT NULL,
    ready_at timestamp with time zone,
    retired_at timestamp with time zone,
    delete_after timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_media_generation_counts CHECK ((((object_count IS NULL) OR (object_count > 0)) AND ((total_size IS NULL) OR (total_size > 0)))),
    CONSTRAINT chk_media_generation_kind CHECK ((kind = 'hls'::text)),
    CONSTRAINT chk_media_generation_manifest CHECK ((manifest_name = 'master.m3u8'::text)),
    CONSTRAINT chk_media_generation_manifest_sha256 CHECK (((manifest_sha256 IS NULL) OR (octet_length(manifest_sha256) = 32))),
    CONSTRAINT chk_media_generation_prefix CHECK ((object_prefix = ((('media/'::text || (file_id)::text) || '/hls/'::text) || (id)::text))),
    CONSTRAINT chk_media_generation_ready_metadata CHECK (((status <> ALL (ARRAY['ready'::text, 'retired'::text])) OR ((manifest_sha256 IS NOT NULL) AND (object_count IS NOT NULL) AND (total_size IS NOT NULL) AND (ready_at IS NOT NULL)))),
    CONSTRAINT chk_media_generation_retirement CHECK (((status <> 'retired'::text) OR ((retired_at IS NOT NULL) AND (delete_after IS NOT NULL) AND (delete_after >= (retired_at + '07:00:00'::interval))))),
    CONSTRAINT chk_media_generation_status CHECK ((status = ANY (ARRAY['allocated'::text, 'ready'::text, 'retired'::text])))
);


--
-- Name: menu; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.menu (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    items jsonb DEFAULT '[]'::jsonb NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    content_document_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: menu_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.menu_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    items_json jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mesh_optimization_candidate; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mesh_optimization_candidate (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_file_id uuid NOT NULL,
    output_file_id uuid,
    entity_type text,
    entity_id uuid,
    target_ratio_percent integer NOT NULL,
    method text NOT NULL,
    pipeline_version text NOT NULL,
    cache_key text NOT NULL,
    status text NOT NULL,
    job_id text,
    original_file_size bigint,
    optimized_file_size bigint,
    processing_time_ms bigint,
    original_vertexes bigint,
    optimized_vertexes bigint,
    original_triangles bigint,
    optimized_triangles bigint,
    error_message text,
    selected_at timestamp with time zone,
    expires_at timestamp with time zone,
    enqueued_at timestamp with time zone,
    processing_started_at timestamp with time zone,
    completed_at timestamp with time zone,
    failed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    public_asset_id uuid,
    output_object_id uuid NOT NULL,
    CONSTRAINT chk_mesh_optimization_candidate_method CHECK ((method = 'DRACO'::text)),
    CONSTRAINT chk_mesh_optimization_candidate_status CHECK ((status = ANY (ARRAY['pending'::text, 'processing'::text, 'ready'::text, 'failed'::text, 'cancelled'::text]))),
    CONSTRAINT chk_mesh_optimization_candidate_target_ratio CHECK (((target_ratio_percent >= 1) AND (target_ratio_percent <= 100)))
);


--
-- Name: metadata_ai_job; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.metadata_ai_job (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    requester_member_id uuid NOT NULL,
    target_type character varying(100) NOT NULL,
    target_id text NOT NULL,
    requested_keys jsonb DEFAULT '[]'::jsonb NOT NULL,
    context text NOT NULL,
    prompt text NOT NULL,
    status character varying(50) DEFAULT 'queued'::character varying NOT NULL,
    suggestion jsonb,
    response_text text,
    error text,
    provider character varying(100),
    model character varying(255),
    duration_ms bigint,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: newsletter_subscription; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.newsletter_subscription (
    identity_id uuid NOT NULL,
    subscribed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_newsletter_subscription_subscribed_at CHECK (isfinite(subscribed_at))
);


--
-- Name: og_generation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.og_generation (
    id uuid NOT NULL,
    run_id uuid NOT NULL,
    target_id uuid NOT NULL,
    request_sequence bigint NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    entity_snapshot jsonb NOT NULL,
    processing_at timestamp with time zone,
    lease_token uuid,
    lease_expires_at timestamp with time zone,
    deadline_at timestamp with time zone DEFAULT (now() + '00:30:00'::interval) NOT NULL,
    last_error_code text,
    ready_at timestamp with time zone,
    failed_at timestamp with time zone,
    superseded_at timestamp with time zone,
    superseded_by_id uuid,
    cancelled_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_og_generation_deadline CHECK ((deadline_at > created_at)),
    CONSTRAINT chk_og_generation_entity_snapshot CHECK ((jsonb_typeof(entity_snapshot) = 'object'::text)),
    CONSTRAINT chk_og_generation_failure_reason CHECK ((((status = 'failed'::text) AND (last_error_code IS NOT NULL) AND (last_error_code = ANY (ARRAY['invalid_claim'::text, 'source_rejected'::text, 'processing_failed'::text, 'integrity_failed'::text, 'completion_rejected'::text]))) OR ((status <> 'failed'::text) AND (last_error_code IS NULL)))),
    CONSTRAINT chk_og_generation_processing_lease CHECK ((((status = 'processing'::text) AND (processing_at IS NOT NULL) AND (lease_token IS NOT NULL) AND (lease_expires_at IS NOT NULL) AND (lease_expires_at > processing_at)) OR ((status = ANY (ARRAY['ready'::text, 'superseded'::text])) AND (((lease_token IS NULL) AND (lease_expires_at IS NULL)) OR ((processing_at IS NOT NULL) AND (lease_token IS NOT NULL) AND (lease_expires_at IS NOT NULL) AND (lease_expires_at > processing_at)))) OR ((status = ANY (ARRAY['queued'::text, 'failed'::text, 'cancelled'::text])) AND (lease_token IS NULL) AND (lease_expires_at IS NULL)))),
    CONSTRAINT chk_og_generation_status CHECK ((status = ANY (ARRAY['queued'::text, 'processing'::text, 'ready'::text, 'failed'::text, 'superseded'::text, 'cancelled'::text]))),
    CONSTRAINT chk_og_generation_terminal_state CHECK ((((status = ANY (ARRAY['queued'::text, 'processing'::text])) AND (completed_at IS NULL)) OR ((status = 'ready'::text) AND (ready_at IS NOT NULL) AND (completed_at IS NOT NULL)) OR ((status = 'failed'::text) AND (failed_at IS NOT NULL) AND (completed_at IS NOT NULL)) OR ((status = 'superseded'::text) AND (superseded_at IS NOT NULL) AND (superseded_by_id IS NOT NULL) AND (superseded_by_id <> id) AND (completed_at IS NOT NULL)) OR ((status = 'cancelled'::text) AND (cancelled_at IS NOT NULL) AND (completed_at IS NOT NULL))))
);


--
-- Name: og_generation_request_sequence_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.og_generation ALTER COLUMN request_sequence ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.og_generation_request_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: og_generation_run; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.og_generation_run (
    id uuid DEFAULT gen_random_uuid() CONSTRAINT og_generation_run_id_not_null1 NOT NULL,
    trigger_kind text NOT NULL,
    reason text NOT NULL,
    render_config_snapshot jsonb NOT NULL,
    config_revision text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_og_generation_run_config_revision CHECK ((config_revision ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT chk_og_generation_run_reason CHECK ((NULLIF(btrim(reason), ''::text) IS NOT NULL)),
    CONSTRAINT chk_og_generation_run_render_config CHECK ((jsonb_typeof(render_config_snapshot) = 'object'::text)),
    CONSTRAINT chk_og_generation_run_status CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'ready'::text, 'partial_failed'::text, 'failed'::text, 'cancelled'::text]))),
    CONSTRAINT chk_og_generation_run_timestamps CHECK ((((status = 'queued'::text) AND (started_at IS NULL) AND (completed_at IS NULL)) OR ((status = 'running'::text) AND (started_at IS NOT NULL) AND (completed_at IS NULL)) OR ((status = ANY (ARRAY['ready'::text, 'partial_failed'::text, 'failed'::text, 'cancelled'::text])) AND (completed_at IS NOT NULL) AND ((started_at IS NULL) OR (completed_at >= started_at))))),
    CONSTRAINT chk_og_generation_run_trigger_kind CHECK ((NULLIF(btrim(trigger_kind), ''::text) IS NOT NULL))
);


--
-- Name: og_generation_target; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.og_generation_target (
    id uuid DEFAULT gen_random_uuid() CONSTRAINT og_generation_target_id_not_null1 NOT NULL,
    entity_type text NOT NULL,
    entity_id text NOT NULL,
    target_kind text NOT NULL,
    locale text,
    latest_generation_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_og_generation_target_entity_id CHECK ((NULLIF(btrim(entity_id), ''::text) IS NOT NULL)),
    CONSTRAINT chk_og_generation_target_entity_type CHECK ((entity_type = ANY (ARRAY['post'::text, 'page'::text, 'form'::text, 'privacy'::text, 'terms'::text, 'work'::text, 'label'::text, 'artist'::text, 'release'::text, 'series'::text, 'site'::text]))),
    CONSTRAINT chk_og_generation_target_kind CHECK ((((target_kind = 'entity'::text) AND (locale IS NULL) AND (entity_type = ANY (ARRAY['label'::text, 'release'::text, 'site'::text]))) OR ((target_kind = 'locale'::text) AND (NULLIF(btrim(locale), ''::text) IS NOT NULL) AND (entity_type = ANY (ARRAY['post'::text, 'page'::text, 'form'::text, 'series'::text, 'privacy'::text, 'terms'::text, 'work'::text, 'artist'::text])))))
);


--
-- Name: page; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.page (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug character varying(255),
    status character varying(30) DEFAULT 'PAGE_STATUS_DRAFT'::character varying NOT NULL,
    show_title boolean DEFAULT true NOT NULL,
    featured_image_file_id uuid,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid,
    document_layout jsonb DEFAULT '{"footer": "flow", "pageChrome": "flow", "contentHeight": "content"}'::jsonb NOT NULL,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    access_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT chk_page_access_policy_object CHECK ((jsonb_typeof(access_policy) = 'object'::text)),
    CONSTRAINT chk_page_document_layout CHECK (
CASE
    WHEN (jsonb_typeof(document_layout) = 'object'::text) THEN ((document_layout ?& ARRAY['contentHeight'::text, 'pageChrome'::text, 'footer'::text]) AND ((document_layout - ARRAY['contentHeight'::text, 'pageChrome'::text, 'footer'::text]) = '{}'::jsonb) AND COALESCE(((document_layout ->> 'contentHeight'::text) = ANY (ARRAY['content'::text, 'viewport'::text])), false) AND COALESCE(((document_layout ->> 'pageChrome'::text) = ANY (ARRAY['flow'::text, 'pinned'::text])), false) AND COALESCE(((document_layout ->> 'footer'::text) = ANY (ARRAY['flow'::text, 'pinned'::text])), false))
    ELSE false
END),
    CONSTRAINT chk_page_slug_route_namespace CHECK ((slug IS NULL) OR (
        slug = btrim(slug)
        AND slug <> ''
        AND left(slug, 1) <> '/'
        AND right(slug, 1) <> '/'
        AND strpos(slug, '//') = 0
        AND NOT (string_to_array(slug, '/') && ARRAY['.', '..'])
        AND lower(split_part(slug, '/', 1)) <> ALL (ARRAY[
            '_next', 'account', 'admin', 'api', 'auth', 'category',
            'changelog', 'favicon.ico', 'files', 'login', 'manifest.webmanifest',
            'my', 'onboarding', 'privacy', 'robots.txt', 's', 'sitemap',
            'sitemap.xml', 'sitemaps', 'subscribe', 'tag', 'terms',
            'unsubscribe', 'user', 'verification', 'verify'
        ])
        AND lower(slug) !~ '^tools/p5-runner(/|$)'
    )),
    CONSTRAINT chk_page_status CHECK (((status)::text = ANY (ARRAY['PAGE_STATUS_DRAFT'::text, 'PAGE_STATUS_PUBLISHED'::text])))
);


--
-- Name: page_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.page_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    incarnation_id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text,
    summary text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid
);


--
-- Name: page_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.page_version (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    page_id uuid NOT NULL,
    version integer NOT NULL,
    title text,
    contributor_member_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    summary text,
    content_html text,
    content_text text,
    content_snapshot jsonb NOT NULL,
    CONSTRAINT chk_page_version_content_snapshot CHECK (((content_snapshot IS NULL) OR ((jsonb_typeof(content_snapshot) = 'object'::text) AND (content_snapshot ?& ARRAY['schemaVersion'::text, 'sourceLocale'::text, 'title'::text, 'summary'::text, 'document'::text]) AND ((content_snapshot - ARRAY['schemaVersion'::text, 'sourceLocale'::text, 'title'::text, 'summary'::text, 'document'::text]) = '{}'::jsonb) AND ((content_snapshot -> 'schemaVersion'::text) = '1'::jsonb) AND (jsonb_typeof((content_snapshot -> 'sourceLocale'::text)) = 'string'::text) AND (btrim((content_snapshot ->> 'sourceLocale'::text)) <> ''::text) AND (jsonb_typeof((content_snapshot -> 'title'::text)) = ANY (ARRAY['string'::text, 'null'::text])) AND (jsonb_typeof((content_snapshot -> 'summary'::text)) = ANY (ARRAY['string'::text, 'null'::text])) AND (jsonb_typeof((content_snapshot -> 'document'::text)) = 'object'::text)))),
    CONSTRAINT chk_page_version_contributor_member_ids CHECK (public.uuid_array_is_sorted_unique(contributor_member_ids))
);


--
-- Name: post; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text,
    status public.post_status DEFAULT 'POST_STATUS_DRAFT'::public.post_status NOT NULL,
    comments_enabled boolean DEFAULT true NOT NULL,
    series_id uuid,
    series_order integer,
    featured_image_file_id uuid,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    map_place_id uuid,
    og_asset_id uuid,
    document_layout jsonb DEFAULT '{"footer": "flow", "pageChrome": "flow", "contentHeight": "content"}'::jsonb NOT NULL,
    scheduled_at timestamp with time zone,
    scheduled_time_zone text,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    configuration_revision uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT chk_post_document_layout CHECK (
CASE
    WHEN (jsonb_typeof(document_layout) = 'object'::text) THEN ((document_layout ?& ARRAY['contentHeight'::text, 'pageChrome'::text, 'footer'::text]) AND ((document_layout - ARRAY['contentHeight'::text, 'pageChrome'::text, 'footer'::text]) = '{}'::jsonb) AND COALESCE(((document_layout ->> 'contentHeight'::text) = ANY (ARRAY['content'::text, 'viewport'::text])), false) AND COALESCE(((document_layout ->> 'pageChrome'::text) = ANY (ARRAY['flow'::text, 'pinned'::text])), false) AND COALESCE(((document_layout ->> 'footer'::text) = ANY (ARRAY['flow'::text, 'pinned'::text])), false))
    ELSE false
END),
    CONSTRAINT chk_post_schedule CHECK ((((status = 'POST_STATUS_SCHEDULED'::public.post_status) AND (scheduled_at IS NOT NULL) AND isfinite(scheduled_at) AND (scheduled_time_zone IS NOT NULL) AND (scheduled_time_zone = btrim(scheduled_time_zone)) AND ((char_length(scheduled_time_zone) >= 1) AND (char_length(scheduled_time_zone) <= 255))) OR ((status <> 'POST_STATUS_SCHEDULED'::public.post_status) AND (scheduled_at IS NULL) AND (scheduled_time_zone IS NULL)))),
    CONSTRAINT chk_post_series_assignment CHECK ((((series_id IS NULL) AND (series_order IS NULL)) OR ((series_id IS NOT NULL) AND (series_order IS NOT NULL) AND (series_order >= 0)))),
    CONSTRAINT chk_post_slug_single_segment CHECK (((slug IS NULL) OR (strpos(slug, '/'::text) = 0)))
);


--
-- Name: post_author; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_author (
    post_id uuid NOT NULL,
    member_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: post_category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_category (
    post_id uuid NOT NULL,
    category_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: post_collaborator; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_collaborator (
    post_id uuid NOT NULL,
    member_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: post_tag; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_tag (
    post_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: post_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    summary text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid
);


--
-- Name: post_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_version (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    version integer NOT NULL,
    title text,
    summary text,
    contributor_member_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    content_snapshot jsonb NOT NULL,
    CONSTRAINT chk_post_version_content_snapshot CHECK (((content_snapshot IS NULL) OR ((jsonb_typeof(content_snapshot) = 'object'::text) AND (content_snapshot ?& ARRAY['schemaVersion'::text, 'sourceLocale'::text, 'title'::text, 'summary'::text, 'document'::text]) AND ((content_snapshot - ARRAY['schemaVersion'::text, 'sourceLocale'::text, 'title'::text, 'summary'::text, 'document'::text]) = '{}'::jsonb) AND ((content_snapshot -> 'schemaVersion'::text) = '1'::jsonb) AND (jsonb_typeof((content_snapshot -> 'sourceLocale'::text)) = 'string'::text) AND (btrim((content_snapshot ->> 'sourceLocale'::text)) <> ''::text) AND (jsonb_typeof((content_snapshot -> 'title'::text)) = ANY (ARRAY['string'::text, 'null'::text])) AND (jsonb_typeof((content_snapshot -> 'summary'::text)) = ANY (ARRAY['string'::text, 'null'::text])) AND (jsonb_typeof((content_snapshot -> 'document'::text)) = 'object'::text)))),
    CONSTRAINT chk_post_version_contributor_member_ids CHECK (public.uuid_array_is_sorted_unique(contributor_member_ids))
);


--
-- Name: privacy_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.privacy_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    version integer NOT NULL,
    title character varying(255) DEFAULT 'Privacy Policy'::character varying NOT NULL,
    content text NOT NULL,
    content_text text,
    content_hash character varying(64),
    view_hash character varying(64),
    status character varying(30) DEFAULT 'PRIVACY_STATUS_DRAFT'::character varying NOT NULL,
    effective_from timestamp with time zone,
    effective_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL
);


--
-- Name: privacy_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.privacy_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    content_html text,
    content_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: program_event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    status character varying(40) DEFAULT 'PROGRAM_EVENT_STATUS_DRAFT'::character varying NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    type_id uuid NOT NULL,
    series_id uuid,
    series_order integer,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone,
    timezone text DEFAULT 'UTC'::text NOT NULL,
    all_day boolean DEFAULT false NOT NULL,
    location_mode character varying(40) DEFAULT 'PROGRAM_EVENT_LOCATION_MODE_MAP_PLACE'::character varying NOT NULL,
    map_place_id uuid,
    ticket_url text,
    stream_url text,
    external_url text,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    title text DEFAULT ''::text NOT NULL,
    content_document_id uuid NOT NULL,
    CONSTRAINT chk_program_event_location_mode CHECK (((location_mode)::text = ANY (ARRAY[('PROGRAM_EVENT_LOCATION_MODE_MAP_PLACE'::character varying)::text, ('PROGRAM_EVENT_LOCATION_MODE_ONLINE'::character varying)::text, ('PROGRAM_EVENT_LOCATION_MODE_HYBRID'::character varying)::text, ('PROGRAM_EVENT_LOCATION_MODE_TBA'::character varying)::text]))),
    CONSTRAINT chk_program_event_location_requirements CHECK (((((location_mode)::text = 'PROGRAM_EVENT_LOCATION_MODE_MAP_PLACE'::text) AND (map_place_id IS NOT NULL)) OR (((location_mode)::text = 'PROGRAM_EVENT_LOCATION_MODE_HYBRID'::text) AND (map_place_id IS NOT NULL)) OR ((location_mode)::text = ANY (ARRAY[('PROGRAM_EVENT_LOCATION_MODE_ONLINE'::character varying)::text, ('PROGRAM_EVENT_LOCATION_MODE_TBA'::character varying)::text])))),
    CONSTRAINT chk_program_event_range CHECK (((ends_at IS NULL) OR (ends_at >= starts_at))),
    CONSTRAINT chk_program_event_slug_single_segment CHECK (((slug IS NULL) OR (strpos(slug, '/'::text) = 0))),
    CONSTRAINT chk_program_event_status CHECK (((status)::text = ANY (ARRAY[('PROGRAM_EVENT_STATUS_DRAFT'::character varying)::text, ('PROGRAM_EVENT_STATUS_PUBLISHED'::character varying)::text, ('PROGRAM_EVENT_STATUS_ARCHIVED'::character varying)::text])))
);


--
-- Name: program_event_artist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_artist (
    event_id uuid NOT NULL,
    artist_id uuid NOT NULL,
    role text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: program_event_client; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_client (
    event_id uuid NOT NULL,
    client_id uuid NOT NULL,
    role text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: program_event_credit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_credit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_id uuid NOT NULL,
    artist_id uuid,
    member_id uuid,
    display_name text,
    credit_role text,
    description text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT program_event_credit_check CHECK ((((artist_id IS NOT NULL) AND (member_id IS NULL) AND (display_name IS NULL)) OR ((artist_id IS NULL) AND (member_id IS NOT NULL) AND (display_name IS NULL)) OR ((artist_id IS NULL) AND (member_id IS NULL) AND (display_name IS NOT NULL))))
);


--
-- Name: program_event_label; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_label (
    event_id uuid NOT NULL,
    label_id uuid NOT NULL,
    role text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: program_event_media; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_media (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_id uuid NOT NULL,
    file_id uuid NOT NULL,
    role character varying(40) DEFAULT 'poster'::character varying NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    alt text,
    caption text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_program_event_media_role CHECK (((role)::text = ANY (ARRAY[('poster'::character varying)::text, ('gallery'::character varying)::text, ('lineup'::character varying)::text, ('sponsor'::character varying)::text, ('social'::character varying)::text, ('venue'::character varying)::text])))
);


--
-- Name: program_event_series; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_series (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    status character varying(40) DEFAULT 'PROGRAM_EVENT_STATUS_DRAFT'::character varying NOT NULL,
    poster_file_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    title text NOT NULL,
    summary text,
    description text,
    CONSTRAINT chk_program_event_series_slug_single_segment CHECK (((slug IS NULL) OR (strpos(slug, '/'::text) = 0))),
    CONSTRAINT chk_program_event_series_status CHECK (((status)::text = ANY (ARRAY['PROGRAM_EVENT_STATUS_DRAFT'::text, 'PROGRAM_EVENT_STATUS_PUBLISHED'::text]))),
    CONSTRAINT chk_program_event_series_title CHECK (((title = btrim(title)) AND (title <> ''::text)))
);


--
-- Name: program_event_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    summary text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: program_event_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_type (
    id uuid DEFAULT gen_random_uuid() CONSTRAINT program_event_type_id_not_null1 NOT NULL,
    slug text NOT NULL,
    status character varying(40) DEFAULT 'PROGRAM_EVENT_TYPE_STATUS_ACTIVE'::character varying NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    requires_place boolean DEFAULT false NOT NULL,
    requires_stream_url boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_program_event_type_slug_single_segment CHECK (((slug IS NULL) OR (strpos(slug, '/'::text) = 0))),
    CONSTRAINT chk_program_event_type_status CHECK (((status)::text = ANY (ARRAY[('PROGRAM_EVENT_TYPE_STATUS_ACTIVE'::character varying)::text, ('PROGRAM_EVENT_TYPE_STATUS_INACTIVE'::character varying)::text])))
);


--
-- Name: program_event_type_locale; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.program_event_type_locale (
    type_id uuid NOT NULL,
    locale text NOT NULL,
    name text NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: public_asset; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.public_asset (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_file_id uuid,
    kind text NOT NULL,
    object_key text NOT NULL,
    extension text NOT NULL,
    mime_type text NOT NULL,
    file_size bigint,
    sha256 bytea,
    disposition text DEFAULT 'inline'::text NOT NULL,
    download_filename text,
    status text DEFAULT 'allocated'::text NOT NULL,
    ready_at timestamp with time zone,
    delete_requested_at timestamp with time zone,
    deleted_at timestamp with time zone,
    failed_at timestamp with time zone,
    failure_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_public_asset_disposition CHECK (((disposition = 'inline'::text) AND (download_filename IS NULL))),
    CONSTRAINT chk_public_asset_extension CHECK ((extension ~ '^[a-z0-9][a-z0-9]{0,15}$'::text)),
    CONSTRAINT chk_public_asset_kind CHECK ((kind = ANY (ARRAY['image'::text, 'thumbnail'::text, 'waveform'::text, 'spectrogram'::text, 'mesh'::text, 'og'::text, 'avatar'::text, 'logo'::text, 'favicon'::text, 'loader'::text, 'gallery'::text, 'artwork'::text, 'poster'::text, 'map_image'::text, 'texture'::text, 'email_image'::text]))),
    CONSTRAINT chk_public_asset_kind_media_contract CHECK ((((kind = ANY (ARRAY['avatar'::text, 'thumbnail'::text])) AND (extension = 'webp'::text) AND (mime_type = 'image/webp'::text)) OR ((kind = 'spectrogram'::text) AND (extension = 'png'::text) AND (mime_type = 'image/png'::text)) OR ((kind = 'waveform'::text) AND (extension = 'json'::text) AND (mime_type = 'application/json'::text)) OR ((kind = 'mesh'::text) AND (extension = 'glb'::text) AND (mime_type = 'model/gltf-binary'::text)) OR ((kind = ANY (ARRAY['image'::text, 'og'::text, 'logo'::text, 'favicon'::text, 'loader'::text, 'gallery'::text, 'artwork'::text, 'poster'::text, 'map_image'::text, 'texture'::text, 'email_image'::text])) AND (((extension = 'jpg'::text) AND (mime_type = 'image/jpeg'::text)) OR ((extension = 'png'::text) AND (mime_type = 'image/png'::text)) OR ((extension = 'gif'::text) AND (mime_type = 'image/gif'::text)) OR ((extension = 'webp'::text) AND (mime_type = 'image/webp'::text)) OR ((extension = 'avif'::text) AND (mime_type = 'image/avif'::text)) OR ((extension = 'svg'::text) AND (mime_type = 'image/svg+xml'::text)) OR ((extension = 'ico'::text) AND (mime_type = 'image/x-icon'::text)) OR ((extension = 'ico'::text) AND (mime_type = 'image/vnd.microsoft.icon'::text)))))),
    CONSTRAINT chk_public_asset_lifecycle_timestamps CHECK ((((status <> 'delete_pending'::text) OR (delete_requested_at IS NOT NULL)) AND ((status <> 'deleted'::text) OR (deleted_at IS NOT NULL)) AND ((status <> 'failed'::text) OR (failed_at IS NOT NULL)))),
    CONSTRAINT chk_public_asset_object_key CHECK ((object_key = ((('asset/'::text || (id)::text) || '.'::text) || extension))),
    CONSTRAINT chk_public_asset_ready_metadata CHECK (((status <> 'ready'::text) OR ((file_size IS NOT NULL) AND (sha256 IS NOT NULL) AND (ready_at IS NOT NULL)))),
    CONSTRAINT chk_public_asset_sha256 CHECK (((sha256 IS NULL) OR (octet_length(sha256) = 32))),
    CONSTRAINT chk_public_asset_size CHECK (((file_size IS NULL) OR (file_size > 0))),
    CONSTRAINT chk_public_asset_status CHECK ((status = ANY (ARRAY['allocated'::text, 'ready'::text, 'delete_pending'::text, 'deleted'::text, 'failed'::text])))
);


--
-- Name: public_asset_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.public_asset_binding (
    asset_id uuid NOT NULL,
    owner_type text NOT NULL,
    owner_id text NOT NULL,
    binding_key text NOT NULL,
    source_file_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: release; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug character varying(255),
    type public.release_type NOT NULL,
    release_date date,
    catalog_number character varying(100),
    spotify_url character varying(500),
    apple_music_url character varying(500),
    bandcamp_url character varying(500),
    youtube_music_url character varying(500),
    metadata jsonb DEFAULT '{}'::jsonb,
    status character varying(30) DEFAULT 'RELEASE_STATUS_DRAFT'::character varying NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    CONSTRAINT chk_release_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0))),
    CONSTRAINT chk_release_status CHECK (((status)::text = ANY (ARRAY['RELEASE_STATUS_DRAFT'::text, 'RELEASE_STATUS_PUBLISHED'::text])))
);


--
-- Name: release_artist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_artist (
    release_id uuid NOT NULL,
    artist_id uuid NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: release_category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_category (
    release_id uuid NOT NULL,
    category_id uuid NOT NULL
);


--
-- Name: release_credit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_credit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    release_id uuid NOT NULL,
    artist_id uuid,
    member_id uuid,
    credited_name character varying(255),
    credit_role character varying(100),
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT release_credit_check CHECK (((artist_id IS NOT NULL) OR (member_id IS NOT NULL) OR (credited_name IS NOT NULL)))
);


--
-- Name: release_credit_locale; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_credit_locale (
    credit_id uuid NOT NULL,
    locale text NOT NULL,
    note text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_release_credit_locale_note CHECK ((btrim(note) <> ''::text))
);


--
-- Name: release_file; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_file (
    release_id uuid NOT NULL,
    file_id uuid NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: release_format; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_format (
    release_id uuid NOT NULL,
    format_id uuid NOT NULL,
    format_description character varying(255)
);


--
-- Name: release_genre; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_genre (
    release_id uuid NOT NULL,
    genre_id uuid NOT NULL
);


--
-- Name: release_label; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_label (
    release_id uuid NOT NULL,
    label_id uuid NOT NULL,
    catalog_number character varying(100),
    sort_order integer DEFAULT 0
);


--
-- Name: release_style; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_style (
    release_id uuid NOT NULL,
    style_id uuid NOT NULL
);


--
-- Name: release_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.release_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: series; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.series (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug character varying(255) NOT NULL,
    status character varying(30) DEFAULT 'SERIES_STATUS_DRAFT'::character varying NOT NULL,
    featured_image_file_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    content_document_id uuid NOT NULL,
    CONSTRAINT chk_series_slug CHECK ((((slug)::text = btrim((slug)::text)) AND ((slug)::text <> ''::text))),
    CONSTRAINT chk_series_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0))),
    CONSTRAINT chk_series_status CHECK (((status)::text = ANY (ARRAY['SERIES_STATUS_DRAFT'::text, 'SERIES_STATUS_PUBLISHED'::text])))
);


--
-- Name: series_manager; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.series_manager (
    series_id uuid NOT NULL,
    member_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: series_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.series_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    summary text,
    content_json jsonb,
    content_html text,
    content_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid
);


--
-- Name: share_link; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.share_link (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    token character varying(64) NOT NULL,
    entity_type character varying(50) NOT NULL,
    entity_id uuid NOT NULL,
    label character varying(100),
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    password_hash text,
    CONSTRAINT chk_share_link_expiry CHECK ((isfinite(expires_at) AND (expires_at > created_at) AND (expires_at <= (created_at + '1 year'::interval)))),
    CONSTRAINT chk_share_link_password_hash CHECK (((password_hash IS NULL) OR ((password_hash = btrim(password_hash)) AND ((char_length(password_hash) >= 1) AND (char_length(password_hash) <= 512)) AND (password_hash ~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]+={0,2}\$[A-Za-z0-9+/]+={0,2}$'::text))))
);


--
-- Name: site_setting_loader_file; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_setting_loader_file (
    site_setting_id smallint DEFAULT 1 NOT NULL,
    file_id uuid NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT site_setting_loader_file_site_setting_id_check CHECK ((site_setting_id = 1))
);


--
-- Name: site_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_settings (
    id smallint DEFAULT 1 NOT NULL,
    site_title character varying(255) DEFAULT ''::character varying NOT NULL,
    company_name character varying(255) DEFAULT ''::character varying NOT NULL,
    company_address text DEFAULT ''::text NOT NULL,
    tax_id character varying(255) DEFAULT ''::character varying NOT NULL,
    legal_email character varying(255) DEFAULT ''::character varying NOT NULL,
    support_email character varying(255) DEFAULT ''::character varying NOT NULL,
    privacy_email character varying(255) DEFAULT ''::character varying NOT NULL,
    social_links jsonb DEFAULT '{}'::jsonb NOT NULL,
    logo_email_file_id uuid,
    favicon_file_id uuid,
    primary_color character varying(7) DEFAULT '#b02d23'::character varying NOT NULL,
    default_comments_enabled boolean DEFAULT true NOT NULL,
    homepage_page_id uuid,
    menu_header_id uuid,
    menu_secondary_id uuid,
    menu_footer_id uuid,
    menu_avatar_dropdown_id uuid,
    meta_description text DEFAULT ''::text NOT NULL,
    google_analytics_id character varying(255),
    og_image_config jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    site_og_background_file_id uuid,
    privacy_og_background_file_id uuid,
    terms_og_background_file_id uuid,
    logo_light_file_id uuid,
    logo_dark_file_id uuid,
    site_og_asset_id uuid,
    default_map_theme_id uuid NOT NULL,
    CONSTRAINT site_settings_id_check CHECK ((id = 1))
);


--
-- Name: sitemap_snapshot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sitemap_snapshot (
    key text NOT NULL,
    content text NOT NULL,
    content_type text NOT NULL,
    generated_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT sitemap_snapshot_content_type_not_blank CHECK ((btrim(content_type) <> ''::text)),
    CONSTRAINT sitemap_snapshot_key_not_blank CHECK ((btrim(key) <> ''::text))
);


--
-- Name: style; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.style (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(100) NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_style_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0)))
);


--
-- Name: tag; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tag (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(50) NOT NULL,
    slug character varying(50) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_tag_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0)))
);


--
-- Name: terms_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.terms_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    version integer NOT NULL,
    title character varying(255) DEFAULT 'Terms of Service'::character varying NOT NULL,
    content text NOT NULL,
    content_text text,
    content_hash character varying(64),
    view_hash character varying(64),
    status character varying(30) DEFAULT 'TERMS_STATUS_DRAFT'::character varying NOT NULL,
    effective_from timestamp with time zone,
    effective_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL
);


--
-- Name: terms_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.terms_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    content_html text,
    content_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: track; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    release_id uuid NOT NULL,
    track_number integer NOT NULL,
    title character varying(255) NOT NULL,
    duration_seconds integer,
    audio_original_file_id uuid,
    processing_status character varying(50),
    lyrics text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    download_audience text DEFAULT 'disabled'::text NOT NULL,
    CONSTRAINT chk_track_download_audience CHECK ((download_audience = ANY (ARRAY['disabled'::text, 'public'::text, 'authenticated'::text, 'restricted'::text]))),
    CONSTRAINT chk_track_download_original CHECK (((audio_original_file_id IS NOT NULL) OR (download_audience = 'disabled'::text)))
);


--
-- Name: track_download_audience_segment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_download_audience_segment (
    track_id uuid NOT NULL,
    audience_segment_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: track_credit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_credit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid NOT NULL,
    artist_id uuid,
    member_id uuid,
    credited_name character varying(255),
    credit_role character varying(100),
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT track_credit_check CHECK (((artist_id IS NOT NULL) OR (member_id IS NOT NULL) OR (credited_name IS NOT NULL)))
);


--
-- Name: transcode_job; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transcode_job (
    event_id text NOT NULL,
    queue_name character varying(100) NOT NULL,
    entity_type character varying(100) NOT NULL,
    entity_id text NOT NULL,
    file_id text NOT NULL,
    payload bytea NOT NULL,
    status character varying(100) DEFAULT 'TRANSCODE_JOB_STATUS_QUEUED'::character varying NOT NULL,
    progress integer DEFAULT 0 NOT NULL,
    last_sequence bigint,
    last_error text,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    hls_progress integer DEFAULT 0 NOT NULL,
    spectrogram_progress integer DEFAULT 0 NOT NULL,
    last_stage text
);


--
-- Name: translation_job; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_job (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    entity_type text NOT NULL,
    entity_id text NOT NULL,
    target_locale text NOT NULL,
    source_locale text NOT NULL,
    request_artifact_digest text NOT NULL,
    operation_id text NOT NULL,
    status character varying(32) DEFAULT 'queued'::character varying NOT NULL,
    requested_by_member_id uuid NOT NULL,
    provider character varying(100),
    model character varying(255),
    provider_document_id text,
    provider_document_key text,
    provider_document_submitted_at timestamp with time zone,
    request_xliff bytea NOT NULL,
    request_manifest jsonb NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_translation_job_locale_pair CHECK ((source_locale <> target_locale)),
    CONSTRAINT chk_translation_job_provider_document_handle CHECK (((provider_document_id IS NULL) AND (provider_document_key IS NULL) AND (provider_document_submitted_at IS NULL)) OR ((provider_document_id IS NOT NULL) AND (btrim(provider_document_id) <> ''::text) AND (provider_document_key IS NOT NULL) AND (btrim(provider_document_key) <> ''::text) AND (provider_document_submitted_at IS NOT NULL) AND (provider IS NOT NULL) AND (btrim((provider)::text) <> ''::text) AND (model IS NOT NULL) AND (btrim((model)::text) <> ''::text))),
    CONSTRAINT chk_translation_job_request_artifact CHECK (((request_artifact_digest ~ '^[0-9a-f]{64}$'::text) AND (octet_length(request_xliff) > 0) AND (jsonb_typeof(request_manifest) = 'object'::text))),
    CONSTRAINT chk_translation_job_status CHECK (((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text])))
);


--
-- Name: translation_locale; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_locale (
    code text NOT NULL,
    display_name text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    is_public boolean DEFAULT true NOT NULL,
    dir text NOT NULL,
    machine_translation_allowed boolean DEFAULT true NOT NULL,
    font_profile text,
    sort_order integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_translation_locale_dir CHECK ((dir = ANY (ARRAY['ltr'::text, 'rtl'::text])))
);


--
-- Name: translation_provider_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_provider_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    type public.translation_provider_type NOT NULL,
    is_active boolean DEFAULT false NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: translation_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_settings (
    id smallint DEFAULT 1 NOT NULL,
    default_locale text DEFAULT 'en'::text NOT NULL,
    protected_terms text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_translation_settings_protected_terms CHECK (public.translation_protected_terms_are_valid(protected_terms)),
    CONSTRAINT translation_settings_id_check CHECK ((id = 1))
);


--
-- Name: upload_part; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.upload_part (
    upload_id text NOT NULL,
    part_number integer NOT NULL,
    etag text NOT NULL,
    size bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT upload_part_part_number_check CHECK ((part_number >= 1)),
    CONSTRAINT upload_part_size_check CHECK ((size >= 0))
);


--
-- Name: upload_session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.upload_session (
    upload_id text NOT NULL,
    file_id uuid NOT NULL,
    upload_type text NOT NULL,
    entity_id text,
    entity_type text,
    requested_mime text NOT NULL,
    detected_mime text,
    verified_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    total_parts integer DEFAULT 1 NOT NULL,
    chunk_size integer DEFAULT 0 NOT NULL,
    status text DEFAULT 'initiated'::text NOT NULL,
    last_activity_at timestamp with time zone DEFAULT now() NOT NULL,
    file_name text DEFAULT ''::text NOT NULL,
    file_size bigint DEFAULT 0 NOT NULL,
    file_last_modified bigint,
    slot_id text,
    attempt_id text,
    ingest_sequence bigint DEFAULT 0 NOT NULL,
    expected_current_file_id uuid,
    client_media_bundle_id uuid,
    client_media_manifest jsonb,
    CONSTRAINT chk_upload_session_client_media_pair CHECK (((client_media_bundle_id IS NULL) = (client_media_manifest IS NULL))),
    CONSTRAINT chk_upload_session_semantic_target_owner CHECK (
CASE
    WHEN (upload_type = ANY (ARRAY['UPLOAD_TYPE_GENERAL_FILE'::text, 'UPLOAD_TYPE_EDITOR_IMAGE'::text, 'UPLOAD_TYPE_EDITOR_AUDIO'::text, 'UPLOAD_TYPE_EDITOR_VIDEO'::text, 'UPLOAD_TYPE_EDITOR_ATTACHMENT'::text, 'UPLOAD_TYPE_EDITOR_MESH'::text])) THEN ((entity_id IS NULL) AND (entity_type IS NULL) AND (slot_id IS NULL) AND (expected_current_file_id IS NULL))
    WHEN (upload_type = 'UPLOAD_TYPE_TRACK_AUDIO'::text) THEN ((NULLIF(btrim(entity_id), ''::text) IS NOT NULL) AND (entity_type = 'TRANSCODE_ENTITY_TYPE_TRACK'::text) AND (slot_id IS NULL))
    ELSE ((NULLIF(btrim(entity_id), ''::text) IS NOT NULL) AND (expected_current_file_id IS NULL))
END),
    CONSTRAINT chk_upload_session_status CHECK ((status = ANY (ARRAY['initiated'::text, 'uploading'::text, 'finalizing'::text, 'failed'::text, 'aborted'::text])))
);


--
-- Name: user_cookie_consent; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_cookie_consent (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    member_id uuid NOT NULL,
    essential boolean DEFAULT true NOT NULL,
    analytics boolean DEFAULT false NOT NULL,
    consent_version integer DEFAULT 1 NOT NULL,
    source character varying(50) DEFAULT 'banner'::character varying NOT NULL,
    ip_address character varying(255),
    user_agent text,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_deletion_request; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_deletion_request (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    member_id uuid NOT NULL,
    token character varying(255) NOT NULL,
    token_expires_at timestamp with time zone NOT NULL,
    confirmed_at timestamp with time zone,
    scheduled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    notification_email text,
    notification_email_verified_at timestamp with time zone,
    notification_name text,
    lifecycle_state character varying(40) DEFAULT 'confirmation_pending'::character varying NOT NULL,
    notification_locale text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    identity_id uuid NOT NULL,
    CONSTRAINT chk_user_deletion_request_distinct_ids CHECK ((member_id <> identity_id)),
    CONSTRAINT chk_user_deletion_request_lifecycle_state CHECK (((lifecycle_state)::text = ANY (ARRAY[('confirmation_pending'::character varying)::text, ('scheduled'::character varying)::text, ('recovery_confirmation_pending'::character varying)::text, ('cancelled'::character varying)::text, ('recovered'::character varying)::text]))),
    CONSTRAINT chk_user_deletion_request_timestamps CHECK ((isfinite(created_at) AND isfinite(updated_at) AND (updated_at >= created_at)))
);


--
-- Name: user_tag; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_tag (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_tag_mapping; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_tag_mapping (
    member_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: waveform_job; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.waveform_job (
    event_id text NOT NULL,
    entity_type character varying(100) NOT NULL,
    entity_id text NOT NULL,
    file_id text NOT NULL,
    status character varying(100) NOT NULL,
    cancel_requested boolean DEFAULT false NOT NULL,
    last_error text,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    progress integer DEFAULT 0 NOT NULL,
    last_sequence bigint,
    last_stage text,
    CONSTRAINT chk_waveform_job_status CHECK (((status)::text = ANY (ARRAY[('WAVEFORM_JOB_STATUS_QUEUED'::character varying)::text, ('WAVEFORM_JOB_STATUS_COMPLETED'::character varying)::text, ('WAVEFORM_JOB_STATUS_FAILED'::character varying)::text, ('WAVEFORM_JOB_STATUS_CANCELLED'::character varying)::text])))
);


--
-- Name: work; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug character varying(255),
    type public.work_type NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    featured boolean DEFAULT false,
    status character varying(30) DEFAULT 'WORK_STATUS_DRAFT'::character varying NOT NULL,
    featured_image_file_id uuid,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    year integer NOT NULL,
    month integer NOT NULL,
    map_place_id uuid,
    until_year integer,
    until_month integer,
    is_present boolean DEFAULT false NOT NULL,
    og_asset_id uuid,
    content_document_id uuid NOT NULL,
    source_locale text DEFAULT 'en'::text NOT NULL,
    CONSTRAINT chk_work_slug_single_segment CHECK (((slug IS NULL) OR (strpos((slug)::text, '/'::text) = 0))),
    CONSTRAINT work_month_check CHECK (((month >= 1) AND (month <= 12))),
    CONSTRAINT work_period_order_check CHECK (((is_present = true) OR (until_year > year) OR ((until_year = year) AND (until_month >= month)))),
    CONSTRAINT work_period_presence_check CHECK ((((is_present = true) AND (until_year IS NULL) AND (until_month IS NULL)) OR ((is_present = false) AND (until_year IS NOT NULL) AND (until_month IS NOT NULL)))),
    CONSTRAINT work_until_month_check CHECK (((until_month IS NULL) OR ((until_month >= 1) AND (until_month <= 12)))),
    CONSTRAINT work_until_year_check CHECK (((until_year IS NULL) OR ((until_year >= 1) AND (until_year <= 9999)))),
    CONSTRAINT work_year_check CHECK (((year >= 1) AND (year <= 9999)))
);


--
-- Name: work_client; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_client (
    work_id uuid NOT NULL,
    client_id uuid NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: work_credit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_credit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    work_id uuid NOT NULL,
    group_id uuid,
    artist_id uuid,
    member_id uuid,
    name character varying(100),
    credit_role character varying(100),
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT work_credit_check CHECK ((((artist_id IS NOT NULL) AND (member_id IS NULL) AND (name IS NULL)) OR ((artist_id IS NULL) AND (member_id IS NOT NULL) AND (name IS NULL)) OR ((artist_id IS NULL) AND (member_id IS NULL) AND (name IS NOT NULL))))
);


--
-- Name: work_credit_group; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_credit_group (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    work_id uuid NOT NULL,
    name character varying(100) NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: work_translation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_translation (
    entity_id uuid NOT NULL,
    locale text NOT NULL,
    title text,
    summary text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    og_asset_id uuid
);


--
-- Name: work_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_version (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    work_id uuid NOT NULL,
    version integer NOT NULL,
    title text,
    summary text,
    contributor_member_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    content_snapshot jsonb NOT NULL,
    CONSTRAINT chk_work_version_content_snapshot CHECK (((content_snapshot IS NULL) OR ((jsonb_typeof(content_snapshot) = 'object'::text) AND (content_snapshot ?& ARRAY['schemaVersion'::text, 'sourceLocale'::text, 'title'::text, 'summary'::text, 'document'::text]) AND ((content_snapshot - ARRAY['schemaVersion'::text, 'sourceLocale'::text, 'title'::text, 'summary'::text, 'document'::text]) = '{}'::jsonb) AND ((content_snapshot -> 'schemaVersion'::text) = '1'::jsonb) AND (jsonb_typeof((content_snapshot -> 'sourceLocale'::text)) = 'string'::text) AND (btrim((content_snapshot ->> 'sourceLocale'::text)) <> ''::text) AND (jsonb_typeof((content_snapshot -> 'title'::text)) = ANY (ARRAY['string'::text, 'null'::text])) AND (jsonb_typeof((content_snapshot -> 'summary'::text)) = ANY (ARRAY['string'::text, 'null'::text])) AND (jsonb_typeof((content_snapshot -> 'document'::text)) = 'object'::text)))),
    CONSTRAINT chk_work_version_contributor_member_ids CHECK (public.uuid_array_is_sorted_unique(contributor_member_ids))
);


--
-- Name: geoip_metadata id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geoip_metadata ALTER COLUMN id SET DEFAULT nextval('public.geoip_metadata_id_seq'::regclass);


--
-- Name: account_email_change_request account_email_change_request_identity_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_email_change_request
    ADD CONSTRAINT account_email_change_request_identity_id_key UNIQUE (identity_id);


--
-- Name: account_email_change_request account_email_change_request_member_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_email_change_request
    ADD CONSTRAINT account_email_change_request_member_id_key UNIQUE (member_id);


--
-- Name: account_email_change_request account_email_change_request_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_email_change_request
    ADD CONSTRAINT account_email_change_request_pkey PRIMARY KEY (id);


--
-- Name: account_identity account_identity_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_identity
    ADD CONSTRAINT account_identity_pkey PRIMARY KEY (id);


--
-- Name: artist artist_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist
    ADD CONSTRAINT artist_content_document_id_key UNIQUE (content_document_id);


--
-- Name: artist_file artist_file_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_file
    ADD CONSTRAINT artist_file_pkey PRIMARY KEY (artist_id, file_id);


--
-- Name: artist_label artist_label_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_label
    ADD CONSTRAINT artist_label_pkey PRIMARY KEY (artist_id, label_id);


--
-- Name: artist_manager artist_manager_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_manager
    ADD CONSTRAINT artist_manager_pkey PRIMARY KEY (artist_id, member_id);


--
-- Name: artist_owner artist_owner_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_owner
    ADD CONSTRAINT artist_owner_pkey PRIMARY KEY (artist_id, member_id);


--
-- Name: artist artist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist
    ADD CONSTRAINT artist_pkey PRIMARY KEY (id);


--
-- Name: artist artist_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist
    ADD CONSTRAINT artist_slug_key UNIQUE (slug);


--
-- Name: artist_translation artist_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_translation
    ADD CONSTRAINT artist_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: audience_segment_excluded_member audience_segment_excluded_member_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment_excluded_member
    ADD CONSTRAINT audience_segment_excluded_member_pkey PRIMARY KEY (audience_segment_id, member_id);


--
-- Name: audience_segment audience_segment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment
    ADD CONSTRAINT audience_segment_pkey PRIMARY KEY (id);


--
-- Name: audience_segment_user_role audience_segment_user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment_user_role
    ADD CONSTRAINT audience_segment_user_role_pkey PRIMARY KEY (audience_segment_id, role);


--
-- Name: audience_segment_user_tag audience_segment_user_tag_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment_user_tag
    ADD CONSTRAINT audience_segment_user_tag_pkey PRIMARY KEY (audience_segment_id, user_tag_id);


--
-- Name: auth_bootstrap_state auth_bootstrap_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_bootstrap_state
    ADD CONSTRAINT auth_bootstrap_state_pkey PRIMARY KEY (key);


--
-- Name: auth_code_issuance auth_code_issuance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_code_issuance
    ADD CONSTRAINT auth_code_issuance_pkey PRIMARY KEY (token);


--
-- Name: campaign campaign_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign
    ADD CONSTRAINT campaign_content_document_id_key UNIQUE (content_document_id);


--
-- Name: email_delivery_recipient campaign_delivery_recipient_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_recipient
    ADD CONSTRAINT campaign_delivery_recipient_pkey PRIMARY KEY (id);


--
-- Name: email_delivery_run campaign_delivery_run_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run
    ADD CONSTRAINT campaign_delivery_run_pkey PRIMARY KEY (id);


--
-- Name: campaign campaign_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign
    ADD CONSTRAINT campaign_pkey PRIMARY KEY (id);


--
-- Name: campaign_translation campaign_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_translation
    ADD CONSTRAINT campaign_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: category category_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.category
    ADD CONSTRAINT category_name_key UNIQUE (name);


--
-- Name: category category_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.category
    ADD CONSTRAINT category_pkey PRIMARY KEY (id);


--
-- Name: category category_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.category
    ADD CONSTRAINT category_slug_key UNIQUE (slug);


--
-- Name: client client_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_name_key UNIQUE (name);


--
-- Name: client client_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_pkey PRIMARY KEY (id);


--
-- Name: comment comment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT comment_pkey PRIMARY KEY (id);


--
-- Name: content_block_attachment content_block_attachment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_attachment
    ADD CONSTRAINT content_block_attachment_pkey PRIMARY KEY (block_id, reference_path);


--
-- Name: content_block_attachment_download_audience_segment content_block_attachment_download_audience_segment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_attachment_download_audience_segment
    ADD CONSTRAINT content_block_attachment_download_audience_segment_pkey PRIMARY KEY (block_id, reference_path, audience_segment_id);


--
-- Name: content_block content_block_document_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block
    ADD CONSTRAINT content_block_document_id_id_key UNIQUE (document_id, id);


--
-- Name: content_block_locale content_block_locale_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_locale
    ADD CONSTRAINT content_block_locale_pkey PRIMARY KEY (block_id, locale);


--
-- Name: content_block content_block_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block
    ADD CONSTRAINT content_block_pkey PRIMARY KEY (id);


--
-- Name: content_block content_block_sibling_position_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block
    ADD CONSTRAINT content_block_sibling_position_key UNIQUE NULLS NOT DISTINCT (document_id, parent_block_id, container_slot, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: content_document content_document_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_document
    ADD CONSTRAINT content_document_pkey PRIMARY KEY (id);


--
-- Name: country country_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.country
    ADD CONSTRAINT country_pkey PRIMARY KEY (code);


--
-- Name: domain_audit domain_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_audit
    ADD CONSTRAINT domain_audit_pkey PRIMARY KEY (audit_id);


--
-- Name: email_delivery_run_target_excluded_member email_delivery_run_target_excluded_member_identity_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_excluded_member
    ADD CONSTRAINT email_delivery_run_target_excluded_member_identity_key UNIQUE (run_id, identity_id);


--
-- Name: email_delivery_run_target_excluded_member email_delivery_run_target_excluded_member_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_excluded_member
    ADD CONSTRAINT email_delivery_run_target_excluded_member_pkey PRIMARY KEY (run_id, member_id);


--
-- Name: email_delivery_run_target_user_role email_delivery_run_target_user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_user_role
    ADD CONSTRAINT email_delivery_run_target_user_role_pkey PRIMARY KEY (run_id, role);


--
-- Name: email_delivery_run_target_user_tag email_delivery_run_target_user_tag_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_user_tag
    ADD CONSTRAINT email_delivery_run_target_user_tag_pkey PRIMARY KEY (run_id, user_tag_id);


--
-- Name: email_layout email_layout_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layout
    ADD CONSTRAINT email_layout_key_key UNIQUE (key);


--
-- Name: email_layout email_layout_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layout
    ADD CONSTRAINT email_layout_pkey PRIMARY KEY (id);


--
-- Name: email_layout email_layout_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layout
    ADD CONSTRAINT email_layout_content_document_id_key UNIQUE (content_document_id);


--
-- Name: email_layout_translation email_layout_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layout_translation
    ADD CONSTRAINT email_layout_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: email_suppression email_suppression_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_suppression
    ADD CONSTRAINT email_suppression_pkey PRIMARY KEY (id);


--
-- Name: email_template email_template_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template
    ADD CONSTRAINT email_template_content_document_id_key UNIQUE (content_document_id);


--
-- Name: email_template email_template_event_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template
    ADD CONSTRAINT email_template_event_key_key UNIQUE (event_key);


--
-- Name: email_template email_template_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template
    ADD CONSTRAINT email_template_key_key UNIQUE (key);


--
-- Name: email_template email_template_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template
    ADD CONSTRAINT email_template_pkey PRIMARY KEY (id);


--
-- Name: email_template_translation email_template_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template_translation
    ADD CONSTRAINT email_template_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: file_derivative file_derivative_file_id_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_derivative
    ADD CONSTRAINT file_derivative_file_id_type_key UNIQUE (file_id, type);


--
-- Name: file_derivative file_derivative_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_derivative
    ADD CONSTRAINT file_derivative_pkey PRIMARY KEY (id);


-- Name: file_folder file_folder_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_folder
    ADD CONSTRAINT file_folder_pkey PRIMARY KEY (id);


--
-- Name: file_ingest_binding file_ingest_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_ingest_binding
    ADD CONSTRAINT file_ingest_binding_pkey PRIMARY KEY (file_id);


--
-- Name: file file_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file
    ADD CONSTRAINT file_pkey PRIMARY KEY (id);


--
-- Name: form form_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form
    ADD CONSTRAINT form_pkey PRIMARY KEY (id);


--
-- Name: form form_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form
    ADD CONSTRAINT form_content_document_id_key UNIQUE (content_document_id);


--
-- Name: form form_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form
    ADD CONSTRAINT form_slug_key UNIQUE (slug);


--
-- Name: form_submission form_submission_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_submission
    ADD CONSTRAINT form_submission_pkey PRIMARY KEY (id);


--
-- Name: form_translation form_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_translation
    ADD CONSTRAINT form_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: format format_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.format
    ADD CONSTRAINT format_name_key UNIQUE (name);


--
-- Name: format format_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.format
    ADD CONSTRAINT format_pkey PRIMARY KEY (id);


--
-- Name: format format_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.format
    ADD CONSTRAINT format_slug_key UNIQUE (slug);


--
-- Name: genre genre_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genre
    ADD CONSTRAINT genre_name_key UNIQUE (name);


--
-- Name: genre genre_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genre
    ADD CONSTRAINT genre_pkey PRIMARY KEY (id);


--
-- Name: genre genre_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genre
    ADD CONSTRAINT genre_slug_key UNIQUE (slug);


--
-- Name: geoip_location geoip_location_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geoip_location
    ADD CONSTRAINT geoip_location_pkey PRIMARY KEY (geoname_id);


--
-- Name: geoip_metadata geoip_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geoip_metadata
    ADD CONSTRAINT geoip_metadata_pkey PRIMARY KEY (id);


--
-- Name: geoip_network geoip_network_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geoip_network
    ADD CONSTRAINT geoip_network_pkey PRIMARY KEY (network);


--
-- Name: label label_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_content_document_id_key UNIQUE (content_document_id);


--
-- Name: label_manager label_manager_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_manager
    ADD CONSTRAINT label_manager_pkey PRIMARY KEY (label_id, member_id);


--
-- Name: label_owner label_owner_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_owner
    ADD CONSTRAINT label_owner_pkey PRIMARY KEY (label_id, member_id);


--
-- Name: label label_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_pkey PRIMARY KEY (id);


--
-- Name: label label_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_slug_key UNIQUE (slug);


--
-- Name: label_translation label_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_translation
    ADD CONSTRAINT label_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: mail_adapter mail_adapter_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mail_adapter
    ADD CONSTRAINT mail_adapter_pkey PRIMARY KEY (id);


--
-- Name: map_place map_place_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.map_place
    ADD CONSTRAINT map_place_pkey PRIMARY KEY (id);


--
-- Name: map_theme map_theme_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.map_theme
    ADD CONSTRAINT map_theme_pkey PRIMARY KEY (id);


--
-- Name: media_generation media_generation_object_prefix_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_generation
    ADD CONSTRAINT media_generation_object_prefix_key UNIQUE (object_prefix);


--
-- Name: media_generation media_generation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_generation
    ADD CONSTRAINT media_generation_pkey PRIMARY KEY (id);


--
-- Name: member member_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member
    ADD CONSTRAINT member_pkey PRIMARY KEY (id);


--
-- Name: member_personal_access_token member_personal_access_token_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member_personal_access_token
    ADD CONSTRAINT member_personal_access_token_pkey PRIMARY KEY (selector);


--
-- Name: menu menu_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu
    ADD CONSTRAINT menu_name_key UNIQUE (name);


--
-- Name: menu menu_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu
    ADD CONSTRAINT menu_pkey PRIMARY KEY (id);


--
-- Name: menu menu_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu
    ADD CONSTRAINT menu_content_document_id_key UNIQUE (content_document_id);


--
-- Name: menu_translation menu_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_translation
    ADD CONSTRAINT menu_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: mesh_optimization_candidate mesh_optimization_candidate_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesh_optimization_candidate
    ADD CONSTRAINT mesh_optimization_candidate_pkey PRIMARY KEY (id);


--
-- Name: metadata_ai_job metadata_ai_job_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_ai_job
    ADD CONSTRAINT metadata_ai_job_pkey PRIMARY KEY (id);


--
-- Name: newsletter_subscription newsletter_subscription_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.newsletter_subscription
    ADD CONSTRAINT newsletter_subscription_pkey PRIMARY KEY (identity_id);


--
-- Name: og_generation og_generation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation
    ADD CONSTRAINT og_generation_pkey PRIMARY KEY (id);


--
-- Name: og_generation_run og_generation_run_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation_run
    ADD CONSTRAINT og_generation_run_pkey PRIMARY KEY (id);


--
-- Name: og_generation_target og_generation_target_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation_target
    ADD CONSTRAINT og_generation_target_pkey PRIMARY KEY (id);


--
-- Name: page page_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page
    ADD CONSTRAINT page_content_document_id_key UNIQUE (content_document_id);


--
-- Name: page page_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page
    ADD CONSTRAINT page_pkey PRIMARY KEY (id);


--
-- Name: page page_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page
    ADD CONSTRAINT page_slug_key UNIQUE (slug);


--
-- Name: page_translation page_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_translation
    ADD CONSTRAINT page_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: page_version page_version_page_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_version
    ADD CONSTRAINT page_version_page_id_version_key UNIQUE (page_id, version);


--
-- Name: page_version page_version_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_version
    ADD CONSTRAINT page_version_pkey PRIMARY KEY (id);


--
-- Name: post_author post_author_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_author
    ADD CONSTRAINT post_author_pkey PRIMARY KEY (post_id, member_id);


--
-- Name: post_category post_category_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_category
    ADD CONSTRAINT post_category_pkey PRIMARY KEY (post_id, category_id);


--
-- Name: post_collaborator post_collaborator_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_collaborator
    ADD CONSTRAINT post_collaborator_pkey PRIMARY KEY (post_id, member_id);


--
-- Name: post post_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_content_document_id_key UNIQUE (content_document_id);


--
-- Name: post post_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_pkey PRIMARY KEY (id);


--
-- Name: post post_series_order_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_series_order_key UNIQUE (series_id, series_order) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: post post_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_slug_key UNIQUE (slug);


--
-- Name: post_tag post_tag_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_tag
    ADD CONSTRAINT post_tag_pkey PRIMARY KEY (post_id, tag_id);


--
-- Name: post_translation post_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_translation
    ADD CONSTRAINT post_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: post_version post_version_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_version
    ADD CONSTRAINT post_version_pkey PRIMARY KEY (id);


--
-- Name: post_version post_version_post_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_version
    ADD CONSTRAINT post_version_post_id_version_key UNIQUE (post_id, version);


--
-- Name: privacy_history privacy_history_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.privacy_history
    ADD CONSTRAINT privacy_history_content_document_id_key UNIQUE (content_document_id);


--
-- Name: privacy_history privacy_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.privacy_history
    ADD CONSTRAINT privacy_history_pkey PRIMARY KEY (id);


--
-- Name: privacy_history privacy_history_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.privacy_history
    ADD CONSTRAINT privacy_history_version_key UNIQUE (version);


--
-- Name: privacy_translation privacy_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.privacy_translation
    ADD CONSTRAINT privacy_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: program_event_artist program_event_artist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_artist
    ADD CONSTRAINT program_event_artist_pkey PRIMARY KEY (event_id, artist_id);


--
-- Name: program_event_client program_event_client_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_client
    ADD CONSTRAINT program_event_client_pkey PRIMARY KEY (event_id, client_id);


--
-- Name: program_event program_event_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event
    ADD CONSTRAINT program_event_content_document_id_key UNIQUE (content_document_id);


--
-- Name: program_event_credit program_event_credit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_credit
    ADD CONSTRAINT program_event_credit_pkey PRIMARY KEY (id);


--
-- Name: program_event_label program_event_label_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_label
    ADD CONSTRAINT program_event_label_pkey PRIMARY KEY (event_id, label_id);


--
-- Name: program_event_media program_event_media_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_media
    ADD CONSTRAINT program_event_media_pkey PRIMARY KEY (id);


--
-- Name: program_event program_event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event
    ADD CONSTRAINT program_event_pkey PRIMARY KEY (id);


--
-- Name: program_event_series program_event_series_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_series
    ADD CONSTRAINT program_event_series_pkey PRIMARY KEY (id);


--
-- Name: program_event_translation program_event_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_translation
    ADD CONSTRAINT program_event_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: program_event_type_locale program_event_type_locale_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_type_locale
    ADD CONSTRAINT program_event_type_locale_pkey PRIMARY KEY (type_id, locale);


--
-- Name: program_event_type program_event_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_type
    ADD CONSTRAINT program_event_type_pkey PRIMARY KEY (id);


--
-- Name: program_event_type program_event_type_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_type
    ADD CONSTRAINT program_event_type_slug_key UNIQUE (slug);


--
-- Name: public_asset_binding public_asset_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_asset_binding
    ADD CONSTRAINT public_asset_binding_pkey PRIMARY KEY (owner_type, owner_id, binding_key);


--
-- Name: public_asset public_asset_object_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_asset
    ADD CONSTRAINT public_asset_object_key_key UNIQUE (object_key);


--
-- Name: public_asset public_asset_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_asset
    ADD CONSTRAINT public_asset_pkey PRIMARY KEY (id);


--
-- Name: release_artist release_artist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_artist
    ADD CONSTRAINT release_artist_pkey PRIMARY KEY (release_id, artist_id);


--
-- Name: release_category release_category_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_category
    ADD CONSTRAINT release_category_pkey PRIMARY KEY (release_id, category_id);


--
-- Name: release release_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release
    ADD CONSTRAINT release_content_document_id_key UNIQUE (content_document_id);


--
-- Name: release_credit_locale release_credit_locale_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_credit_locale
    ADD CONSTRAINT release_credit_locale_pkey PRIMARY KEY (credit_id, locale);


--
-- Name: release_credit release_credit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_credit
    ADD CONSTRAINT release_credit_pkey PRIMARY KEY (id);


--
-- Name: release_file release_file_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_file
    ADD CONSTRAINT release_file_pkey PRIMARY KEY (release_id, file_id);


--
-- Name: release_format release_format_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_format
    ADD CONSTRAINT release_format_pkey PRIMARY KEY (release_id, format_id);


--
-- Name: release_genre release_genre_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_genre
    ADD CONSTRAINT release_genre_pkey PRIMARY KEY (release_id, genre_id);


--
-- Name: release_label release_label_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_label
    ADD CONSTRAINT release_label_pkey PRIMARY KEY (release_id, label_id);


--
-- Name: release release_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release
    ADD CONSTRAINT release_pkey PRIMARY KEY (id);


--
-- Name: release release_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release
    ADD CONSTRAINT release_slug_key UNIQUE (slug);


--
-- Name: release_style release_style_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_style
    ADD CONSTRAINT release_style_pkey PRIMARY KEY (release_id, style_id);


--
-- Name: release_translation release_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_translation
    ADD CONSTRAINT release_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: security_access security_access_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_access
    ADD CONSTRAINT security_access_pkey PRIMARY KEY (access_id);


--
-- Name: series_manager series_manager_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series_manager
    ADD CONSTRAINT series_manager_pkey PRIMARY KEY (series_id, member_id);


--
-- Name: series series_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_pkey PRIMARY KEY (id);


--
-- Name: series series_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_content_document_id_key UNIQUE (content_document_id);


--
-- Name: series series_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_slug_key UNIQUE (slug);


--
-- Name: series_translation series_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series_translation
    ADD CONSTRAINT series_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: share_link share_link_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.share_link
    ADD CONSTRAINT share_link_pkey PRIMARY KEY (id);


--
-- Name: share_link share_link_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.share_link
    ADD CONSTRAINT share_link_token_key UNIQUE (token);


--
-- Name: site_setting_loader_file site_setting_loader_file_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_setting_loader_file
    ADD CONSTRAINT site_setting_loader_file_pkey PRIMARY KEY (site_setting_id, file_id);


--
-- Name: site_settings site_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_pkey PRIMARY KEY (id);


--
-- Name: sitemap_snapshot sitemap_snapshot_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sitemap_snapshot
    ADD CONSTRAINT sitemap_snapshot_pkey PRIMARY KEY (key);


--
-- Name: style style_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.style
    ADD CONSTRAINT style_name_key UNIQUE (name);


--
-- Name: style style_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.style
    ADD CONSTRAINT style_pkey PRIMARY KEY (id);


--
-- Name: style style_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.style
    ADD CONSTRAINT style_slug_key UNIQUE (slug);


--
-- Name: tag tag_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tag
    ADD CONSTRAINT tag_name_key UNIQUE (name);


--
-- Name: tag tag_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tag
    ADD CONSTRAINT tag_pkey PRIMARY KEY (id);


--
-- Name: tag tag_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tag
    ADD CONSTRAINT tag_slug_key UNIQUE (slug);


--
-- Name: terms_history terms_history_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_history
    ADD CONSTRAINT terms_history_content_document_id_key UNIQUE (content_document_id);


--
-- Name: terms_history terms_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_history
    ADD CONSTRAINT terms_history_pkey PRIMARY KEY (id);


--
-- Name: terms_history terms_history_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_history
    ADD CONSTRAINT terms_history_version_key UNIQUE (version);


--
-- Name: terms_translation terms_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_translation
    ADD CONSTRAINT terms_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: track_credit track_credit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_credit
    ADD CONSTRAINT track_credit_pkey PRIMARY KEY (id);


--
-- Name: track track_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track
    ADD CONSTRAINT track_pkey PRIMARY KEY (id);


--
-- Name: track_download_audience_segment track_download_audience_segment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_download_audience_segment
    ADD CONSTRAINT track_download_audience_segment_pkey PRIMARY KEY (track_id, audience_segment_id);


--
-- Name: track track_release_id_track_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track
    ADD CONSTRAINT track_release_id_track_number_key UNIQUE (release_id, track_number);


--
-- Name: transcode_job transcode_job_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transcode_job
    ADD CONSTRAINT transcode_job_pkey PRIMARY KEY (event_id);


--
-- Name: translation_job translation_job_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_job
    ADD CONSTRAINT translation_job_pkey PRIMARY KEY (id);


--
-- Name: translation_locale translation_locale_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_locale
    ADD CONSTRAINT translation_locale_pkey PRIMARY KEY (code);


--
-- Name: translation_provider_config translation_provider_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_provider_config
    ADD CONSTRAINT translation_provider_config_pkey PRIMARY KEY (id);


--
-- Name: translation_settings translation_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_settings
    ADD CONSTRAINT translation_settings_pkey PRIMARY KEY (id);


--
-- Name: upload_part upload_part_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.upload_part
    ADD CONSTRAINT upload_part_pkey PRIMARY KEY (upload_id, part_number);


--
-- Name: upload_session upload_session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.upload_session
    ADD CONSTRAINT upload_session_pkey PRIMARY KEY (upload_id);


--
-- Name: file_folder uq_file_folder_parent_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_folder
    ADD CONSTRAINT uq_file_folder_parent_name UNIQUE NULLS NOT DISTINCT (parent_id, name);


--
-- Name: mesh_optimization_candidate uq_mesh_optimization_candidate_cache_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesh_optimization_candidate
    ADD CONSTRAINT uq_mesh_optimization_candidate_cache_key UNIQUE (cache_key);


--
-- Name: mesh_optimization_candidate uq_mesh_optimization_candidate_output_object_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesh_optimization_candidate
    ADD CONSTRAINT uq_mesh_optimization_candidate_output_object_id UNIQUE (output_object_id);


--
-- Name: og_generation uq_og_generation_request_sequence; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation
    ADD CONSTRAINT uq_og_generation_request_sequence UNIQUE (request_sequence);


--
-- Name: og_generation uq_og_generation_target_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation
    ADD CONSTRAINT uq_og_generation_target_id UNIQUE (target_id, id);


--
-- Name: og_generation_target uq_og_generation_target_identity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation_target
    ADD CONSTRAINT uq_og_generation_target_identity UNIQUE NULLS NOT DISTINCT (entity_type, entity_id, locale);


--
-- Name: translation_job uq_translation_job_operation; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_job
    ADD CONSTRAINT uq_translation_job_operation UNIQUE (entity_type, entity_id, target_locale, operation_id);


--
-- Name: user_cookie_consent user_cookie_consent_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_cookie_consent
    ADD CONSTRAINT user_cookie_consent_pkey PRIMARY KEY (id);


--
-- Name: user_deletion_request user_deletion_request_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_deletion_request
    ADD CONSTRAINT user_deletion_request_pkey PRIMARY KEY (id);


--
-- Name: user_deletion_request user_deletion_request_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_deletion_request
    ADD CONSTRAINT user_deletion_request_token_key UNIQUE (token);


--
-- Name: user_tag_mapping user_tag_mapping_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tag_mapping
    ADD CONSTRAINT user_tag_mapping_pkey PRIMARY KEY (member_id, tag_id);


--
-- Name: user_tag user_tag_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tag
    ADD CONSTRAINT user_tag_name_key UNIQUE (name);


--
-- Name: user_tag user_tag_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tag
    ADD CONSTRAINT user_tag_pkey PRIMARY KEY (id);


--
-- Name: waveform_job waveform_job_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.waveform_job
    ADD CONSTRAINT waveform_job_pkey PRIMARY KEY (event_id);


--
-- Name: work_client work_client_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_client
    ADD CONSTRAINT work_client_pkey PRIMARY KEY (work_id, client_id);


--
-- Name: work work_content_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work
    ADD CONSTRAINT work_content_document_id_key UNIQUE (content_document_id);


--
-- Name: work_credit_group work_credit_group_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_credit_group
    ADD CONSTRAINT work_credit_group_pkey PRIMARY KEY (id);


--
-- Name: work_credit work_credit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_credit
    ADD CONSTRAINT work_credit_pkey PRIMARY KEY (id);


--
-- Name: work work_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work
    ADD CONSTRAINT work_pkey PRIMARY KEY (id);


--
-- Name: work work_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work
    ADD CONSTRAINT work_slug_key UNIQUE (slug);


--
-- Name: work_translation work_translation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_translation
    ADD CONSTRAINT work_translation_pkey PRIMARY KEY (entity_id, locale);


--
-- Name: work_version work_version_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_version
    ADD CONSTRAINT work_version_pkey PRIMARY KEY (id);


--
-- Name: work_version work_version_work_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_version
    ADD CONSTRAINT work_version_work_id_version_key UNIQUE (work_id, version);


--
-- Name: auth_code_issuance_client_ip_issued_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_code_issuance_client_ip_issued_at_idx ON public.auth_code_issuance USING btree (client_ip_digest, issued_at);


--
-- Name: auth_code_issuance_expires_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_code_issuance_expires_at_idx ON public.auth_code_issuance USING btree (expires_at);


--
-- Name: auth_code_issuance_issued_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_code_issuance_issued_at_idx ON public.auth_code_issuance USING btree (issued_at);


--
-- Name: auth_code_issuance_recipient_issued_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_code_issuance_recipient_issued_at_idx ON public.auth_code_issuance USING btree (recipient_digest, issued_at DESC);


--
-- Name: auth_code_issuance_subject_issued_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_code_issuance_subject_issued_at_idx ON public.auth_code_issuance USING btree (subject_digest, issued_at);


--
-- Name: domain_audit_action_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX domain_audit_action_idx ON public.domain_audit USING btree (action, occurred_at DESC, audit_id DESC);


--
-- Name: domain_audit_actor_member_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX domain_audit_actor_member_idx ON public.domain_audit USING btree (actor_member_id, occurred_at DESC, audit_id DESC) WHERE (actor_member_id IS NOT NULL);


--
-- Name: domain_audit_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX domain_audit_occurred_at_idx ON public.domain_audit USING btree (occurred_at DESC, audit_id DESC);


--
-- Name: domain_audit_request_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX domain_audit_request_idx ON public.domain_audit USING btree (request_id, occurred_at DESC, audit_id DESC) WHERE (request_id IS NOT NULL);


--
-- Name: domain_audit_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX domain_audit_target_idx ON public.domain_audit USING btree (target_type, target_id, occurred_at DESC, audit_id DESC);


--
-- Name: domain_audit_trace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX domain_audit_trace_idx ON public.domain_audit USING btree (trace_id, occurred_at DESC, audit_id DESC) WHERE (trace_id IS NOT NULL);


--
-- Name: idx_account_email_change_request_reconcile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_email_change_request_reconcile ON public.account_email_change_request USING btree (created_at, id);


--
-- Name: idx_artist_file_artist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artist_file_artist ON public.artist_file USING btree (artist_id);


--
-- Name: idx_artist_file_sort; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artist_file_sort ON public.artist_file USING btree (artist_id, sort_order);


--
-- Name: idx_artist_label_artist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artist_label_artist ON public.artist_label USING btree (artist_id);


--
-- Name: idx_artist_label_label; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artist_label_label ON public.artist_label USING btree (label_id);


--
-- Name: idx_artist_manager_member_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artist_manager_member_id ON public.artist_manager USING btree (member_id);


--
-- Name: idx_artist_owner_member_artist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artist_owner_member_artist ON public.artist_owner USING btree (member_id, artist_id);


--
-- Name: idx_artist_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artist_slug ON public.artist USING btree (slug);


--
-- Name: idx_artist_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artist_status ON public.artist USING btree (status);


--
-- Name: idx_audience_segment_archived_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audience_segment_archived_at ON public.audience_segment USING btree (archived_at) WHERE (archived_at IS NOT NULL);


--
-- Name: idx_audience_segment_excluded_member_member_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audience_segment_excluded_member_member_segment ON public.audience_segment_excluded_member USING btree (member_id, audience_segment_id);


--
-- Name: idx_audience_segment_user_role_role_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audience_segment_user_role_role_segment ON public.audience_segment_user_role USING btree (role, audience_segment_id);


--
-- Name: idx_audience_segment_user_tag_tag_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audience_segment_user_tag_tag_segment ON public.audience_segment_user_tag USING btree (user_tag_id, audience_segment_id);


--
-- Name: idx_campaign_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaign_created_at ON public.campaign USING btree (created_at DESC);


--
-- Name: idx_campaign_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaign_scheduled_at ON public.campaign USING btree (scheduled_at) WHERE (scheduled_at IS NOT NULL);


--
-- Name: idx_campaign_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaign_status ON public.campaign USING btree (status);


--
-- Name: idx_category_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_category_slug ON public.category USING btree (slug);


--
-- Name: idx_client_logo_dark_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_client_logo_dark_file ON public.client USING btree (logo_dark_file_id) WHERE (logo_dark_file_id IS NOT NULL);


--
-- Name: idx_client_logo_light_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_client_logo_light_file ON public.client USING btree (logo_light_file_id) WHERE (logo_light_file_id IS NOT NULL);


--
-- Name: idx_comment_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_comment_parent_id ON public.comment USING btree (parent_id);


--
-- Name: idx_comment_post_created_deleted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_comment_post_created_deleted ON public.comment USING btree (post_id, created_at, is_deleted);


--
-- Name: idx_comment_post_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_comment_post_id ON public.comment USING btree (post_id);


--
-- Name: idx_content_block_attachment_active_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_block_attachment_active_file ON public.content_block_attachment USING btree (file_id, block_id) WHERE (selector_kind = 'active'::text);


--
-- Name: idx_content_block_attachment_missing_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_block_attachment_missing_kind ON public.content_block_attachment USING btree (missing_kind, block_id) WHERE (selector_kind = 'missing'::text);


--
-- Name: idx_content_block_attachment_download_segment_reverse; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_block_attachment_download_segment_reverse ON public.content_block_attachment_download_audience_segment USING btree (audience_segment_id, block_id, reference_path);


--
-- Name: idx_content_block_document_tree; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_block_document_tree ON public.content_block USING btree (document_id, parent_block_id, container_slot, "position");


--
-- Name: idx_content_block_locale_locale_block; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_block_locale_locale_block ON public.content_block_locale USING btree (locale, block_id);


--
-- Name: idx_country_code_pgroonga; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_country_code_pgroonga ON public.country USING pgroonga (code);


--
-- Name: idx_country_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_country_name ON public.country USING btree (name);


--
-- Name: idx_country_name_pgroonga; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_country_name_pgroonga ON public.country USING pgroonga (name);


--
-- Name: idx_country_native_name_pgroonga; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_country_native_name_pgroonga ON public.country USING pgroonga (native_name) WHERE (native_name IS NOT NULL);


--
-- Name: idx_email_delivery_recipient_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_recipient_identity ON public.email_delivery_recipient USING btree (identity_id) WHERE (identity_id IS NOT NULL);


--
-- Name: idx_email_delivery_recipient_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_recipient_member ON public.email_delivery_recipient USING btree (member_id);


--
-- Name: idx_email_delivery_recipient_provider_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_recipient_provider_message_id ON public.email_delivery_recipient USING btree (provider_message_id) WHERE (provider_message_id IS NOT NULL);


--
-- Name: idx_email_delivery_recipient_run_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_email_delivery_recipient_run_email ON public.email_delivery_recipient USING btree (run_id, normalized_recipient_email);


--
-- Name: idx_email_delivery_recipient_run_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_recipient_run_status ON public.email_delivery_recipient USING btree (run_id, status);


--
-- Name: idx_email_delivery_recipient_run_status_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_recipient_run_status_id ON public.email_delivery_recipient USING btree (run_id, status, id);


--
-- Name: idx_email_delivery_run_active_campaign; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_email_delivery_run_active_campaign ON public.email_delivery_run USING btree (campaign_id) WHERE (((run_kind)::text = 'campaign'::text) AND (campaign_id IS NOT NULL) AND ((status)::text = ANY (ARRAY[('scheduled'::character varying)::text, ('sending'::character varying)::text])));


--
-- Name: idx_email_delivery_run_audience_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_audience_segment ON public.email_delivery_run USING btree (audience_segment_id) WHERE (audience_segment_id IS NOT NULL);


--
-- Name: idx_email_delivery_run_campaign; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_campaign ON public.email_delivery_run USING btree (campaign_id, created_at DESC) WHERE (campaign_id IS NOT NULL);


--
-- Name: idx_email_delivery_run_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_due ON public.email_delivery_run USING btree (scheduled_at, id) WHERE ((status)::text = 'scheduled'::text);


--
-- Name: idx_email_delivery_run_privacy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_privacy ON public.email_delivery_run USING btree (privacy_id) WHERE (privacy_id IS NOT NULL);


--
-- Name: idx_email_delivery_run_source_layout; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_source_layout ON public.email_delivery_run USING btree (source_layout_id) WHERE (source_layout_id IS NOT NULL);


--
-- Name: idx_email_delivery_run_source_template; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_source_template ON public.email_delivery_run USING btree (source_template_id) WHERE (source_template_id IS NOT NULL);


--
-- Name: idx_email_delivery_run_target_excluded_member_identity_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_target_excluded_member_identity_run ON public.email_delivery_run_target_excluded_member USING btree (identity_id, run_id);


--
-- Name: idx_email_delivery_run_target_excluded_member_member_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_target_excluded_member_member_run ON public.email_delivery_run_target_excluded_member USING btree (member_id, run_id);


--
-- Name: idx_email_delivery_run_target_user_role_role_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_target_user_role_role_run ON public.email_delivery_run_target_user_role USING btree (role, run_id);


--
-- Name: idx_email_delivery_run_target_user_tag_tag_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_target_user_tag_tag_run ON public.email_delivery_run_target_user_tag USING btree (user_tag_id, run_id);


--
-- Name: idx_email_delivery_run_terms; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_run_terms ON public.email_delivery_run USING btree (terms_id) WHERE (terms_id IS NOT NULL);


--
-- Name: idx_email_layout_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_layout_key ON public.email_layout USING btree (key);


--
-- Name: idx_email_suppression_active_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_email_suppression_active_email ON public.email_suppression USING btree (lower((email)::text)) WHERE (released_at IS NULL);


--
-- Name: idx_email_suppression_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_suppression_email ON public.email_suppression USING btree (lower((email)::text), created_at DESC);


--
-- Name: idx_email_template_event_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_template_event_key ON public.email_template USING btree (event_key) WHERE (event_key IS NOT NULL);


--
-- Name: idx_email_template_is_system; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_template_is_system ON public.email_template USING btree (is_system);


--
-- Name: idx_email_template_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_template_key ON public.email_template USING btree (key);


--
-- Name: idx_file_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_created_at ON public.file USING btree (created_at DESC);


--
-- Name: idx_file_delete_requested; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_delete_requested ON public.file USING btree (delete_requested_at, id) WHERE (delete_requested_at IS NOT NULL);


--
-- Name: idx_file_derivative_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_derivative_asset ON public.file_derivative USING btree (asset_id) WHERE (asset_id IS NOT NULL);


--
-- Name: idx_file_derivative_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_derivative_file_id ON public.file_derivative USING btree (file_id);


--
-- Name: idx_file_derivative_media_generation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_derivative_media_generation ON public.file_derivative USING btree (media_generation_id) WHERE (media_generation_id IS NOT NULL);


-- Name: idx_file_folder_catalog; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_folder_catalog ON public.file USING btree (folder_id, created_at DESC, id) WHERE (delete_requested_at IS NULL);


--
-- Name: idx_file_folder_created_by_member_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_folder_created_by_member_id ON public.file_folder USING btree (created_by_member_id) WHERE (created_by_member_id IS NOT NULL);


--
-- Name: idx_file_folder_name_search; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_folder_name_search ON public.file_folder USING pgroonga (name);


--
-- Name: idx_file_folder_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_folder_parent_id ON public.file_folder USING btree (parent_id, name, id);


--
-- Name: idx_file_ingest_binding_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_ingest_binding_owner ON public.file_ingest_binding USING btree (entity_type, entity_id, upload_type);


--
-- Name: idx_file_name_search; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_name_search ON public.file USING pgroonga ((((file_name || '.'::text) || extension))) WHERE (delete_requested_at IS NULL);


--
-- Name: idx_file_uploaded_by_member_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_uploaded_by_member_id ON public.file USING btree (uploaded_by_member_id) WHERE (uploaded_by_member_id IS NOT NULL);


--
-- Name: idx_form_featured_image; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_form_featured_image ON public.form USING btree (featured_image_file_id) WHERE (featured_image_file_id IS NOT NULL);


--
-- Name: idx_form_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_form_slug ON public.form USING btree (slug);


--
-- Name: idx_form_submission_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_form_submission_created_at ON public.form_submission USING btree (created_at);


--
-- Name: idx_form_submission_form_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_form_submission_form_id ON public.form_submission USING btree (form_id);


--
-- Name: idx_genre_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_genre_slug ON public.genre USING btree (slug);


--
-- Name: idx_geoip_location_country; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geoip_location_country ON public.geoip_location USING btree (country_iso_code);


--
-- Name: idx_geoip_network_geoname; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geoip_network_geoname ON public.geoip_network USING btree (geoname_id);


--
-- Name: idx_geoip_network_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geoip_network_location ON public.geoip_network USING gist (location);


--
-- Name: idx_geoip_network_network; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geoip_network_network ON public.geoip_network USING gist (network);


--
-- Name: idx_label_logo_dark_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_label_logo_dark_file ON public.label USING btree (logo_dark_file_id) WHERE (logo_dark_file_id IS NOT NULL);


--
-- Name: idx_label_logo_light_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_label_logo_light_file ON public.label USING btree (logo_light_file_id) WHERE (logo_light_file_id IS NOT NULL);


--
-- Name: idx_label_manager_member_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_label_manager_member_id ON public.label_manager USING btree (member_id);


--
-- Name: idx_label_owner_member_label; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_label_owner_member_label ON public.label_owner USING btree (member_id, label_id);


--
-- Name: idx_label_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_label_parent ON public.label USING btree (parent_label_id);


--
-- Name: idx_label_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_label_slug ON public.label USING btree (slug);


--
-- Name: idx_label_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_label_status ON public.label USING btree (status);


--
-- Name: idx_mail_adapter_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mail_adapter_active ON public.mail_adapter USING btree (is_active) WHERE (is_active = true);


--
-- Name: idx_mail_adapter_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mail_adapter_type ON public.mail_adapter USING btree (type);


--
-- Name: idx_map_place_created_by_member_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_map_place_created_by_member_id ON public.map_place USING btree (created_by_member_id) WHERE (created_by_member_id IS NOT NULL);


--
-- Name: idx_map_place_geom; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_map_place_geom ON public.map_place USING gist (geom);


--
-- Name: idx_map_place_google_place_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_map_place_google_place_id ON public.map_place USING btree (google_place_id) WHERE (google_place_id IS NOT NULL);


--
-- Name: idx_map_place_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_map_place_updated_at ON public.map_place USING btree (updated_at);


--
-- Name: idx_map_place_updated_by_member_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_map_place_updated_by_member_id ON public.map_place USING btree (updated_by_member_id) WHERE (updated_by_member_id IS NOT NULL);


--
-- Name: idx_media_generation_cleanup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_media_generation_cleanup ON public.media_generation USING btree (delete_after) WHERE (status = 'retired'::text);


--
-- Name: idx_media_generation_file_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_media_generation_file_status ON public.media_generation USING btree (file_id, status, created_at DESC);


--
-- Name: idx_member_deleted_available_emails_hold; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_member_deleted_available_emails_hold ON public.member USING gin (available_emails) WHERE ((account_identity_id IS NULL) AND (cardinality(available_emails) > 0));


--
-- Name: idx_member_unonboarded_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_member_unonboarded_created_at ON public.member USING btree (created_at, id) WHERE (NOT onboarded);


--
-- Name: idx_member_personal_access_token_member; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_member_personal_access_token_member ON public.member_personal_access_token USING btree (member_id);


--
-- Name: idx_menu_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_name ON public.menu USING btree (name);


--
-- Name: idx_mesh_optimization_candidate_expiry_cleanup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mesh_optimization_candidate_expiry_cleanup ON public.mesh_optimization_candidate USING btree (expires_at, status) WHERE ((selected_at IS NULL) AND (expires_at IS NOT NULL));


--
-- Name: idx_mesh_optimization_candidate_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mesh_optimization_candidate_job_id ON public.mesh_optimization_candidate USING btree (job_id) WHERE (job_id IS NOT NULL);


--
-- Name: idx_mesh_optimization_candidate_output_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mesh_optimization_candidate_output_status ON public.mesh_optimization_candidate USING btree (output_file_id, status) WHERE (output_file_id IS NOT NULL);


--
-- Name: idx_mesh_optimization_candidate_public_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mesh_optimization_candidate_public_asset ON public.mesh_optimization_candidate USING btree (public_asset_id) WHERE (public_asset_id IS NOT NULL);


--
-- Name: idx_mesh_optimization_candidate_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mesh_optimization_candidate_source ON public.mesh_optimization_candidate USING btree (source_file_id, target_ratio_percent, created_at DESC);


--
-- Name: idx_mesh_optimization_candidate_source_selected; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mesh_optimization_candidate_source_selected ON public.mesh_optimization_candidate USING btree (source_file_id, selected_at);


--
-- Name: idx_metadata_ai_job_requester_member_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_metadata_ai_job_requester_member_created_at ON public.metadata_ai_job USING btree (requester_member_id, created_at DESC);


--
-- Name: idx_metadata_ai_job_status_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_metadata_ai_job_status_created_at ON public.metadata_ai_job USING btree (status, created_at DESC);


--
-- Name: idx_metadata_ai_job_target_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_metadata_ai_job_target_created_at ON public.metadata_ai_job USING btree (target_type, target_id, created_at DESC);


--
-- Name: idx_newsletter_subscription_subscribed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_newsletter_subscription_subscribed_at ON public.newsletter_subscription USING btree (subscribed_at DESC, identity_id);


--
-- Name: idx_og_generation_active_deadline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_og_generation_active_deadline ON public.og_generation USING btree (deadline_at, id) WHERE (status = ANY (ARRAY['queued'::text, 'processing'::text]));


--
-- Name: idx_og_generation_lease_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_og_generation_lease_expiry ON public.og_generation USING btree (lease_expires_at, id) WHERE (status = 'processing'::text);


--
-- Name: idx_og_generation_run_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_og_generation_run_status ON public.og_generation USING btree (run_id, status, request_sequence);


--
-- Name: idx_og_generation_run_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_og_generation_run_status_created ON public.og_generation_run USING btree (status, created_at, id);


--
-- Name: idx_og_generation_target_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_og_generation_target_history ON public.og_generation USING btree (target_id, request_sequence DESC);


--
-- Name: idx_og_generation_target_latest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_og_generation_target_latest ON public.og_generation_target USING btree (latest_generation_id) WHERE (latest_generation_id IS NOT NULL);


--
-- Name: idx_page_featured_image; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_page_featured_image ON public.page USING btree (featured_image_file_id) WHERE (featured_image_file_id IS NOT NULL);


--
-- Name: idx_page_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_page_slug ON public.page USING btree (slug);


--
-- Name: idx_page_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_page_status ON public.page USING btree (status);


--
-- Name: idx_page_version_page_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_page_version_page_id ON public.page_version USING btree (page_id, version DESC);


--
-- Name: idx_post_author_member_post; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_author_member_post ON public.post_author USING btree (member_id, post_id);


--
-- Name: idx_post_category_post_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_category_post_id ON public.post_category USING btree (post_id);


--
-- Name: idx_post_collaborator_member_post; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_collaborator_member_post ON public.post_collaborator USING btree (member_id, post_id);


--
-- Name: idx_post_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_created_at ON public.post USING btree (created_at DESC);


--
-- Name: idx_post_featured_image; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_featured_image ON public.post USING btree (featured_image_file_id) WHERE (featured_image_file_id IS NOT NULL);


--
-- Name: idx_post_map_place_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_map_place_id ON public.post USING btree (map_place_id) WHERE (map_place_id IS NOT NULL);


--
-- Name: idx_post_scheduled_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_scheduled_due ON public.post USING btree (scheduled_at, id) WHERE (status = 'POST_STATUS_SCHEDULED'::public.post_status);


--
-- Name: idx_post_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_status ON public.post USING btree (status);


--
-- Name: idx_post_tag_post_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_tag_post_id ON public.post_tag USING btree (post_id);


--
-- Name: idx_post_version_post_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_version_post_id ON public.post_version USING btree (post_id, version DESC);


--
-- Name: idx_privacy_history_single_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_privacy_history_single_active ON public.privacy_history USING btree (status) WHERE ((status)::text = 'PRIVACY_STATUS_ACTIVE'::text);


--
-- Name: idx_privacy_history_single_scheduled; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_privacy_history_single_scheduled ON public.privacy_history USING btree (status) WHERE ((status)::text = 'PRIVACY_STATUS_SCHEDULED'::text);


--
-- Name: idx_program_event_artist_artist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_artist_artist ON public.program_event_artist USING btree (artist_id, sort_order);


--
-- Name: idx_program_event_client_client; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_client_client ON public.program_event_client USING btree (client_id, sort_order);


--
-- Name: idx_program_event_credit_artist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_credit_artist ON public.program_event_credit USING btree (artist_id) WHERE (artist_id IS NOT NULL);


--
-- Name: idx_program_event_credit_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_credit_event ON public.program_event_credit USING btree (event_id, sort_order);


--
-- Name: idx_program_event_credit_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_credit_member ON public.program_event_credit USING btree (member_id) WHERE (member_id IS NOT NULL);


--
-- Name: idx_program_event_label_label; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_label_label ON public.program_event_label USING btree (label_id, sort_order);


--
-- Name: idx_program_event_map_place; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_map_place ON public.program_event USING btree (map_place_id) WHERE (map_place_id IS NOT NULL);


--
-- Name: idx_program_event_media_event_role_sort; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_media_event_role_sort ON public.program_event_media USING btree (event_id, role, sort_order, created_at);


--
-- Name: idx_program_event_series; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_series ON public.program_event USING btree (series_id, series_order) WHERE (series_id IS NOT NULL);


--
-- Name: idx_program_event_series_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_series_status ON public.program_event_series USING btree (status, updated_at DESC);


--
-- Name: idx_program_event_status_starts_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_status_starts_at ON public.program_event USING btree (status, starts_at DESC);


--
-- Name: idx_program_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_type ON public.program_event USING btree (type_id, starts_at DESC);


--
-- Name: idx_program_event_type_locale_locale; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_type_locale_locale ON public.program_event_type_locale USING btree (locale, name);


--
-- Name: idx_program_event_type_status_sort; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_program_event_type_status_sort ON public.program_event_type USING btree (status, sort_order, slug);


--
-- Name: idx_public_asset_binding_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_public_asset_binding_asset ON public.public_asset_binding USING btree (asset_id);


--
-- Name: idx_public_asset_binding_source_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_public_asset_binding_source_file ON public.public_asset_binding USING btree (source_file_id) WHERE (source_file_id IS NOT NULL);


--
-- Name: idx_public_asset_og_retention; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_public_asset_og_retention ON public.public_asset USING btree (ready_at, id) WHERE ((kind = 'og'::text) AND (status = 'ready'::text));


--
-- Name: idx_public_asset_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_public_asset_status_created ON public.public_asset USING btree (status, created_at);


--
-- Name: idx_release_artist_artist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_artist_artist ON public.release_artist USING btree (artist_id);


--
-- Name: idx_release_artist_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_artist_release ON public.release_artist USING btree (release_id);


--
-- Name: idx_release_category_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_category_category ON public.release_category USING btree (category_id);


--
-- Name: idx_release_category_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_category_release ON public.release_category USING btree (release_id);


--
-- Name: idx_release_credit_artist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_credit_artist ON public.release_credit USING btree (artist_id);


--
-- Name: idx_release_credit_locale_locale_credit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_credit_locale_locale_credit ON public.release_credit_locale USING btree (locale, credit_id);


--
-- Name: idx_release_credit_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_credit_member ON public.release_credit USING btree (member_id);


--
-- Name: idx_release_credit_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_credit_release ON public.release_credit USING btree (release_id);


--
-- Name: idx_release_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_date ON public.release USING btree (release_date DESC);


--
-- Name: idx_release_file_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_file_release ON public.release_file USING btree (release_id);


--
-- Name: idx_release_file_sort; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_file_sort ON public.release_file USING btree (release_id, sort_order);


--
-- Name: idx_release_format_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_format_release ON public.release_format USING btree (release_id);


--
-- Name: idx_release_genre_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_genre_release ON public.release_genre USING btree (release_id);


--
-- Name: idx_release_label_label; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_label_label ON public.release_label USING btree (label_id);


--
-- Name: idx_release_label_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_label_release ON public.release_label USING btree (release_id);


--
-- Name: idx_release_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_status ON public.release USING btree (status);


--
-- Name: idx_release_style_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_style_release ON public.release_style USING btree (release_id);


--
-- Name: idx_release_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_release_type ON public.release USING btree (type);


--
-- Name: idx_series_featured_image; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_series_featured_image ON public.series USING btree (featured_image_file_id) WHERE (featured_image_file_id IS NOT NULL);


--
-- Name: idx_series_manager_member_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_series_manager_member_id ON public.series_manager USING btree (member_id);


--
-- Name: idx_share_link_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_share_link_entity ON public.share_link USING btree (entity_type, entity_id);


--
-- Name: idx_share_link_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_share_link_token ON public.share_link USING btree (token);


--
-- Name: idx_site_setting_loader_file_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_setting_loader_file_file_id ON public.site_setting_loader_file USING btree (file_id);


--
-- Name: idx_site_setting_loader_file_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_setting_loader_file_order ON public.site_setting_loader_file USING btree (site_setting_id, "position", created_at);


--
-- Name: idx_site_settings_favicon_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_favicon_file_id ON public.site_settings USING btree (favicon_file_id);


--
-- Name: idx_site_settings_homepage_page_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_homepage_page_id ON public.site_settings USING btree (homepage_page_id);


--
-- Name: idx_site_settings_logo_dark_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_logo_dark_file_id ON public.site_settings USING btree (logo_dark_file_id) WHERE (logo_dark_file_id IS NOT NULL);


--
-- Name: idx_site_settings_logo_email_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_logo_email_file_id ON public.site_settings USING btree (logo_email_file_id);


--
-- Name: idx_site_settings_logo_light_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_logo_light_file_id ON public.site_settings USING btree (logo_light_file_id) WHERE (logo_light_file_id IS NOT NULL);


--
-- Name: idx_site_settings_menu_avatar_dropdown_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_menu_avatar_dropdown_id ON public.site_settings USING btree (menu_avatar_dropdown_id);


--
-- Name: idx_site_settings_menu_footer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_menu_footer_id ON public.site_settings USING btree (menu_footer_id);


--
-- Name: idx_site_settings_menu_header_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_menu_header_id ON public.site_settings USING btree (menu_header_id);


--
-- Name: idx_site_settings_menu_secondary_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_settings_menu_secondary_id ON public.site_settings USING btree (menu_secondary_id);


--
-- Name: idx_style_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_style_slug ON public.style USING btree (slug);


--
-- Name: idx_tag_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tag_slug ON public.tag USING btree (slug);


--
-- Name: idx_terms_history_single_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_terms_history_single_active ON public.terms_history USING btree (status) WHERE ((status)::text = 'TERMS_STATUS_ACTIVE'::text);


--
-- Name: idx_terms_history_single_scheduled; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_terms_history_single_scheduled ON public.terms_history USING btree (status) WHERE ((status)::text = 'TERMS_STATUS_SCHEDULED'::text);


--
-- Name: idx_track_audio_original_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_audio_original_file ON public.track USING btree (audio_original_file_id) WHERE (audio_original_file_id IS NOT NULL);


--
-- Name: idx_track_download_audience_segment_reverse; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_download_audience_segment_reverse ON public.track_download_audience_segment USING btree (audience_segment_id, track_id);


--
-- Name: idx_track_credit_artist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_credit_artist ON public.track_credit USING btree (artist_id);


--
-- Name: idx_track_credit_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_credit_member ON public.track_credit USING btree (member_id);


--
-- Name: idx_track_credit_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_credit_track ON public.track_credit USING btree (track_id);


--
-- Name: idx_track_processing; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_processing ON public.track USING btree (processing_status);


--
-- Name: idx_track_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_release ON public.track USING btree (release_id);


--
-- Name: idx_transcode_job_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transcode_job_file ON public.transcode_job USING btree (file_id, created_at DESC);


--
-- Name: idx_translation_job_entity_locale_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_job_entity_locale_updated_at ON public.translation_job USING btree (entity_type, entity_id, target_locale, updated_at DESC);


--
-- Name: uq_translation_job_active_request_artifact; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_translation_job_active_request_artifact ON public.translation_job USING btree (entity_type, entity_id, target_locale, request_artifact_digest);


--
-- Name: idx_translation_job_status_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_job_status_updated_at ON public.translation_job USING btree (status, updated_at DESC);


--
-- Name: idx_translation_job_target_locale_status_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_job_target_locale_status_updated_at ON public.translation_job USING btree (target_locale, status, updated_at DESC);


--
-- Name: idx_translation_provider_config_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_provider_config_active ON public.translation_provider_config USING btree (is_active, priority, created_at) WHERE (is_active = true);


--
-- Name: idx_translation_provider_config_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_provider_config_type ON public.translation_provider_config USING btree (type);


--
-- Name: idx_upload_part_upload_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_part_upload_id ON public.upload_part USING btree (upload_id);


--
-- Name: idx_upload_session_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_session_file_id ON public.upload_session USING btree (file_id);


--
-- Name: idx_upload_session_file_id_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_session_file_id_status ON public.upload_session USING btree (file_id, status, last_activity_at DESC);


--
-- Name: idx_upload_session_last_activity_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_session_last_activity_at ON public.upload_session USING btree (last_activity_at);


--
-- Name: idx_upload_session_resume_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_session_resume_lookup ON public.upload_session USING btree (upload_type, entity_id, status, last_activity_at DESC);


--
-- Name: idx_upload_session_slot_attempt_resume_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_session_slot_attempt_resume_lookup ON public.upload_session USING btree (upload_type, entity_id, slot_id, attempt_id, status, last_activity_at DESC);


--
-- Name: idx_upload_session_slot_resume_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_session_slot_resume_lookup ON public.upload_session USING btree (upload_type, entity_id, slot_id, status, last_activity_at DESC);


--
-- Name: idx_upload_session_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_session_status ON public.upload_session USING btree (status);


--
-- Name: idx_upload_session_upload_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upload_session_upload_type ON public.upload_session USING btree (upload_type);


--
-- Name: idx_user_cookie_consent_member_recorded_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_cookie_consent_member_recorded_at ON public.user_cookie_consent USING btree (member_id, recorded_at DESC);


--
-- Name: idx_user_deletion_request_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_deletion_request_member ON public.user_deletion_request USING btree (member_id);


--
-- Name: idx_user_deletion_request_notification_email_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_deletion_request_notification_email_pending ON public.user_deletion_request USING btree (lower(notification_email)) WHERE ((scheduled_at IS NOT NULL) AND (notification_email IS NOT NULL));


--
-- Name: idx_user_deletion_request_scheduled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_deletion_request_scheduled ON public.user_deletion_request USING btree (scheduled_at) WHERE (scheduled_at IS NOT NULL);


--
-- Name: idx_user_deletion_request_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_deletion_request_token ON public.user_deletion_request USING btree (token);


--
-- Name: idx_user_tag_mapping_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_tag_mapping_tag ON public.user_tag_mapping USING btree (tag_id);


--
-- Name: idx_waveform_job_entity_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_waveform_job_entity_status ON public.waveform_job USING btree (entity_type, entity_id, status);


--
-- Name: idx_waveform_job_file_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_waveform_job_file_status ON public.waveform_job USING btree (file_id, status);


--
-- Name: idx_work_client_client; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_client_client ON public.work_client USING btree (client_id);


--
-- Name: idx_work_client_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_client_work ON public.work_client USING btree (work_id);


--
-- Name: idx_work_credit_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_credit_group ON public.work_credit USING btree (group_id);


--
-- Name: idx_work_credit_group_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_credit_group_work ON public.work_credit_group USING btree (work_id);


--
-- Name: idx_work_credit_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_credit_work ON public.work_credit USING btree (work_id);


--
-- Name: idx_work_featured; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_featured ON public.work USING btree (featured) WHERE (featured = true);


--
-- Name: idx_work_featured_image; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_featured_image ON public.work USING btree (featured_image_file_id) WHERE (featured_image_file_id IS NOT NULL);


--
-- Name: idx_work_map_place_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_map_place_id ON public.work USING btree (map_place_id) WHERE (map_place_id IS NOT NULL);


--
-- Name: idx_work_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_status ON public.work USING btree (status);


--
-- Name: idx_work_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_type ON public.work USING btree (type);


--
-- Name: idx_work_version_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_version_work_id ON public.work_version USING btree (work_id, version DESC);


--
-- Name: idx_work_year_month; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_year_month ON public.work USING btree (year DESC, month DESC);


--
-- Name: security_access_action_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX security_access_action_idx ON public.security_access USING btree (action, occurred_at DESC, access_id DESC);


--
-- Name: security_access_actor_member_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX security_access_actor_member_idx ON public.security_access USING btree (actor_member_id, occurred_at DESC, access_id DESC) WHERE (actor_member_id IS NOT NULL);


--
-- Name: security_access_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX security_access_occurred_at_idx ON public.security_access USING btree (occurred_at DESC, access_id DESC);


--
-- Name: security_access_request_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX security_access_request_idx ON public.security_access USING btree (request_id, occurred_at DESC, access_id DESC);


--
-- Name: security_access_source_ip_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX security_access_source_ip_idx ON public.security_access USING btree (source_ip, occurred_at DESC, access_id DESC);


--
-- Name: security_access_trace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX security_access_trace_idx ON public.security_access USING btree (trace_id, occurred_at DESC, access_id DESC) WHERE (trace_id IS NOT NULL);


--
-- Name: uq_member_account_identity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_member_account_identity_id ON public.member USING btree (account_identity_id) WHERE (account_identity_id IS NOT NULL);


--
-- Name: uq_member_nickname; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_member_nickname ON public.member USING btree (nickname);


--
-- Name: uq_program_event_media_file_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_program_event_media_file_scope ON public.program_event_media USING btree (event_id, role, file_id);


--
-- Name: uq_program_event_media_primary; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_program_event_media_primary ON public.program_event_media USING btree (event_id, role) WHERE (is_primary = true);


--
-- Name: uq_program_event_series_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_program_event_series_slug ON public.program_event_series USING btree (slug);


--
-- Name: uq_program_event_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_program_event_slug ON public.program_event USING btree (slug);


--
-- Name: uq_public_asset_source_original; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_public_asset_source_original ON public.public_asset USING btree (source_file_id) WHERE ((source_file_id IS NOT NULL) AND (kind = ANY (ARRAY['image'::text, 'mesh'::text, 'avatar'::text, 'logo'::text, 'favicon'::text, 'loader'::text, 'gallery'::text, 'artwork'::text, 'poster'::text, 'map_image'::text, 'texture'::text, 'email_image'::text])) AND (status <> 'deleted'::text));


--
-- Name: content_block content_block_parent_acyclic; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER content_block_parent_acyclic AFTER INSERT OR UPDATE ON public.content_block DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_block_parent_acyclic();


--
-- Name: content_block_attachment validate_content_block_attachment_download_policy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_content_block_attachment_download_policy AFTER INSERT OR DELETE OR UPDATE ON public.content_block_attachment DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_content_block_attachment_download_policy();


--
-- Name: content_block_attachment_download_audience_segment validate_content_block_attachment_download_policy_segment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_content_block_attachment_download_policy_segment AFTER INSERT OR DELETE OR UPDATE ON public.content_block_attachment_download_audience_segment DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_content_block_attachment_download_policy();


--
-- Name: content_block validate_content_block_kind_download_policy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_content_block_kind_download_policy AFTER UPDATE OF kind ON public.content_block DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_content_block_attachment_download_policy();


--
-- Name: artist enforce_artist_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_artist_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.artist DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: campaign enforce_campaign_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_campaign_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.campaign DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: email_template enforce_email_template_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_email_template_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.email_template DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: email_layout enforce_email_layout_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_email_layout_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.email_layout DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: form enforce_form_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_form_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.form DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: label enforce_label_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_label_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.label DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: menu enforce_menu_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_menu_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.menu DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: page enforce_page_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_page_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.page DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: post enforce_post_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_post_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.post DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: post post_configuration_revision_before_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER post_configuration_revision_before_update BEFORE UPDATE ON public.post FOR EACH ROW EXECUTE FUNCTION public.advance_post_configuration_revision();


--
-- Name: privacy_history enforce_privacy_history_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_privacy_history_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.privacy_history DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: program_event enforce_program_event_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_program_event_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.program_event DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: release enforce_release_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_release_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.release DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: series enforce_series_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_series_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.series DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: terms_history enforce_terms_history_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_terms_history_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.terms_history DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: work enforce_work_content_document_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER enforce_work_content_document_owner AFTER INSERT OR UPDATE OF content_document_id ON public.work DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_content_document_owner_contract();


--
-- Name: audience_segment reject_audience_segment_hard_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reject_audience_segment_hard_delete BEFORE DELETE ON public.audience_segment FOR EACH ROW EXECUTE FUNCTION public.reject_audience_segment_hard_delete();


--
-- Name: email_delivery_recipient reject_email_delivery_recipient_attribution_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reject_email_delivery_recipient_attribution_update BEFORE UPDATE ON public.email_delivery_recipient FOR EACH ROW EXECUTE FUNCTION public.reject_email_delivery_recipient_attribution_update();


--
-- Name: email_delivery_recipient reject_email_delivery_recipient_direct_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reject_email_delivery_recipient_direct_delete BEFORE DELETE ON public.email_delivery_recipient FOR EACH ROW EXECUTE FUNCTION public.reject_email_delivery_recipient_direct_delete();


--
-- Name: email_delivery_run reject_email_delivery_run_definition_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reject_email_delivery_run_definition_update BEFORE UPDATE ON public.email_delivery_run FOR EACH ROW EXECUTE FUNCTION public.reject_email_delivery_run_definition_update();


--
-- Name: email_delivery_run_target_excluded_member reject_sealed_email_delivery_run_target_exclusion_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reject_sealed_email_delivery_run_target_exclusion_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.email_delivery_run_target_excluded_member FOR EACH ROW EXECUTE FUNCTION public.reject_sealed_email_delivery_run_target_mutation();


--
-- Name: email_delivery_run_target_user_role reject_sealed_email_delivery_run_target_user_role_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reject_sealed_email_delivery_run_target_user_role_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.email_delivery_run_target_user_role FOR EACH ROW EXECUTE FUNCTION public.reject_sealed_email_delivery_run_target_mutation();


--
-- Name: email_delivery_run_target_user_tag reject_sealed_email_delivery_run_target_user_tag_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reject_sealed_email_delivery_run_target_user_tag_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.email_delivery_run_target_user_tag FOR EACH ROW EXECUTE FUNCTION public.reject_sealed_email_delivery_run_target_mutation();


--
-- Name: email_delivery_recipient validate_email_delivery_recipient_capture; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_email_delivery_recipient_capture BEFORE INSERT OR UPDATE OF member_id, identity_id ON public.email_delivery_recipient FOR EACH ROW EXECUTE FUNCTION public.validate_email_delivery_recipient_capture();


--
-- Name: email_delivery_run_target_excluded_member validate_email_delivery_run_excluded_member_capture; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_email_delivery_run_excluded_member_capture BEFORE INSERT OR UPDATE OF member_id, identity_id ON public.email_delivery_run_target_excluded_member FOR EACH ROW EXECUTE FUNCTION public.validate_email_delivery_run_excluded_member_capture();


--
-- Name: email_delivery_run validate_email_delivery_run_target; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_email_delivery_run_target AFTER INSERT OR UPDATE ON public.email_delivery_run DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_email_delivery_run_target_trigger();


--
-- Name: email_delivery_run_target_excluded_member validate_email_delivery_run_target_excluded_member; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_email_delivery_run_target_excluded_member AFTER INSERT OR DELETE OR UPDATE ON public.email_delivery_run_target_excluded_member DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_email_delivery_run_target_trigger();


--
-- Name: email_delivery_run_target_user_role validate_email_delivery_run_target_user_role; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_email_delivery_run_target_user_role AFTER INSERT OR DELETE OR UPDATE ON public.email_delivery_run_target_user_role DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_email_delivery_run_target_trigger();


--
-- Name: email_delivery_run_target_user_tag validate_email_delivery_run_target_user_tag; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_email_delivery_run_target_user_tag AFTER INSERT OR DELETE OR UPDATE ON public.email_delivery_run_target_user_tag DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_email_delivery_run_target_trigger();


--
-- Name: track validate_track_download_policy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_track_download_policy AFTER INSERT OR DELETE OR UPDATE OF audio_original_file_id, download_audience ON public.track DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_track_download_policy();


--
-- Name: track_download_audience_segment validate_track_download_policy_segment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER validate_track_download_policy_segment AFTER INSERT OR DELETE OR UPDATE ON public.track_download_audience_segment DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_track_download_policy();


--
-- Name: account_email_change_request account_email_change_request_identity_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_email_change_request
    ADD CONSTRAINT account_email_change_request_identity_fkey FOREIGN KEY (identity_id) REFERENCES public.account_identity(id) ON DELETE CASCADE;


--
-- Name: account_email_change_request account_email_change_request_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_email_change_request
    ADD CONSTRAINT account_email_change_request_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: artist artist_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist
    ADD CONSTRAINT artist_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.artist
    ADD CONSTRAINT artist_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: artist artist_country_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist
    ADD CONSTRAINT artist_country_code_fkey FOREIGN KEY (country_code) REFERENCES public.country(code);


--
-- Name: artist_file artist_file_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_file
    ADD CONSTRAINT artist_file_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: artist_file artist_file_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_file
    ADD CONSTRAINT artist_file_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file(id) ON DELETE CASCADE;


--
-- Name: artist_label artist_label_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_label
    ADD CONSTRAINT artist_label_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: artist_label artist_label_label_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_label
    ADD CONSTRAINT artist_label_label_id_fkey FOREIGN KEY (label_id) REFERENCES public.label(id) ON DELETE CASCADE;


--
-- Name: artist_manager artist_manager_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_manager
    ADD CONSTRAINT artist_manager_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: artist_manager artist_manager_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_manager
    ADD CONSTRAINT artist_manager_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: artist artist_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist
    ADD CONSTRAINT artist_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: artist_owner artist_owner_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_owner
    ADD CONSTRAINT artist_owner_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: artist_owner artist_owner_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_owner
    ADD CONSTRAINT artist_owner_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: artist artist_parent_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist
    ADD CONSTRAINT artist_parent_artist_id_fkey FOREIGN KEY (parent_artist_id) REFERENCES public.artist(id) ON DELETE SET NULL;


--
-- Name: artist_translation artist_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_translation
    ADD CONSTRAINT artist_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: artist_translation artist_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_translation
    ADD CONSTRAINT artist_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: artist_translation artist_translation_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_translation
    ADD CONSTRAINT artist_translation_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: audience_segment_excluded_member audience_segment_excluded_member_audience_segment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment_excluded_member
    ADD CONSTRAINT audience_segment_excluded_member_audience_segment_id_fkey FOREIGN KEY (audience_segment_id) REFERENCES public.audience_segment(id) ON DELETE CASCADE;


--
-- Name: audience_segment_excluded_member audience_segment_excluded_member_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment_excluded_member
    ADD CONSTRAINT audience_segment_excluded_member_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: audience_segment_user_role audience_segment_user_role_audience_segment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment_user_role
    ADD CONSTRAINT audience_segment_user_role_audience_segment_id_fkey FOREIGN KEY (audience_segment_id) REFERENCES public.audience_segment(id) ON DELETE CASCADE;


--
-- Name: audience_segment_user_tag audience_segment_user_tag_audience_segment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment_user_tag
    ADD CONSTRAINT audience_segment_user_tag_audience_segment_id_fkey FOREIGN KEY (audience_segment_id) REFERENCES public.audience_segment(id) ON DELETE CASCADE;


--
-- Name: audience_segment_user_tag audience_segment_user_tag_user_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segment_user_tag
    ADD CONSTRAINT audience_segment_user_tag_user_tag_id_fkey FOREIGN KEY (user_tag_id) REFERENCES public.user_tag(id) ON DELETE RESTRICT;


--
-- Name: auth_bootstrap_state auth_bootstrap_state_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_bootstrap_state
    ADD CONSTRAINT auth_bootstrap_state_identity_id_fkey FOREIGN KEY (identity_id) REFERENCES public.account_identity(id) ON DELETE SET NULL;


--
-- Name: auth_bootstrap_state auth_bootstrap_state_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_bootstrap_state
    ADD CONSTRAINT auth_bootstrap_state_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: campaign campaign_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign
    ADD CONSTRAINT campaign_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.campaign
    ADD CONSTRAINT campaign_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: email_delivery_recipient campaign_delivery_recipient_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_recipient
    ADD CONSTRAINT campaign_delivery_recipient_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.email_delivery_run(id) ON DELETE CASCADE;


--
-- Name: campaign campaign_layout_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign
    ADD CONSTRAINT campaign_layout_id_fkey FOREIGN KEY (layout_id) REFERENCES public.email_layout(id) ON DELETE RESTRICT;


--
-- Name: campaign campaign_segment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign
    ADD CONSTRAINT campaign_segment_id_fkey FOREIGN KEY (segment_id) REFERENCES public.audience_segment(id) ON DELETE RESTRICT;


--
-- Name: campaign_translation campaign_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_translation
    ADD CONSTRAINT campaign_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.campaign(id) ON DELETE CASCADE;


--
-- Name: campaign_translation campaign_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_translation
    ADD CONSTRAINT campaign_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: client client_logo_dark_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_logo_dark_file_id_fkey FOREIGN KEY (logo_dark_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: client client_logo_light_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_logo_light_file_id_fkey FOREIGN KEY (logo_light_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: comment comment_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT comment_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: comment comment_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT comment_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.comment(id) ON DELETE CASCADE;


--
-- Name: comment comment_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT comment_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON DELETE CASCADE;


--
-- Name: content_block_attachment content_block_attachment_block_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_attachment
    ADD CONSTRAINT content_block_attachment_block_id_fkey FOREIGN KEY (block_id) REFERENCES public.content_block(id) ON DELETE CASCADE;


--
-- Name: content_block_attachment content_block_attachment_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_attachment
    ADD CONSTRAINT content_block_attachment_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file(id) ON DELETE RESTRICT;


--
-- Name: content_block_attachment_download_audience_segment content_block_attachment_download_segment_attachment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_attachment_download_audience_segment
    ADD CONSTRAINT content_block_attachment_download_segment_attachment_fkey FOREIGN KEY (block_id, reference_path) REFERENCES public.content_block_attachment(block_id, reference_path) ON DELETE CASCADE;


--
-- Name: content_block_attachment_download_audience_segment content_block_attachment_download_audience_segment_segment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_attachment_download_audience_segment
    ADD CONSTRAINT content_block_attachment_download_audience_segment_segment_fkey FOREIGN KEY (audience_segment_id) REFERENCES public.audience_segment(id) ON DELETE CASCADE;


--
-- Name: content_block content_block_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block
    ADD CONSTRAINT content_block_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.content_document(id) ON DELETE CASCADE;


--
-- Name: content_block_locale content_block_locale_block_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_locale
    ADD CONSTRAINT content_block_locale_block_id_fkey FOREIGN KEY (block_id) REFERENCES public.content_block(id) ON DELETE CASCADE;


--
-- Name: content_block_locale content_block_locale_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block_locale
    ADD CONSTRAINT content_block_locale_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: content_block content_block_parent_same_document_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_block
    ADD CONSTRAINT content_block_parent_same_document_fkey FOREIGN KEY (document_id, parent_block_id) REFERENCES public.content_block(document_id, id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: domain_audit domain_audit_actor_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_audit
    ADD CONSTRAINT domain_audit_actor_member_id_fkey FOREIGN KEY (actor_member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: email_delivery_recipient email_delivery_recipient_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_recipient
    ADD CONSTRAINT email_delivery_recipient_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: email_delivery_run email_delivery_run_audience_segment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run
    ADD CONSTRAINT email_delivery_run_audience_segment_id_fkey FOREIGN KEY (audience_segment_id) REFERENCES public.audience_segment(id) ON DELETE RESTRICT;


--
-- Name: email_delivery_run email_delivery_run_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run
    ADD CONSTRAINT email_delivery_run_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.campaign(id) ON DELETE RESTRICT;


--
--
-- Name: email_delivery_run email_delivery_run_source_layout_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run
    ADD CONSTRAINT email_delivery_run_source_layout_id_fkey FOREIGN KEY (source_layout_id) REFERENCES public.email_layout(id) ON DELETE SET NULL;


--
-- Name: email_delivery_run email_delivery_run_source_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run
    ADD CONSTRAINT email_delivery_run_source_template_id_fkey FOREIGN KEY (source_template_id) REFERENCES public.email_template(id) ON DELETE SET NULL;


--
-- Name: email_delivery_run_target_excluded_member email_delivery_run_target_excluded_member_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_excluded_member
    ADD CONSTRAINT email_delivery_run_target_excluded_member_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: email_delivery_run_target_excluded_member email_delivery_run_target_excluded_member_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_excluded_member
    ADD CONSTRAINT email_delivery_run_target_excluded_member_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.email_delivery_run(id) ON DELETE CASCADE;


--
-- Name: email_delivery_run_target_user_role email_delivery_run_target_user_role_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_user_role
    ADD CONSTRAINT email_delivery_run_target_user_role_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.email_delivery_run(id) ON DELETE CASCADE;


--
-- Name: email_delivery_run_target_user_tag email_delivery_run_target_user_tag_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_user_tag
    ADD CONSTRAINT email_delivery_run_target_user_tag_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.email_delivery_run(id) ON DELETE CASCADE;


--
-- Name: email_delivery_run_target_user_tag email_delivery_run_target_user_tag_user_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_run_target_user_tag
    ADD CONSTRAINT email_delivery_run_target_user_tag_user_tag_id_fkey FOREIGN KEY (user_tag_id) REFERENCES public.user_tag(id) ON DELETE RESTRICT;


--
--
-- Name: email_layout_translation email_layout_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layout_translation
    ADD CONSTRAINT email_layout_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.email_layout(id) ON DELETE CASCADE;


--
-- Name: email_layout_translation email_layout_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layout_translation
    ADD CONSTRAINT email_layout_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: email_layout email_layout_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layout
    ADD CONSTRAINT email_layout_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: email_layout email_layout_source_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layout
    ADD CONSTRAINT email_layout_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: email_template email_template_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template
    ADD CONSTRAINT email_template_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.email_template
    ADD CONSTRAINT email_template_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: email_template email_template_layout_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template
    ADD CONSTRAINT email_template_layout_id_fkey FOREIGN KEY (layout_id) REFERENCES public.email_layout(id) ON DELETE RESTRICT;


--
-- Name: email_template_translation email_template_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template_translation
    ADD CONSTRAINT email_template_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.email_template(id) ON DELETE CASCADE;


--
-- Name: email_template_translation email_template_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_template_translation
    ADD CONSTRAINT email_template_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: file_derivative file_derivative_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_derivative
    ADD CONSTRAINT file_derivative_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.public_asset(id) ON DELETE RESTRICT;


--
-- Name: file_derivative file_derivative_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_derivative
    ADD CONSTRAINT file_derivative_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file(id) ON DELETE CASCADE;


--
-- Name: file_derivative file_derivative_media_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_derivative
    ADD CONSTRAINT file_derivative_media_generation_id_fkey FOREIGN KEY (media_generation_id) REFERENCES public.media_generation(id) ON DELETE RESTRICT;


-- Name: file_folder file_folder_created_by_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_folder
    ADD CONSTRAINT file_folder_created_by_member_id_fkey FOREIGN KEY (created_by_member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: file file_folder_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file
    ADD CONSTRAINT file_folder_id_fkey FOREIGN KEY (folder_id) REFERENCES public.file_folder(id) ON DELETE SET NULL;


--
-- Name: file_folder file_folder_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_folder
    ADD CONSTRAINT file_folder_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.file_folder(id) ON DELETE CASCADE;


--
-- Name: file_ingest_binding file_ingest_binding_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_ingest_binding
    ADD CONSTRAINT file_ingest_binding_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file(id) ON DELETE CASCADE;


--
-- Name: file file_uploaded_by_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file
    ADD CONSTRAINT file_uploaded_by_member_id_fkey FOREIGN KEY (uploaded_by_member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: og_generation fk_og_generation_superseded_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation
    ADD CONSTRAINT fk_og_generation_superseded_by FOREIGN KEY (target_id, superseded_by_id) REFERENCES public.og_generation(target_id, id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: og_generation_target fk_og_generation_target_latest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation_target
    ADD CONSTRAINT fk_og_generation_target_latest FOREIGN KEY (id, latest_generation_id) REFERENCES public.og_generation(target_id, id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: form form_featured_image_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form
    ADD CONSTRAINT form_featured_image_file_id_fkey FOREIGN KEY (featured_image_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: form form_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form
    ADD CONSTRAINT form_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: form form_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form
    ADD CONSTRAINT form_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: form form_source_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form
    ADD CONSTRAINT form_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: form_submission form_submission_form_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_submission
    ADD CONSTRAINT form_submission_form_id_fkey FOREIGN KEY (form_id) REFERENCES public.form(id) ON DELETE CASCADE;


--
-- Name: form_submission form_submission_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_submission
    ADD CONSTRAINT form_submission_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: form_translation form_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_translation
    ADD CONSTRAINT form_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.form(id) ON DELETE CASCADE;


--
-- Name: form_translation form_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_translation
    ADD CONSTRAINT form_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: form_translation form_translation_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_translation
    ADD CONSTRAINT form_translation_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: label label_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: label label_country_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_country_code_fkey FOREIGN KEY (country_code) REFERENCES public.country(code);


--
-- Name: label label_logo_dark_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_logo_dark_file_id_fkey FOREIGN KEY (logo_dark_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: label label_logo_light_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_logo_light_file_id_fkey FOREIGN KEY (logo_light_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: label_manager label_manager_label_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_manager
    ADD CONSTRAINT label_manager_label_id_fkey FOREIGN KEY (label_id) REFERENCES public.label(id) ON DELETE CASCADE;


--
-- Name: label_manager label_manager_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_manager
    ADD CONSTRAINT label_manager_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: label label_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: label_owner label_owner_label_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_owner
    ADD CONSTRAINT label_owner_label_id_fkey FOREIGN KEY (label_id) REFERENCES public.label(id) ON DELETE CASCADE;


--
-- Name: label_owner label_owner_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_owner
    ADD CONSTRAINT label_owner_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: label label_parent_label_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label
    ADD CONSTRAINT label_parent_label_id_fkey FOREIGN KEY (parent_label_id) REFERENCES public.label(id) ON DELETE SET NULL;


--
-- Name: label_translation label_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_translation
    ADD CONSTRAINT label_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.label(id) ON DELETE CASCADE;


--
-- Name: label_translation label_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_translation
    ADD CONSTRAINT label_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: map_place map_place_created_by_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.map_place
    ADD CONSTRAINT map_place_created_by_member_id_fkey FOREIGN KEY (created_by_member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: map_place map_place_image_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.map_place
    ADD CONSTRAINT map_place_image_file_id_fkey FOREIGN KEY (image_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: map_place map_place_updated_by_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.map_place
    ADD CONSTRAINT map_place_updated_by_member_id_fkey FOREIGN KEY (updated_by_member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: media_generation media_generation_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_generation
    ADD CONSTRAINT media_generation_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file(id) ON DELETE CASCADE;


--
-- Name: member member_account_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member
    ADD CONSTRAINT member_account_identity_id_fkey FOREIGN KEY (account_identity_id) REFERENCES public.account_identity(id) ON DELETE SET NULL;


--
-- Name: member_personal_access_token member_personal_access_token_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member_personal_access_token
    ADD CONSTRAINT member_personal_access_token_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE CASCADE;


--
-- Name: menu_translation menu_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_translation
    ADD CONSTRAINT menu_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.menu(id) ON DELETE CASCADE;


--
-- Name: menu_translation menu_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_translation
    ADD CONSTRAINT menu_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: menu menu_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu
    ADD CONSTRAINT menu_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: menu menu_source_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu
    ADD CONSTRAINT menu_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: mesh_optimization_candidate mesh_optimization_candidate_output_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesh_optimization_candidate
    ADD CONSTRAINT mesh_optimization_candidate_output_file_id_fkey FOREIGN KEY (output_file_id) REFERENCES public.file(id) ON DELETE RESTRICT;


--
-- Name: mesh_optimization_candidate mesh_optimization_candidate_public_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesh_optimization_candidate
    ADD CONSTRAINT mesh_optimization_candidate_public_asset_id_fkey FOREIGN KEY (public_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: mesh_optimization_candidate mesh_optimization_candidate_source_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesh_optimization_candidate
    ADD CONSTRAINT mesh_optimization_candidate_source_file_id_fkey FOREIGN KEY (source_file_id) REFERENCES public.file(id) ON DELETE CASCADE;


--
-- Name: metadata_ai_job metadata_ai_job_requester_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_ai_job
    ADD CONSTRAINT metadata_ai_job_requester_member_id_fkey FOREIGN KEY (requester_member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: newsletter_subscription newsletter_subscription_identity_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.newsletter_subscription
    ADD CONSTRAINT newsletter_subscription_identity_fkey FOREIGN KEY (identity_id) REFERENCES public.account_identity(id) ON DELETE CASCADE;


--
-- Name: og_generation og_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation
    ADD CONSTRAINT og_generation_id_fkey FOREIGN KEY (id) REFERENCES public.public_asset(id) ON DELETE RESTRICT;


--
-- Name: og_generation og_generation_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation
    ADD CONSTRAINT og_generation_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.og_generation_run(id) ON DELETE RESTRICT;


--
-- Name: og_generation og_generation_target_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation
    ADD CONSTRAINT og_generation_target_id_fkey FOREIGN KEY (target_id) REFERENCES public.og_generation_target(id) ON DELETE RESTRICT;


--
-- Name: og_generation_target og_generation_target_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.og_generation_target
    ADD CONSTRAINT og_generation_target_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: page page_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page
    ADD CONSTRAINT page_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.page
    ADD CONSTRAINT page_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: page page_featured_image_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page
    ADD CONSTRAINT page_featured_image_file_id_fkey FOREIGN KEY (featured_image_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: page page_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page
    ADD CONSTRAINT page_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: page_translation page_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_translation
    ADD CONSTRAINT page_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.page(id) ON DELETE CASCADE;


--
-- Name: page_translation page_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_translation
    ADD CONSTRAINT page_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: page_translation page_translation_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_translation
    ADD CONSTRAINT page_translation_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: page_version page_version_page_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_version
    ADD CONSTRAINT page_version_page_id_fkey FOREIGN KEY (page_id) REFERENCES public.page(id) ON DELETE CASCADE;


--
-- Name: post_author post_author_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_author
    ADD CONSTRAINT post_author_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: post_author post_author_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_author
    ADD CONSTRAINT post_author_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON DELETE CASCADE;


--
-- Name: post_category post_category_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_category
    ADD CONSTRAINT post_category_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.category(id) ON DELETE RESTRICT;


--
-- Name: post_category post_category_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_category
    ADD CONSTRAINT post_category_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON DELETE CASCADE;


--
-- Name: post_collaborator post_collaborator_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_collaborator
    ADD CONSTRAINT post_collaborator_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: post_collaborator post_collaborator_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_collaborator
    ADD CONSTRAINT post_collaborator_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON DELETE CASCADE;


--
-- Name: post post_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: post post_featured_image_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_featured_image_file_id_fkey FOREIGN KEY (featured_image_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: post post_map_place_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_map_place_id_fkey FOREIGN KEY (map_place_id) REFERENCES public.map_place(id) ON DELETE RESTRICT;


--
-- Name: post post_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: post post_series_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_series_id_fkey FOREIGN KEY (series_id) REFERENCES public.series(id) ON DELETE SET NULL;


--
-- Name: post_tag post_tag_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_tag
    ADD CONSTRAINT post_tag_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON DELETE CASCADE;


--
-- Name: post_tag post_tag_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_tag
    ADD CONSTRAINT post_tag_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tag(id) ON DELETE RESTRICT;


--
-- Name: post_translation post_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_translation
    ADD CONSTRAINT post_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.post(id) ON DELETE CASCADE;


--
-- Name: post_translation post_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_translation
    ADD CONSTRAINT post_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: post_translation post_translation_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_translation
    ADD CONSTRAINT post_translation_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: post_version post_version_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_version
    ADD CONSTRAINT post_version_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON DELETE CASCADE;


--
-- Name: privacy_history privacy_history_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.privacy_history
    ADD CONSTRAINT privacy_history_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.privacy_history
    ADD CONSTRAINT privacy_history_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: privacy_translation privacy_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.privacy_translation
    ADD CONSTRAINT privacy_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.privacy_history(id) ON DELETE CASCADE;


--
-- Name: privacy_translation privacy_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.privacy_translation
    ADD CONSTRAINT privacy_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: program_event_artist program_event_artist_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_artist
    ADD CONSTRAINT program_event_artist_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: program_event_artist program_event_artist_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_artist
    ADD CONSTRAINT program_event_artist_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.program_event(id) ON DELETE CASCADE;


--
-- Name: program_event_client program_event_client_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_client
    ADD CONSTRAINT program_event_client_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(id) ON DELETE RESTRICT;


--
-- Name: program_event_client program_event_client_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_client
    ADD CONSTRAINT program_event_client_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.program_event(id) ON DELETE CASCADE;


--
-- Name: program_event program_event_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event
    ADD CONSTRAINT program_event_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: program_event_credit program_event_credit_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_credit
    ADD CONSTRAINT program_event_credit_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: program_event_credit program_event_credit_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_credit
    ADD CONSTRAINT program_event_credit_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.program_event(id) ON DELETE CASCADE;


--
-- Name: program_event_credit program_event_credit_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_credit
    ADD CONSTRAINT program_event_credit_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: program_event_label program_event_label_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_label
    ADD CONSTRAINT program_event_label_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.program_event(id) ON DELETE CASCADE;


--
-- Name: program_event_label program_event_label_label_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_label
    ADD CONSTRAINT program_event_label_label_id_fkey FOREIGN KEY (label_id) REFERENCES public.label(id) ON DELETE CASCADE;


--
-- Name: program_event program_event_map_place_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event
    ADD CONSTRAINT program_event_map_place_id_fkey FOREIGN KEY (map_place_id) REFERENCES public.map_place(id) ON DELETE RESTRICT;


--
-- Name: program_event_media program_event_media_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_media
    ADD CONSTRAINT program_event_media_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.program_event(id) ON DELETE CASCADE;


--
-- Name: program_event_media program_event_media_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_media
    ADD CONSTRAINT program_event_media_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file(id) ON DELETE CASCADE;


--
-- Name: program_event program_event_series_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event
    ADD CONSTRAINT program_event_series_id_fkey FOREIGN KEY (series_id) REFERENCES public.program_event_series(id) ON DELETE SET NULL;


--
-- Name: program_event_series program_event_series_poster_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_series
    ADD CONSTRAINT program_event_series_poster_file_id_fkey FOREIGN KEY (poster_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: program_event program_event_source_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event
    ADD CONSTRAINT program_event_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: program_event_translation program_event_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_translation
    ADD CONSTRAINT program_event_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.program_event(id) ON DELETE CASCADE;


--
-- Name: program_event_translation program_event_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_translation
    ADD CONSTRAINT program_event_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: program_event program_event_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event
    ADD CONSTRAINT program_event_type_id_fkey FOREIGN KEY (type_id) REFERENCES public.program_event_type(id) ON DELETE RESTRICT;


--
-- Name: program_event_type_locale program_event_type_locale_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_type_locale
    ADD CONSTRAINT program_event_type_locale_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: program_event_type_locale program_event_type_locale_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.program_event_type_locale
    ADD CONSTRAINT program_event_type_locale_type_id_fkey FOREIGN KEY (type_id) REFERENCES public.program_event_type(id) ON DELETE CASCADE;


--
-- Name: public_asset_binding public_asset_binding_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_asset_binding
    ADD CONSTRAINT public_asset_binding_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.public_asset(id) ON DELETE RESTRICT;


--
-- Name: public_asset_binding public_asset_binding_source_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_asset_binding
    ADD CONSTRAINT public_asset_binding_source_file_id_fkey FOREIGN KEY (source_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: public_asset public_asset_source_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_asset
    ADD CONSTRAINT public_asset_source_file_id_fkey FOREIGN KEY (source_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: release_artist release_artist_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_artist
    ADD CONSTRAINT release_artist_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: release_artist release_artist_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_artist
    ADD CONSTRAINT release_artist_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release_category release_category_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_category
    ADD CONSTRAINT release_category_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.category(id) ON DELETE RESTRICT;


--
-- Name: release_category release_category_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_category
    ADD CONSTRAINT release_category_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release release_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release
    ADD CONSTRAINT release_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.release
    ADD CONSTRAINT release_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: release_credit release_credit_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_credit
    ADD CONSTRAINT release_credit_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: release_credit_locale release_credit_locale_credit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_credit_locale
    ADD CONSTRAINT release_credit_locale_credit_id_fkey FOREIGN KEY (credit_id) REFERENCES public.release_credit(id) ON DELETE CASCADE;


--
-- Name: release_credit_locale release_credit_locale_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_credit_locale
    ADD CONSTRAINT release_credit_locale_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: release_credit release_credit_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_credit
    ADD CONSTRAINT release_credit_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: release_credit release_credit_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_credit
    ADD CONSTRAINT release_credit_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release_file release_file_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_file
    ADD CONSTRAINT release_file_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file(id) ON DELETE CASCADE;


--
-- Name: release_file release_file_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_file
    ADD CONSTRAINT release_file_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release_format release_format_format_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_format
    ADD CONSTRAINT release_format_format_id_fkey FOREIGN KEY (format_id) REFERENCES public.format(id) ON DELETE RESTRICT;


--
-- Name: release_format release_format_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_format
    ADD CONSTRAINT release_format_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release_genre release_genre_genre_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_genre
    ADD CONSTRAINT release_genre_genre_id_fkey FOREIGN KEY (genre_id) REFERENCES public.genre(id) ON DELETE RESTRICT;


--
-- Name: release_genre release_genre_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_genre
    ADD CONSTRAINT release_genre_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release_label release_label_label_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_label
    ADD CONSTRAINT release_label_label_id_fkey FOREIGN KEY (label_id) REFERENCES public.label(id) ON DELETE CASCADE;


--
-- Name: release_label release_label_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_label
    ADD CONSTRAINT release_label_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release release_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release
    ADD CONSTRAINT release_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: release_style release_style_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_style
    ADD CONSTRAINT release_style_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release_style release_style_style_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_style
    ADD CONSTRAINT release_style_style_id_fkey FOREIGN KEY (style_id) REFERENCES public.style(id) ON DELETE RESTRICT;


--
-- Name: release_translation release_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_translation
    ADD CONSTRAINT release_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: release_translation release_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.release_translation
    ADD CONSTRAINT release_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: series series_featured_image_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_featured_image_file_id_fkey FOREIGN KEY (featured_image_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: series_manager series_manager_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series_manager
    ADD CONSTRAINT series_manager_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: series_manager series_manager_series_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series_manager
    ADD CONSTRAINT series_manager_series_id_fkey FOREIGN KEY (series_id) REFERENCES public.series(id) ON DELETE CASCADE;


--
-- Name: series series_source_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: series series_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: series_translation series_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series_translation
    ADD CONSTRAINT series_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.series(id) ON DELETE CASCADE;


--
-- Name: series_translation series_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series_translation
    ADD CONSTRAINT series_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: series_translation series_translation_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.series_translation
    ADD CONSTRAINT series_translation_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: site_setting_loader_file site_setting_loader_file_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_setting_loader_file
    ADD CONSTRAINT site_setting_loader_file_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file(id) ON DELETE CASCADE;


--
-- Name: site_setting_loader_file site_setting_loader_file_site_setting_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_setting_loader_file
    ADD CONSTRAINT site_setting_loader_file_site_setting_id_fkey FOREIGN KEY (site_setting_id) REFERENCES public.site_settings(id) ON DELETE CASCADE;


--
-- Name: site_settings site_settings_default_map_theme_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_default_map_theme_id_fkey FOREIGN KEY (default_map_theme_id) REFERENCES public.map_theme(id) ON DELETE RESTRICT;


--
-- Name: site_settings site_settings_favicon_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_favicon_file_id_fkey FOREIGN KEY (favicon_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_homepage_page_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_homepage_page_id_fkey FOREIGN KEY (homepage_page_id) REFERENCES public.page(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_logo_dark_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_logo_dark_file_id_fkey FOREIGN KEY (logo_dark_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_logo_email_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_logo_email_file_id_fkey FOREIGN KEY (logo_email_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_logo_light_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_logo_light_file_id_fkey FOREIGN KEY (logo_light_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_menu_avatar_dropdown_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_menu_avatar_dropdown_id_fkey FOREIGN KEY (menu_avatar_dropdown_id) REFERENCES public.menu(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_menu_footer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_menu_footer_id_fkey FOREIGN KEY (menu_footer_id) REFERENCES public.menu(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_menu_header_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_menu_header_id_fkey FOREIGN KEY (menu_header_id) REFERENCES public.menu(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_menu_secondary_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_menu_secondary_id_fkey FOREIGN KEY (menu_secondary_id) REFERENCES public.menu(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_privacy_og_background_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_privacy_og_background_file_id_fkey FOREIGN KEY (privacy_og_background_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_site_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_site_og_asset_id_fkey FOREIGN KEY (site_og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_site_og_background_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_site_og_background_file_id_fkey FOREIGN KEY (site_og_background_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: site_settings site_settings_terms_og_background_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_settings
    ADD CONSTRAINT site_settings_terms_og_background_file_id_fkey FOREIGN KEY (terms_og_background_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: terms_history terms_history_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_history
    ADD CONSTRAINT terms_history_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.terms_history
    ADD CONSTRAINT terms_history_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: terms_translation terms_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_translation
    ADD CONSTRAINT terms_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.terms_history(id) ON DELETE CASCADE;


--
-- Name: terms_translation terms_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_translation
    ADD CONSTRAINT terms_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: track track_audio_original_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track
    ADD CONSTRAINT track_audio_original_file_id_fkey FOREIGN KEY (audio_original_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: track_download_audience_segment track_download_audience_segment_segment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_download_audience_segment
    ADD CONSTRAINT track_download_audience_segment_segment_fkey FOREIGN KEY (audience_segment_id) REFERENCES public.audience_segment(id) ON DELETE CASCADE;


--
-- Name: track_download_audience_segment track_download_audience_segment_track_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_download_audience_segment
    ADD CONSTRAINT track_download_audience_segment_track_fkey FOREIGN KEY (track_id) REFERENCES public.track(id) ON DELETE CASCADE;


--
-- Name: track_credit track_credit_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_credit
    ADD CONSTRAINT track_credit_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: track_credit track_credit_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_credit
    ADD CONSTRAINT track_credit_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: track_credit track_credit_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_credit
    ADD CONSTRAINT track_credit_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.track(id) ON DELETE CASCADE;


--
-- Name: track track_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track
    ADD CONSTRAINT track_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.release(id) ON DELETE CASCADE;


--
-- Name: translation_job translation_job_requested_by_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_job
    ADD CONSTRAINT translation_job_requested_by_member_id_fkey FOREIGN KEY (requested_by_member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: translation_job translation_job_source_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_job
    ADD CONSTRAINT translation_job_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: translation_job translation_job_target_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_job
    ADD CONSTRAINT translation_job_target_locale_fkey FOREIGN KEY (target_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: translation_settings translation_settings_default_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_settings
    ADD CONSTRAINT translation_settings_default_locale_fkey FOREIGN KEY (default_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: upload_part upload_part_upload_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.upload_part
    ADD CONSTRAINT upload_part_upload_id_fkey FOREIGN KEY (upload_id) REFERENCES public.upload_session(upload_id) ON DELETE CASCADE;


--
-- Name: user_cookie_consent user_cookie_consent_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_cookie_consent
    ADD CONSTRAINT user_cookie_consent_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: user_deletion_request user_deletion_request_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_deletion_request
    ADD CONSTRAINT user_deletion_request_identity_id_fkey FOREIGN KEY (identity_id) REFERENCES public.account_identity(id) ON DELETE CASCADE;


--
-- Name: user_deletion_request user_deletion_request_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_deletion_request
    ADD CONSTRAINT user_deletion_request_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: user_deletion_request user_deletion_request_notification_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_deletion_request
    ADD CONSTRAINT user_deletion_request_notification_locale_fkey FOREIGN KEY (notification_locale) REFERENCES public.translation_locale(code) ON DELETE SET NULL;


--
-- Name: user_tag_mapping user_tag_mapping_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tag_mapping
    ADD CONSTRAINT user_tag_mapping_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: user_tag_mapping user_tag_mapping_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tag_mapping
    ADD CONSTRAINT user_tag_mapping_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.user_tag(id) ON DELETE CASCADE;


--
-- Name: work_client work_client_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_client
    ADD CONSTRAINT work_client_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(id) ON DELETE RESTRICT;


--
-- Name: work_client work_client_work_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_client
    ADD CONSTRAINT work_client_work_id_fkey FOREIGN KEY (work_id) REFERENCES public.work(id) ON DELETE CASCADE;


--
-- Name: work work_content_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work
    ADD CONSTRAINT work_content_document_id_fkey FOREIGN KEY (content_document_id) REFERENCES public.content_document(id) DEFERRABLE INITIALLY DEFERRED;


ALTER TABLE ONLY public.work
    ADD CONSTRAINT work_source_locale_fkey FOREIGN KEY (source_locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: work_credit work_credit_artist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_credit
    ADD CONSTRAINT work_credit_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist(id) ON DELETE CASCADE;


--
-- Name: work_credit work_credit_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_credit
    ADD CONSTRAINT work_credit_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.work_credit_group(id) ON DELETE SET NULL;


--
-- Name: work_credit_group work_credit_group_work_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_credit_group
    ADD CONSTRAINT work_credit_group_work_id_fkey FOREIGN KEY (work_id) REFERENCES public.work(id) ON DELETE CASCADE;


--
-- Name: work_credit work_credit_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_credit
    ADD CONSTRAINT work_credit_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id) ON DELETE RESTRICT;


--
-- Name: work_credit work_credit_work_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_credit
    ADD CONSTRAINT work_credit_work_id_fkey FOREIGN KEY (work_id) REFERENCES public.work(id) ON DELETE CASCADE;


--
-- Name: work work_featured_image_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work
    ADD CONSTRAINT work_featured_image_file_id_fkey FOREIGN KEY (featured_image_file_id) REFERENCES public.file(id) ON DELETE SET NULL;


--
-- Name: work work_map_place_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work
    ADD CONSTRAINT work_map_place_id_fkey FOREIGN KEY (map_place_id) REFERENCES public.map_place(id) ON DELETE RESTRICT;


--
-- Name: work work_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work
    ADD CONSTRAINT work_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: work_translation work_translation_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_translation
    ADD CONSTRAINT work_translation_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.work(id) ON DELETE CASCADE;


--
-- Name: work_translation work_translation_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_translation
    ADD CONSTRAINT work_translation_locale_fkey FOREIGN KEY (locale) REFERENCES public.translation_locale(code) ON DELETE RESTRICT;


--
-- Name: work_translation work_translation_og_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_translation
    ADD CONSTRAINT work_translation_og_asset_id_fkey FOREIGN KEY (og_asset_id) REFERENCES public.public_asset(id) ON DELETE SET NULL;


--
-- Name: work_version work_version_work_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_version
    ADD CONSTRAINT work_version_work_id_fkey FOREIGN KEY (work_id) REFERENCES public.work(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

DO $$
DECLARE
    queue_name text;
BEGIN
    FOREACH queue_name IN ARRAY ARRAY[
        'og.generate',
        'transcoder.audio',
        'transcoder.video',
        'waveform.generate',
        'asset_optimizer.mesh',
        'file.delete',
        'email.send',
        'email.auth',
        'email.campaign',
        'user.delete.identity',
        'user.delete.avatar',
        'ai.metadata.generate',
        'translation.generate',
        'transcode.result',
        'waveform.result',
        'mesh.optimization.result',
        'release.track_original_audio.projection'
    ]
    LOOP
        PERFORM pgmq.create(queue_name);
    END LOOP;
END $$;

REVOKE ALL ON SCHEMA observability FROM PUBLIC;
REVOKE ALL ON observability.durable_record FROM PUBLIC;
GRANT USAGE ON SCHEMA observability TO geul_observability_reader;
GRANT SELECT ON observability.durable_record TO geul_observability_reader;
REVOKE ALL ON FUNCTION public.geul_pgmq_replay_file_ingest_projection(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_pgmq_archives(timestamp with time zone) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.geul_pgmq_replay_file_ingest_projection(text)
TO geul_pgmq_replay_operator;
GRANT EXECUTE ON FUNCTION public.purge_pgmq_archives(timestamp with time zone)
TO geul_pgmq_api;

GRANT pg_read_all_data, pg_monitor TO geul_observability_reader;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA pgmq FROM PUBLIC;

GRANT EXECUTE ON FUNCTION pgmq.format_table_name(text, text),
    pgmq.metrics(text)
TO geul_observability_reader;

REVOKE ALL PRIVILEGES ON SCHEMA pgmq FROM geul_pgmq_replay_operator;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA pgmq FROM geul_pgmq_replay_operator;

GRANT USAGE ON SCHEMA pgmq TO
    geul_pgmq_api,
    geul_pgmq_collab,
    geul_pgmq_transcoder,
    geul_pgmq_asset_optimizer,
    geul_pgmq_og;

GRANT EXECUTE ON FUNCTION pgmq.format_table_name(text, text) TO
    geul_pgmq_api,
    geul_pgmq_collab,
    geul_pgmq_transcoder,
    geul_pgmq_asset_optimizer,
    geul_pgmq_og;

GRANT EXECUTE ON FUNCTION pgmq.send(text, jsonb) TO
    geul_pgmq_api,
    geul_pgmq_transcoder,
    geul_pgmq_asset_optimizer;
GRANT EXECUTE ON FUNCTION pgmq.send(text, jsonb, jsonb, integer) TO
    geul_pgmq_api,
    geul_pgmq_transcoder,
    geul_pgmq_asset_optimizer;
GRANT EXECUTE ON FUNCTION pgmq.send(text, jsonb, jsonb, timestamp with time zone) TO
    geul_pgmq_api,
    geul_pgmq_transcoder,
    geul_pgmq_asset_optimizer;

GRANT EXECUTE ON FUNCTION pgmq.read(text, integer, integer, jsonb),
    pgmq.delete(text, bigint),
    pgmq.archive(text, bigint),
    pgmq.set_vt(text, bigint, integer),
    pgmq.set_vt(text, bigint, timestamp with time zone),
    pgmq.metrics(text)
TO
    geul_pgmq_api,
    geul_pgmq_collab,
    geul_pgmq_transcoder,
    geul_pgmq_asset_optimizer,
    geul_pgmq_og;

DO $$
DECLARE
    queue_name text;
    qtable text;
    atable text;
    qsequence text;
BEGIN
    FOREACH queue_name IN ARRAY ARRAY[
        'og.generate',
        'transcoder.audio',
        'transcoder.video',
        'waveform.generate',
        'asset_optimizer.mesh',
        'file.delete',
        'email.send',
        'email.auth',
        'email.campaign',
        'user.delete.identity',
        'user.delete.avatar',
        'ai.metadata.generate',
        'translation.generate',
        'transcode.result',
        'waveform.result',
        'mesh.optimization.result',
        'release.track_original_audio.projection'
    ]
    LOOP
        qtable := pgmq.format_table_name(queue_name, 'q');
        atable := pgmq.format_table_name(queue_name, 'a');
        qsequence := qtable || '_msg_id_seq';

        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pgmq.%I TO geul_pgmq_api', qtable);
        EXECUTE format('GRANT SELECT, INSERT ON TABLE pgmq.%I TO geul_pgmq_api', atable);
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE pgmq.%I TO geul_pgmq_api', qsequence);
        EXECUTE format('REVOKE ALL PRIVILEGES ON TABLE pgmq.%I, pgmq.%I FROM geul_pgmq_replay_operator', qtable, atable);
        EXECUTE format('REVOKE ALL PRIVILEGES ON SEQUENCE pgmq.%I FROM geul_pgmq_replay_operator', qsequence);
    END LOOP;

    FOREACH queue_name IN ARRAY ARRAY[
        'release.track_original_audio.projection'
    ]
    LOOP
        qtable := pgmq.format_table_name(queue_name, 'q');
        atable := pgmq.format_table_name(queue_name, 'a');
        EXECUTE format('GRANT SELECT, UPDATE, DELETE ON TABLE pgmq.%I TO geul_pgmq_collab', qtable);
        EXECUTE format('GRANT SELECT, INSERT ON TABLE pgmq.%I TO geul_pgmq_collab', atable);
    END LOOP;

    FOREACH queue_name IN ARRAY ARRAY['transcoder.audio', 'transcoder.video', 'waveform.generate']
    LOOP
        qtable := pgmq.format_table_name(queue_name, 'q');
        atable := pgmq.format_table_name(queue_name, 'a');
        EXECUTE format('GRANT SELECT, UPDATE, DELETE ON TABLE pgmq.%I TO geul_pgmq_transcoder', qtable);
        EXECUTE format('GRANT SELECT, INSERT ON TABLE pgmq.%I TO geul_pgmq_transcoder', atable);
    END LOOP;

    FOREACH queue_name IN ARRAY ARRAY['transcode.result', 'waveform.result']
    LOOP
        qtable := pgmq.format_table_name(queue_name, 'q');
        qsequence := qtable || '_msg_id_seq';
        EXECUTE format('GRANT INSERT, SELECT ON TABLE pgmq.%I TO geul_pgmq_transcoder', qtable);
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE pgmq.%I TO geul_pgmq_transcoder', qsequence);
    END LOOP;

    qtable := pgmq.format_table_name('asset_optimizer.mesh', 'q');
    atable := pgmq.format_table_name('asset_optimizer.mesh', 'a');
    EXECUTE format('GRANT SELECT, UPDATE, DELETE ON TABLE pgmq.%I TO geul_pgmq_asset_optimizer', qtable);
    EXECUTE format('GRANT SELECT, INSERT ON TABLE pgmq.%I TO geul_pgmq_asset_optimizer', atable);

    qtable := pgmq.format_table_name('mesh.optimization.result', 'q');
    qsequence := qtable || '_msg_id_seq';
    EXECUTE format('GRANT INSERT, SELECT ON TABLE pgmq.%I TO geul_pgmq_asset_optimizer', qtable);
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE pgmq.%I TO geul_pgmq_asset_optimizer', qsequence);

    qtable := pgmq.format_table_name('og.generate', 'q');
    atable := pgmq.format_table_name('og.generate', 'a');
    EXECUTE format('GRANT SELECT, UPDATE, DELETE ON TABLE pgmq.%I TO geul_pgmq_og', qtable);
    EXECUTE format('GRANT SELECT, INSERT ON TABLE pgmq.%I TO geul_pgmq_og', atable);
END $$;

-- Deterministic reference and system-template bootstrap data.

--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET search_path = public, pg_catalog;
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: content_document; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.content_document (id, profile) VALUES ('049aad1d-844a-5753-bc8a-0f91e75cdb21', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('0541f243-1b82-5cc5-8e2c-b45b6268b0f2', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('0868b2b5-1964-57d3-8249-738e0130b960', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('13181ddb-e7bc-58a3-b35b-1d1381be7054', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('274f41b8-e037-560a-8695-fd4d3ac5d833', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('280de60d-55a7-50c2-8f60-d6f952306f56', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('43c1aa0d-0e08-57e2-a4aa-d67456c17553', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('51429686-2340-5f0f-aecc-4bf3fb40ffc3', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('588fea29-2730-574c-9585-f10910f710fa', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('6022998c-5ebd-58c9-a880-24f09210b106', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('6a6a045d-ac55-5498-8254-fa6c4db95eb0', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('7366d833-1d68-5890-aaca-4df7ce5d58d8', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('8013c80b-d997-5df1-a63c-9aaf2e052498', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('807ccd1a-3062-5717-ab49-be611504c41d', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('934bd8c8-1114-5dc6-bd2a-d26933889321', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('97039fd1-1270-5e21-bbdd-5c6da12d9072', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('a5bcd392-ffeb-567d-9d50-e93abfd81865', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('c597ac88-1ebb-528e-9f12-3de010c473e1', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('c5ec4cdf-94b6-5eb4-9668-77ecf3141381', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('c6757525-2503-5d06-a1c6-6b867270ce00', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('ca373a6e-7ee1-5612-8ff0-6ec949759016', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('d9e56cb5-ab13-528d-bcc7-aa5237801672', 'email');
INSERT INTO public.content_document (id, profile) VALUES ('f80cd929-5472-5b15-83f6-2a6e63ba582c', 'email');


--
-- Data for Name: content_block; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', '049aad1d-844a-5753-bc8a-0f91e75cdb21', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('044b0c2f-9c61-5de8-9f46-3445067f7faf', '274f41b8-e037-560a-8695-fd4d3ac5d833', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', '6a6a045d-ac55-5498-8254-fa6c4db95eb0', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('1939befb-1fc6-5cea-ac22-0580335e0559', '7366d833-1d68-5890-aaca-4df7ce5d58d8', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', '6022998c-5ebd-58c9-a880-24f09210b106', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', '588fea29-2730-574c-9585-f10910f710fa', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', '51429686-2340-5f0f-aecc-4bf3fb40ffc3', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('68a4277d-22b9-5d4b-a4f6-19610cdc6155', 'a5bcd392-ffeb-567d-9d50-e93abfd81865', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'c597ac88-1ebb-528e-9f12-3de010c473e1', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('7aa62546-f96b-57bc-83ce-39a1af00845a', '934bd8c8-1114-5dc6-bd2a-d26933889321', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('7bd0b861-e3cf-5079-9080-055c0496ac44', '280de60d-55a7-50c2-8f60-d6f952306f56', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('83e81281-d5d6-5922-819b-fa312bb4ad13', 'ca373a6e-7ee1-5612-8ff0-6ec949759016', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'd9e56cb5-ab13-528d-bcc7-aa5237801672', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', '8013c80b-d997-5df1-a63c-9aaf2e052498', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'c5ec4cdf-94b6-5eb4-9668-77ecf3141381', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'f80cd929-5472-5b15-83f6-2a6e63ba582c', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', '807ccd1a-3062-5717-ab49-be611504c41d', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', '0868b2b5-1964-57d3-8249-738e0130b960', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('c7373687-5476-5c2e-ab3e-946dc046bed1', '13181ddb-e7bc-58a3-b35b-1d1381be7054', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', '97039fd1-1270-5e21-bbdd-5c6da12d9072', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'c6757525-2503-5d06-a1c6-6b867270ce00', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'c597ac88-1ebb-528e-9f12-3de010c473e1', NULL, 'content', 1, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', '049aad1d-844a-5753-bc8a-0f91e75cdb21', NULL, 'content', 1, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('eaa95d1c-9a6a-5888-8c68-a35036b2be74', '0541f243-1b82-5cc5-8e2c-b45b6268b0f2', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');
INSERT INTO public.content_block (id, document_id, parent_block_id, container_slot, "position", kind, shared_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', '43c1aa0d-0e08-57e2-a4aa-d67456c17553', NULL, 'content', 0, 'paragraph', '{"paragraph": {"props": {}}}');


--
-- Data for Name: content_block_attachment; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: translation_locale; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('en', 'English', true, true, 'ltr', true, 'latin', 10, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('ar', 'Arabic', true, true, 'rtl', true, 'arabic', 120, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('de', 'German', true, true, 'ltr', true, 'latin', 80, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('es', 'Spanish', true, true, 'ltr', true, 'latin', 60, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('es-419', 'Spanish (Latin America)', true, true, 'ltr', true, 'latin', 65, '2026-08-09 00:00:00+00', '2026-08-09 00:00:00+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('fr', 'French', true, true, 'ltr', true, 'latin', 70, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('id', 'Indonesian', true, true, 'ltr', true, 'latin', 130, '2026-08-09 00:00:00+00', '2026-08-09 00:00:00+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('it', 'Italian', true, true, 'ltr', true, 'latin', 100, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('ja', 'Japanese', true, true, 'ltr', true, 'cjk', 30, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('ko', 'Korean', true, true, 'ltr', true, 'cjk', 20, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('nl', 'Dutch', true, true, 'ltr', true, 'latin', 110, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('pl', 'Polish', true, true, 'ltr', true, 'latin', 170, '2026-08-09 00:00:00+00', '2026-08-09 00:00:00+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('pt-BR', 'Portuguese (Brazil)', true, true, 'ltr', true, 'latin', 90, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('pt-PT', 'Portuguese (Portugal)', true, true, 'ltr', true, 'latin', 95, '2026-08-09 00:00:00+00', '2026-08-09 00:00:00+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('ru', 'Russian', true, true, 'ltr', true, 'latin', 180, '2026-08-09 00:00:00+00', '2026-08-09 00:00:00+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('th', 'Thai', true, true, 'ltr', true, 'latin', 150, '2026-08-09 00:00:00+00', '2026-08-09 00:00:00+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('tr', 'Turkish', true, true, 'ltr', true, 'latin', 160, '2026-08-09 00:00:00+00', '2026-08-09 00:00:00+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('vi', 'Vietnamese', true, true, 'ltr', true, 'latin', 140, '2026-08-09 00:00:00+00', '2026-08-09 00:00:00+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('zh-CN', 'Chinese (Simplified)', true, true, 'ltr', true, 'cjk', 40, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');
INSERT INTO public.translation_locale (code, display_name, enabled, is_public, dir, machine_translation_allowed, font_profile, sort_order, created_at, updated_at) VALUES ('zh-TW', 'Chinese (Traditional)', true, true, 'ltr', true, 'cjk', 50, '2026-08-03 07:42:51.151361+00', '2026-08-03 07:42:51.151361+00');


--
-- Data for Name: content_block_locale; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0136d829-b6d4-5afa-92c4-05005d48e3cf', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('044b0c2f-9c61-5de8-9f46-3445067f7faf', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "The email address {{email}} was added to your account for email-code sign-in.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "مرحبًا {{name}}. أهلًا بك في {{site_name}}. تسجيل الدخول: {{login_url}}. شكرًا لانضمامك إلينا.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Willkommen bei {{site_name}}. Anmelden: {{login_url}}. Vielen Dank, dass Sie dabei sind.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hello {{name}}. Welcome to {{site_name}}, and thanks for joining us. You can sign in at {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hola, {{name}}. Te damos la bienvenida a {{site_name}}. Iniciar sesión: {{login_url}}. Gracias por unirte.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Bonjour {{name}}. Bienvenue sur {{site_name}}. Connexion : {{login_url}}. Merci de nous avoir rejoints.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Ciao {{name}}. Benvenuto su {{site_name}}. Accedi: {{login_url}}. Grazie per esserti unito.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}さん、{{site_name}}へようこそ。ログイン: {{login_url}}。 ご参加いただきありがとうございます。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}님, {{site_name}}에 오신 것을 환영합니다. 로그인: {{login_url}}. 함께해 주셔서 감사합니다.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Welkom bij {{site_name}}. Inloggen: {{login_url}}. Bedankt dat je meedoet.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Olá, {{name}}. Boas-vindas ao {{site_name}}. Entrar: {{login_url}}. Agradecemos por fazer parte.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，欢迎使用{{site_name}}。登录：{{login_url}}。 感谢您的加入。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('0f9abecf-5189-5cb4-ad60-6eb626b71023', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，歡迎使用{{site_name}}。登入：{{login_url}}。 感謝您的加入。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('1939befb-1fc6-5cea-ac22-0580335e0559', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "A passkey was removed from your account. If you did not make this change, review your security settings immediately.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "مرحبًا {{name}}. أصبح حسابك نشطًا من جديد. تسجيل الدخول: {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Ihr Konto ist wieder aktiv. Anmelden: {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hello {{name}}. Your account recovery is complete and your account is active again. Sign in at {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hola, {{name}}. Tu cuenta vuelve a estar activa. Iniciar sesión: {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Bonjour {{name}}. Votre compte est de nouveau actif. Connexion : {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Ciao {{name}}. Il tuo account è di nuovo attivo. Accedi: {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}さん、アカウントは再び有効になりました。ログイン: {{login_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}님, 계정이 다시 활성화되었습니다. 로그인: {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Je account is weer actief. Inloggen: {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Olá, {{name}}. Sua conta está ativa novamente. Entrar: {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，您的账户已重新启用。登录：{{login_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20582bfc-f972-5ed9-853e-e52326b3d8f4', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，您的帳戶已重新啟用。登入：{{login_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "مرحبًا {{name}}. أكّد الحذف عبر {{confirm_url}} خلال {{expires_in}}. تجاهل هذه الرسالة إذا لم تطلب الحذف.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Bestätigen Sie die Löschung innerhalb von {{expires_in}} unter {{confirm_url}}. Wenn Sie die Löschung nicht angefordert haben, ignorieren Sie diese E-Mail.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hello {{name}}. We received a request to delete your account. Confirm the request at {{confirm_url}} within {{expires_in}}. If you did not request deletion, ignore this email.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hola, {{name}}. Confirma la eliminación en {{confirm_url}} antes de {{expires_in}}. Si no solicitaste la eliminación, ignora este correo.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Bonjour {{name}}. Confirmez la suppression sur {{confirm_url}} dans un délai de {{expires_in}}. Si vous n’avez pas demandé la suppression, ignorez cet e-mail.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Ciao {{name}}. Conferma l’eliminazione su {{confirm_url}} entro {{expires_in}}. Se non hai richiesto l’eliminazione, ignora questa e-mail.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}さん、{{expires_in}}以内に{{confirm_url}}でアカウント削除を確認してください。 削除を依頼していない場合は、このメールを無視してください。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}님, {{expires_in}} 이내에 {{confirm_url}}에서 계정 삭제를 확인해 주세요. 삭제를 요청하지 않았다면 이 이메일을 무시하세요.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Bevestig de verwijdering binnen {{expires_in}} via {{confirm_url}}. Negeer deze e-mail als je de verwijdering niet hebt aangevraagd.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Olá, {{name}}. Confirme a exclusão em {{confirm_url}} dentro de {{expires_in}}. Se você não solicitou a exclusão, ignore este e-mail.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，请在{{expires_in}}内前往{{confirm_url}}确认删除账户。 如果您未请求删除，请忽略此邮件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('20ea43d0-4424-59e9-8daf-3cae4ce79adc', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，請在{{expires_in}}內前往{{confirm_url}}確認刪除帳戶。 若您未要求刪除，請忽略此郵件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "استخدم {{verification_code}} للتحقق من {{recipient_email}} في {{site_name}} خلال {{expires_in_minutes}} دقيقة، أو افتح {{verification_url}}. تجاهل هذه الرسالة إذا لم تطلبها.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Verwenden Sie {{verification_code}}, um {{recipient_email}} bei {{site_name}} innerhalb von {{expires_in_minutes}} Minuten zu bestätigen, oder öffnen Sie {{verification_url}}. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Use code {{verification_code}} to verify {{recipient_email}} for {{site_name}} within {{expires_in_minutes}} minutes, or open {{verification_url}}. If you did not request this code, ignore this email.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Usa {{verification_code}} para verificar {{recipient_email}} en {{site_name}} durante los próximos {{expires_in_minutes}} minutos, o abre {{verification_url}}. Ignora este correo si no lo solicitaste.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Utilisez {{verification_code}} pour vérifier {{recipient_email}} sur {{site_name}} dans les {{expires_in_minutes}} prochaines minutes, ou ouvrez {{verification_url}}. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Usa {{verification_code}} per verificare {{recipient_email}} su {{site_name}} entro {{expires_in_minutes}} minuti oppure apri {{verification_url}}. Ignora questa e-mail se non hai fatto la richiesta.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{expires_in_minutes}}分以内に{{verification_code}}を使って{{site_name}}の{{recipient_email}}を確認してください。または{{verification_url}}を開いてください。心当たりがない場合はこのメールを無視してください。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{expires_in_minutes}}분 이내에 {{verification_code}} 코드를 사용하여 {{site_name}}의 {{recipient_email}}을(를) 인증하세요. 또는 {{verification_url}}을(를) 여세요. 요청하지 않았다면 이 이메일을 무시하세요.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Gebruik {{verification_code}} om {{recipient_email}} binnen {{expires_in_minutes}} minuten bij {{site_name}} te verifiëren, of open {{verification_url}}. Negeer deze e-mail als je dit niet hebt aangevraagd.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Use {{verification_code}} para verificar {{recipient_email}} no {{site_name}} dentro de {{expires_in_minutes}} minutos ou abra {{verification_url}}. Ignore este e-mail se você não fez a solicitação.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "请在{{expires_in_minutes}}分钟内使用{{verification_code}}验证{{site_name}}的{{recipient_email}}，或打开{{verification_url}}。如果并非您本人请求，请忽略此邮件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('4c88df00-2d9b-5976-9878-0e8f9e9d79b8', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "請在{{expires_in_minutes}}分鐘內使用{{verification_code}}驗證{{site_name}}的{{recipient_email}}，或開啟{{verification_url}}。若非您本人要求，請忽略此郵件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('68a4277d-22b9-5d4b-a4f6-19610cdc6155', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Your account email changed from {{old_email}} to {{new_email}}. If you did not make this change, contact support immediately.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('741e0dca-0070-527e-ab36-3fa23e42ac9d', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{policy_title}}", "styles": {"bold": true}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('7aa62546-f96b-57bc-83ce-39a1af00845a', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "A sign-in method on your account was changed. Method: {{method}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('7bd0b861-e3cf-5079-9080-055c0496ac44', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "A passkey was added to your account. If you did not make this change, review your security settings immediately.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('83e81281-d5d6-5922-819b-fa312bb4ad13', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "The email address {{email}} was removed from email-code sign-in on your account.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "مرحبًا {{name}}. حُذف حسابك نهائيًا كما طلبت. لا يلزم اتخاذ أي إجراء آخر.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Ihr Konto wurde wie gewünscht dauerhaft gelöscht. Es ist keine weitere Aktion erforderlich.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hello {{name}}. Your account has been permanently deleted as requested. No further action is required.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hola, {{name}}. Tu cuenta se eliminó permanentemente tal como solicitaste. No es necesario que hagas nada más.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Bonjour {{name}}. Votre compte a été supprimé définitivement comme demandé. Aucune autre action n’est requise.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Ciao {{name}}. Il tuo account è stato eliminato definitivamente come richiesto. Non è richiesta alcuna altra azione.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}さん、ご依頼どおりアカウントは完全に削除されました。 これ以上の操作は必要ありません。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}님, 요청하신 대로 계정이 영구 삭제되었습니다. 추가로 할 일은 없습니다.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Je account is zoals gevraagd permanent verwijderd. Er is geen verdere actie nodig.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Olá, {{name}}. Sua conta foi excluída permanentemente como solicitado. Nenhuma outra ação é necessária.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，您的账户已按要求永久删除。 无需采取其他操作。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('8491a766-25fd-55ce-99f3-b6f244773be8', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，您的帳戶已依要求永久刪除。 無需採取其他動作。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "مرحبًا {{name}}. أكّد الاسترداد عبر {{confirm_url}} خلال {{expires_in}}. تجاهل هذه الرسالة إذا لم تطلب الاسترداد.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Bestätigen Sie die Wiederherstellung innerhalb von {{expires_in}} unter {{confirm_url}}. Wenn Sie die Wiederherstellung nicht angefordert haben, ignorieren Sie diese E-Mail.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hello {{name}}. We received a request to recover your account. Confirm recovery at {{confirm_url}} within {{expires_in}}. If you did not request recovery, ignore this email.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hola, {{name}}. Confirma la recuperación en {{confirm_url}} antes de {{expires_in}}. Si no solicitaste la recuperación, ignora este correo.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Bonjour {{name}}. Confirmez la récupération sur {{confirm_url}} dans un délai de {{expires_in}}. Si vous n’avez pas demandé la récupération, ignorez cet e-mail.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Ciao {{name}}. Conferma il recupero su {{confirm_url}} entro {{expires_in}}. Se non hai richiesto il recupero, ignora questa e-mail.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}さん、{{expires_in}}以内に{{confirm_url}}でアカウント復旧を確認してください。 復旧を依頼していない場合は、このメールを無視してください。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}님, {{expires_in}} 이내에 {{confirm_url}}에서 계정 복구를 확인해 주세요. 복구를 요청하지 않았다면 이 이메일을 무시하세요.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Bevestig het herstel binnen {{expires_in}} via {{confirm_url}}. Negeer deze e-mail als je het herstel niet hebt aangevraagd.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Olá, {{name}}. Confirme a recuperação em {{confirm_url}} dentro de {{expires_in}}. Se você não solicitou a recuperação, ignore este e-mail.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，请在{{expires_in}}内前往{{confirm_url}}确认恢复账户。 如果您未请求恢复，请忽略此邮件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('860034a0-adbc-5838-bbb0-37214ed13277', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，請在{{expires_in}}內前往{{confirm_url}}確認復原帳戶。 若您未要求復原，請忽略此郵件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "تغيّر عنوان بريدك الإلكتروني من {{old_email}} إلى {{new_email}}. تواصل مع الدعم إذا لم تُجرِ هذا التغيير.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Ihre E-Mail-Adresse wurde von {{old_email}} in {{new_email}} geändert. Wenden Sie sich an den Support, wenn Sie dies nicht veranlasst haben.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "The email address for your account changed from {{old_email}} to {{new_email}}. Contact support immediately if you did not make this change.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Tu dirección de correo cambió de {{old_email}} a {{new_email}}. Contacta con soporte si no realizaste este cambio.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Votre adresse e-mail est passée de {{old_email}} à {{new_email}}. Contactez l’assistance si vous n’êtes pas à l’origine de ce changement.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Il tuo indirizzo e-mail è cambiato da {{old_email}} a {{new_email}}. Contatta l’assistenza se non hai effettuato questa modifica.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "メールアドレスが{{old_email}}から{{new_email}}に変更されました。心当たりがない場合はサポートへご連絡ください。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "이메일 주소가 {{old_email}}에서 {{new_email}}(으)로 변경되었습니다. 본인이 변경하지 않았다면 지원팀에 문의해 주세요.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Je e-mailadres is gewijzigd van {{old_email}} naar {{new_email}}. Neem contact op met ondersteuning als jij dit niet hebt gedaan.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Seu endereço de e-mail mudou de {{old_email}} para {{new_email}}. Fale com o suporte se você não fez essa alteração.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "您的电子邮箱地址已从{{old_email}}更改为{{new_email}}。如果不是您本人操作，请联系支持团队。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('983f6e57-35db-5db1-aa39-44cf42204c77', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "您的電子郵件地址已從{{old_email}}變更為{{new_email}}。若非您本人操作，請聯絡支援團隊。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "استخدم {{registration_code}} لتسجيل {{recipient_email}} في {{site_name}} خلال {{expires_in_minutes}} دقيقة. تجاهل هذه الرسالة إذا لم تطلبها.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Verwenden Sie {{registration_code}}, um {{recipient_email}} innerhalb von {{expires_in_minutes}} Minuten bei {{site_name}} zu registrieren. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Use code {{registration_code}} to register {{recipient_email}} with {{site_name}} within {{expires_in_minutes}} minutes. If you did not request this code, ignore this email.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Usa {{registration_code}} para registrar {{recipient_email}} en {{site_name}} durante los próximos {{expires_in_minutes}} minutos. Ignora este correo si no lo solicitaste.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Utilisez {{registration_code}} pour inscrire {{recipient_email}} sur {{site_name}} dans les {{expires_in_minutes}} prochaines minutes. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Usa {{registration_code}} per registrare {{recipient_email}} su {{site_name}} entro {{expires_in_minutes}} minuti. Ignora questa e-mail se non hai fatto la richiesta.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{expires_in_minutes}}分以内に{{registration_code}}を使って{{recipient_email}}を{{site_name}}に登録してください。心当たりがない場合はこのメールを無視してください。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{expires_in_minutes}}분 이내에 {{registration_code}} 코드를 사용하여 {{recipient_email}}을(를) {{site_name}}에 등록하세요. 요청하지 않았다면 이 이메일을 무시하세요.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Gebruik {{registration_code}} om {{recipient_email}} binnen {{expires_in_minutes}} minuten bij {{site_name}} te registreren. Negeer deze e-mail als je dit niet hebt aangevraagd.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Use {{registration_code}} para cadastrar {{recipient_email}} no {{site_name}} dentro de {{expires_in_minutes}} minutos. Ignore este e-mail se você não fez a solicitação.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "请在{{expires_in_minutes}}分钟内使用{{registration_code}}在{{site_name}}注册{{recipient_email}}。如果并非您本人请求，请忽略此邮件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('a14ab2bb-fccc-5929-be65-3dbe7292ee2b', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "請在{{expires_in_minutes}}分鐘內使用{{registration_code}}在{{site_name}}註冊{{recipient_email}}。若非您本人要求，請忽略此郵件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}، أصبحت سياسة خصوصية {{site_name}} المحدّثة سارية الآن. قراءتها: {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, die aktualisierte Datenschutzrichtlinie von {{site_name}} gilt jetzt. Lesen: {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, the updated {{site_name}} privacy policy is now effective. Read the current policy at {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, la política de privacidad actualizada de {{site_name}} ya está vigente. Consúltala: {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, la politique de confidentialité mise à jour de {{site_name}} est désormais en vigueur. Consultez-la : {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, l’informativa sulla privacy aggiornata di {{site_name}} è ora in vigore. Leggila: {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}様、{{site_name}}の新しいプライバシーポリシーが発効しました。確認: {{privacy_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}님, {{site_name}}의 새 개인정보 처리방침이 적용되었습니다. 확인: {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, het bijgewerkte privacybeleid van {{site_name}} is nu van kracht. Lezen: {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, a política de privacidade atualizada do {{site_name}} já está em vigor. Leia: {{privacy_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}，{{site_name}}的新隐私政策现已生效。查看：{{privacy_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('bf2412d0-2e16-5ad4-8ef0-36c35c8038fe', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}，{{site_name}}的新隱私權政策現已生效。查看：{{privacy_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}، أصبحت شروط {{site_name}} المحدّثة سارية الآن. قراءتها: {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, die aktualisierten Bedingungen von {{site_name}} gelten jetzt. Lesen: {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, the updated {{site_name}} terms are now effective. Read the current terms at {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, los términos actualizados de {{site_name}} ya están vigentes. Consúltalos: {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, les conditions mises à jour de {{site_name}} sont désormais en vigueur. Consultez-les : {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, i termini aggiornati di {{site_name}} sono ora in vigore. Leggili: {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}様、{{site_name}}の新しい利用規約が発効しました。確認: {{terms_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}님, {{site_name}}의 새 이용약관이 적용되었습니다. 확인: {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, de bijgewerkte voorwaarden van {{site_name}} zijn nu van kracht. Lezen: {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, os termos atualizados do {{site_name}} já estão em vigor. Leia: {{terms_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}，{{site_name}}的新条款现已生效。查看：{{terms_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c4d96259-617c-52ac-bb7e-c86f1e49e09e', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}，{{site_name}}的新條款現已生效。查看：{{terms_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('c7373687-5476-5c2e-ab3e-946dc046bed1', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{provider}} social sign-in was removed from your account.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "استخدم {{login_code}} لتسجيل الدخول إلى {{site_name}} باسم {{recipient_email}} خلال {{expires_in_minutes}} دقيقة. تجاهل هذه الرسالة إذا لم تطلبها.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Verwenden Sie {{login_code}}, um sich innerhalb von {{expires_in_minutes}} Minuten als {{recipient_email}} bei {{site_name}} anzumelden. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Use code {{login_code}} to sign in to {{site_name}} as {{recipient_email}} within {{expires_in_minutes}} minutes. If you did not request this code, ignore this email.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Usa {{login_code}} para entrar en {{site_name}} como {{recipient_email}} durante los próximos {{expires_in_minutes}} minutos. Ignora este correo si no lo solicitaste.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Utilisez {{login_code}} pour vous connecter à {{site_name}} avec {{recipient_email}} dans les {{expires_in_minutes}} prochaines minutes. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Usa {{login_code}} per accedere a {{site_name}} come {{recipient_email}} entro {{expires_in_minutes}} minuti. Ignora questa e-mail se non hai fatto la richiesta.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{expires_in_minutes}}分以内に{{login_code}}を使って{{recipient_email}}として{{site_name}}にログインしてください。心当たりがない場合はこのメールを無視してください。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{expires_in_minutes}}분 이내에 {{login_code}} 코드를 사용하여 {{recipient_email}} 계정으로 {{site_name}}에 로그인하세요. 요청하지 않았다면 이 이메일을 무시하세요.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Gebruik {{login_code}} om binnen {{expires_in_minutes}} minuten als {{recipient_email}} bij {{site_name}} in te loggen. Negeer deze e-mail als je dit niet hebt aangevraagd.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Use {{login_code}} para entrar no {{site_name}} como {{recipient_email}} dentro de {{expires_in_minutes}} minutos. Ignore este e-mail se você não fez a solicitação.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "请在{{expires_in_minutes}}分钟内使用{{login_code}}以{{recipient_email}}身份登录{{site_name}}。如果并非您本人请求，请忽略此邮件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cd69514e-9a53-5b20-a124-a69caf2873fc', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "請在{{expires_in_minutes}}分鐘內使用{{login_code}}以{{recipient_email}}身分登入{{site_name}}。若非您本人要求，請忽略此郵件。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "مرحبًا {{name}}. سيُحذف حسابك في {{scheduled_date}} بعد مهلة قدرها {{grace_period}}. الإلغاء: {{cancel_url}}. الاسترداد: {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Ihr Konto wird nach einer Frist von {{grace_period}} am {{scheduled_date}} gelöscht. Abbrechen: {{cancel_url}}. Wiederherstellen: {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hello {{name}}. Your account is scheduled for deletion on {{scheduled_date}} after the {{grace_period}} grace period. Cancel deletion at {{cancel_url}} or start account recovery at {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hola, {{name}}. Tu cuenta se eliminará el {{scheduled_date}} tras un periodo de gracia de {{grace_period}}. Cancelar: {{cancel_url}}. Recuperar: {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Bonjour {{name}}. Votre compte sera supprimé le {{scheduled_date}} après un délai de grâce de {{grace_period}}. Annuler : {{cancel_url}}. Récupérer : {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Ciao {{name}}. Il tuo account verrà eliminato il {{scheduled_date}} dopo un periodo di tolleranza di {{grace_period}}. Annulla: {{cancel_url}}. Recupera: {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}さん、アカウントは{{grace_period}}の猶予期間後、{{scheduled_date}}に削除されます。キャンセル: {{cancel_url}}。復旧: {{recover_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}님, 계정은 {{grace_period}}의 유예 기간 후 {{scheduled_date}}에 삭제됩니다. 취소: {{cancel_url}}. 복구: {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Je account wordt na een bedenktijd van {{grace_period}} op {{scheduled_date}} verwijderd. Annuleren: {{cancel_url}}. Herstellen: {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Olá, {{name}}. Sua conta será excluída em {{scheduled_date}} após um período de carência de {{grace_period}}. Cancelar: {{cancel_url}}. Recuperar: {{recover_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，您的账户将在{{grace_period}}宽限期后于{{scheduled_date}}删除。取消：{{cancel_url}}。恢复：{{recover_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('cfc5daa6-2e0f-5c9a-9791-83998c3216df', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，您的帳戶將在{{grace_period}}寬限期後於{{scheduled_date}}刪除。取消：{{cancel_url}}。復原：{{recover_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}، تسري شروط {{site_name}} المحدّثة في {{effective_date}}. المعاينة: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, die aktualisierten Bedingungen von {{site_name}} gelten ab dem {{effective_date}}. Vorschau: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, the updated {{site_name}} terms take effect on {{effective_date}}. Review the changes before then at {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, los términos actualizados de {{site_name}} entran en vigor el {{effective_date}}. Vista previa: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, les conditions mises à jour de {{site_name}} entreront en vigueur le {{effective_date}}. Aperçu : {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, i termini aggiornati di {{site_name}} entreranno in vigore il {{effective_date}}. Anteprima: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}様、{{site_name}}の新しい利用規約は{{effective_date}}に発効します。プレビュー: {{preview_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}님, {{site_name}}의 새 이용약관은 {{effective_date}}부터 적용됩니다. 미리보기: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, de bijgewerkte voorwaarden van {{site_name}} gaan in op {{effective_date}}. Voorbeeld: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, os termos atualizados do {{site_name}} entram em vigor em {{effective_date}}. Prévia: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}，{{site_name}}的新条款将于{{effective_date}}生效。预览：{{preview_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('d777790e-12d3-5b2c-90b2-fef9ff25d9fd', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}，{{site_name}}的新條款將於{{effective_date}}生效。預覽：{{preview_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}، تسري سياسة خصوصية {{site_name}} المحدّثة في {{effective_date}}. المعاينة: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, die aktualisierte Datenschutzrichtlinie von {{site_name}} gilt ab dem {{effective_date}}. Vorschau: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, the updated {{site_name}} privacy policy takes effect on {{effective_date}}. Review the changes before then at {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, la política de privacidad actualizada de {{site_name}} entra en vigor el {{effective_date}}. Vista previa: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, la politique de confidentialité mise à jour de {{site_name}} entrera en vigueur le {{effective_date}}. Aperçu : {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, l’informativa sulla privacy aggiornata di {{site_name}} entrerà in vigore il {{effective_date}}. Anteprima: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}様、{{site_name}}の新しいプライバシーポリシーは{{effective_date}}に発効します。プレビュー: {{preview_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}님, {{site_name}}의 새 개인정보 처리방침은 {{effective_date}}부터 적용됩니다. 미리보기: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, het bijgewerkte privacybeleid van {{site_name}} gaat in op {{effective_date}}. Voorbeeld: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}, a política de privacidade atualizada do {{site_name}} entra em vigor em {{effective_date}}. Prévia: {{preview_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}，{{site_name}}的新隐私政策将于{{effective_date}}生效。预览：{{preview_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ddbac35c-c7b5-50d2-b97a-4410bfbb3a66', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{recipient_email}}，{{site_name}}的新隱私權政策將於{{effective_date}}生效。預覽：{{preview_url}}。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('eaa95d1c-9a6a-5888-8c68-a35036b2be74', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{provider}} social sign-in was added to your account.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'ar', '{"paragraph": {"props": {}, "content": [{"text": {"text": "مرحبًا {{name}}. أُلغي طلب حذف حسابك. تسجيل الدخول: {{login_url}}. سيبقى حسابك نشطًا.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'de', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Ihr Löschauftrag wurde abgebrochen. Anmelden: {{login_url}}. Ihr Konto bleibt aktiv.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'en', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hello {{name}}. Your scheduled account deletion was cancelled and your account remains active. Sign in at {{login_url}}.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'es', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hola, {{name}}. Se canceló tu solicitud de eliminación. Iniciar sesión: {{login_url}}. Tu cuenta sigue activa.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'fr', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Bonjour {{name}}. Votre demande de suppression a été annulée. Connexion : {{login_url}}. Votre compte reste actif.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'it', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Ciao {{name}}. La richiesta di eliminazione è stata annullata. Accedi: {{login_url}}. Il tuo account resta attivo.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'ja', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}さん、アカウント削除のリクエストはキャンセルされました。ログイン: {{login_url}}。 アカウントは引き続き有効です。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'ko', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}님, 계정 삭제 요청이 취소되었습니다. 로그인: {{login_url}}. 계정은 계속 활성 상태입니다.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'nl', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Hallo {{name}}. Je verzoek tot verwijdering is geannuleerd. Inloggen: {{login_url}}. Je account blijft actief.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'pt-BR', '{"paragraph": {"props": {}, "content": [{"text": {"text": "Olá, {{name}}. Sua solicitação de exclusão foi cancelada. Entrar: {{login_url}}. Sua conta continua ativa.", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'zh-CN', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，您的账户删除请求已取消。登录：{{login_url}}。 您的账户仍处于启用状态。", "styles": {}}}]}}');
INSERT INTO public.content_block_locale (block_id, locale, localized_data) VALUES ('ed70a317-9278-51d8-b5ee-d860b56e1516', 'zh-TW', '{"paragraph": {"props": {}, "content": [{"text": {"text": "{{name}}，您的帳戶刪除要求已取消。登入：{{login_url}}。 您的帳戶仍維持啟用狀態。", "styles": {}}}]}}');


--
-- Data for Name: country; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.country (code, name, native_name) VALUES ('AD', 'Andorra', 'Andorra');
INSERT INTO public.country (code, name, native_name) VALUES ('AE', 'United Arab Emirates', 'الإمارات العربية المتحدة');
INSERT INTO public.country (code, name, native_name) VALUES ('AF', 'Afghanistan', 'افغانستان');
INSERT INTO public.country (code, name, native_name) VALUES ('AG', 'Antigua & Barbuda', 'Antigua & Barbuda');
INSERT INTO public.country (code, name, native_name) VALUES ('AI', 'Anguilla', 'Anguilla');
INSERT INTO public.country (code, name, native_name) VALUES ('AL', 'Albania', 'Shqipëri');
INSERT INTO public.country (code, name, native_name) VALUES ('AM', 'Armenia', 'Հայաստան');
INSERT INTO public.country (code, name, native_name) VALUES ('AO', 'Angola', 'Angola');
INSERT INTO public.country (code, name, native_name) VALUES ('AQ', 'Antarctica', 'Antarctica');
INSERT INTO public.country (code, name, native_name) VALUES ('AR', 'Argentina', 'Argentina');
INSERT INTO public.country (code, name, native_name) VALUES ('AS', 'American Samoa', 'American Samoa');
INSERT INTO public.country (code, name, native_name) VALUES ('AT', 'Austria', 'Österreich');
INSERT INTO public.country (code, name, native_name) VALUES ('AU', 'Australia', 'Australia');
INSERT INTO public.country (code, name, native_name) VALUES ('AW', 'Aruba', 'Aruba');
INSERT INTO public.country (code, name, native_name) VALUES ('AX', 'Åland Islands', 'Åland');
INSERT INTO public.country (code, name, native_name) VALUES ('AZ', 'Azerbaijan', 'Azərbaycan');
INSERT INTO public.country (code, name, native_name) VALUES ('BA', 'Bosnia & Herzegovina', 'Босна и Херцеговина');
INSERT INTO public.country (code, name, native_name) VALUES ('BB', 'Barbados', 'Barbados');
INSERT INTO public.country (code, name, native_name) VALUES ('BD', 'Bangladesh', 'বাংলাদেশ');
INSERT INTO public.country (code, name, native_name) VALUES ('BE', 'Belgium', 'België');
INSERT INTO public.country (code, name, native_name) VALUES ('BF', 'Burkina Faso', 'Burkina Faso');
INSERT INTO public.country (code, name, native_name) VALUES ('BG', 'Bulgaria', 'България');
INSERT INTO public.country (code, name, native_name) VALUES ('BH', 'Bahrain', 'البحرين');
INSERT INTO public.country (code, name, native_name) VALUES ('BI', 'Burundi', 'Uburundi');
INSERT INTO public.country (code, name, native_name) VALUES ('BJ', 'Benin', 'Bénin');
INSERT INTO public.country (code, name, native_name) VALUES ('BL', 'St. Barthélemy', 'Saint-Barthélemy');
INSERT INTO public.country (code, name, native_name) VALUES ('BM', 'Bermuda', 'Bermuda');
INSERT INTO public.country (code, name, native_name) VALUES ('BN', 'Brunei', 'Brunei');
INSERT INTO public.country (code, name, native_name) VALUES ('BO', 'Bolivia', 'Bolivia');
INSERT INTO public.country (code, name, native_name) VALUES ('BQ', 'Caribbean Netherlands', 'Caribisch Nederland');
INSERT INTO public.country (code, name, native_name) VALUES ('BR', 'Brazil', 'Brasil');
INSERT INTO public.country (code, name, native_name) VALUES ('BS', 'Bahamas', 'Bahamas');
INSERT INTO public.country (code, name, native_name) VALUES ('BT', 'Bhutan', 'འབྲུག');
INSERT INTO public.country (code, name, native_name) VALUES ('BV', 'Bouvet Island', 'Bouvetøya');
INSERT INTO public.country (code, name, native_name) VALUES ('BW', 'Botswana', 'Botswana');
INSERT INTO public.country (code, name, native_name) VALUES ('BY', 'Belarus', 'Беларусь');
INSERT INTO public.country (code, name, native_name) VALUES ('BZ', 'Belize', 'Belize');
INSERT INTO public.country (code, name, native_name) VALUES ('CA', 'Canada', 'Canada');
INSERT INTO public.country (code, name, native_name) VALUES ('CC', 'Cocos (Keeling) Islands', 'Cocos (Keeling) Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('CD', 'Congo - Kinshasa', 'Congo-Kinshasa');
INSERT INTO public.country (code, name, native_name) VALUES ('CF', 'Central African Republic', 'Ködörösêse tî Bêafrîka');
INSERT INTO public.country (code, name, native_name) VALUES ('CG', 'Congo - Brazzaville', 'Congo-Brazzaville');
INSERT INTO public.country (code, name, native_name) VALUES ('CH', 'Switzerland', 'Schweiz');
INSERT INTO public.country (code, name, native_name) VALUES ('CI', 'Côte d’Ivoire', 'Côte d’Ivoire');
INSERT INTO public.country (code, name, native_name) VALUES ('CK', 'Cook Islands', 'Cook Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('CL', 'Chile', 'Chile');
INSERT INTO public.country (code, name, native_name) VALUES ('CM', 'Cameroon', 'Cameroun');
INSERT INTO public.country (code, name, native_name) VALUES ('CN', 'China', '中国');
INSERT INTO public.country (code, name, native_name) VALUES ('CO', 'Colombia', 'Colombia');
INSERT INTO public.country (code, name, native_name) VALUES ('CR', 'Costa Rica', 'Costa Rica');
INSERT INTO public.country (code, name, native_name) VALUES ('CU', 'Cuba', 'Cuba');
INSERT INTO public.country (code, name, native_name) VALUES ('CV', 'Cape Verde', 'Cabo Verde');
INSERT INTO public.country (code, name, native_name) VALUES ('CW', 'Curaçao', 'Kòrsou');
INSERT INTO public.country (code, name, native_name) VALUES ('CX', 'Christmas Island', 'Christmas Island');
INSERT INTO public.country (code, name, native_name) VALUES ('CY', 'Cyprus', 'Κύπρος');
INSERT INTO public.country (code, name, native_name) VALUES ('CZ', 'Czechia', 'Česko');
INSERT INTO public.country (code, name, native_name) VALUES ('DE', 'Germany', 'Deutschland');
INSERT INTO public.country (code, name, native_name) VALUES ('DJ', 'Djibouti', 'Djibouti');
INSERT INTO public.country (code, name, native_name) VALUES ('DK', 'Denmark', 'Danmark');
INSERT INTO public.country (code, name, native_name) VALUES ('DM', 'Dominica', 'Dominica');
INSERT INTO public.country (code, name, native_name) VALUES ('DO', 'Dominican Republic', 'República Dominicana');
INSERT INTO public.country (code, name, native_name) VALUES ('DZ', 'Algeria', 'الجزائر');
INSERT INTO public.country (code, name, native_name) VALUES ('EC', 'Ecuador', 'Ecuador');
INSERT INTO public.country (code, name, native_name) VALUES ('EE', 'Estonia', 'Eesti');
INSERT INTO public.country (code, name, native_name) VALUES ('EG', 'Egypt', 'مصر');
INSERT INTO public.country (code, name, native_name) VALUES ('EH', 'Western Sahara', 'الصحراء الغربية');
INSERT INTO public.country (code, name, native_name) VALUES ('ER', 'Eritrea', 'ኤርትራ');
INSERT INTO public.country (code, name, native_name) VALUES ('ES', 'Spain', 'España');
INSERT INTO public.country (code, name, native_name) VALUES ('ET', 'Ethiopia', 'ኢትዮጵያ');
INSERT INTO public.country (code, name, native_name) VALUES ('FI', 'Finland', 'Suomi');
INSERT INTO public.country (code, name, native_name) VALUES ('FJ', 'Fiji', 'Fiji');
INSERT INTO public.country (code, name, native_name) VALUES ('FK', 'Falkland Islands', 'Falkland Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('FM', 'Micronesia', 'Micronesia');
INSERT INTO public.country (code, name, native_name) VALUES ('FO', 'Faroe Islands', 'Føroyar');
INSERT INTO public.country (code, name, native_name) VALUES ('FR', 'France', 'France');
INSERT INTO public.country (code, name, native_name) VALUES ('GA', 'Gabon', 'Gabon');
INSERT INTO public.country (code, name, native_name) VALUES ('GB', 'United Kingdom', 'United Kingdom');
INSERT INTO public.country (code, name, native_name) VALUES ('GD', 'Grenada', 'Grenada');
INSERT INTO public.country (code, name, native_name) VALUES ('GE', 'Georgia', 'საქართველო');
INSERT INTO public.country (code, name, native_name) VALUES ('GF', 'French Guiana', 'Guyane française');
INSERT INTO public.country (code, name, native_name) VALUES ('GG', 'Guernsey', 'Guernsey');
INSERT INTO public.country (code, name, native_name) VALUES ('GH', 'Ghana', 'Ghana');
INSERT INTO public.country (code, name, native_name) VALUES ('GI', 'Gibraltar', 'Gibraltar');
INSERT INTO public.country (code, name, native_name) VALUES ('GL', 'Greenland', 'Kalaallit Nunaat');
INSERT INTO public.country (code, name, native_name) VALUES ('GM', 'Gambia', 'Gambia');
INSERT INTO public.country (code, name, native_name) VALUES ('GN', 'Guinea', 'Guinée');
INSERT INTO public.country (code, name, native_name) VALUES ('GP', 'Guadeloupe', 'Guadeloupe');
INSERT INTO public.country (code, name, native_name) VALUES ('GQ', 'Equatorial Guinea', 'Guinea Ecuatorial');
INSERT INTO public.country (code, name, native_name) VALUES ('GR', 'Greece', 'Ελλάδα');
INSERT INTO public.country (code, name, native_name) VALUES ('GS', 'South Georgia & South Sandwich Islands', 'South Georgia & South Sandwich Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('GT', 'Guatemala', 'Guatemala');
INSERT INTO public.country (code, name, native_name) VALUES ('GU', 'Guam', 'Guam');
INSERT INTO public.country (code, name, native_name) VALUES ('GW', 'Guinea-Bissau', 'Guiné-Bissau');
INSERT INTO public.country (code, name, native_name) VALUES ('GY', 'Guyana', 'Guyana');
INSERT INTO public.country (code, name, native_name) VALUES ('HK', 'Hong Kong', '香港');
INSERT INTO public.country (code, name, native_name) VALUES ('HM', 'Heard & McDonald Islands', 'Heard & McDonald Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('HN', 'Honduras', 'Honduras');
INSERT INTO public.country (code, name, native_name) VALUES ('HR', 'Croatia', 'Hrvatska');
INSERT INTO public.country (code, name, native_name) VALUES ('HT', 'Haiti', 'Haïti');
INSERT INTO public.country (code, name, native_name) VALUES ('HU', 'Hungary', 'Magyarország');
INSERT INTO public.country (code, name, native_name) VALUES ('ID', 'Indonesia', 'Indonesia');
INSERT INTO public.country (code, name, native_name) VALUES ('IE', 'Ireland', 'Ireland');
INSERT INTO public.country (code, name, native_name) VALUES ('IL', 'Israel', 'ישראל');
INSERT INTO public.country (code, name, native_name) VALUES ('IM', 'Isle of Man', 'Isle of Man');
INSERT INTO public.country (code, name, native_name) VALUES ('IN', 'India', 'भारत');
INSERT INTO public.country (code, name, native_name) VALUES ('IO', 'British Indian Ocean Territory', 'British Indian Ocean Territory');
INSERT INTO public.country (code, name, native_name) VALUES ('IQ', 'Iraq', 'العراق');
INSERT INTO public.country (code, name, native_name) VALUES ('IR', 'Iran', 'ایران');
INSERT INTO public.country (code, name, native_name) VALUES ('IS', 'Iceland', 'Ísland');
INSERT INTO public.country (code, name, native_name) VALUES ('IT', 'Italy', 'Italia');
INSERT INTO public.country (code, name, native_name) VALUES ('JE', 'Jersey', 'Jersey');
INSERT INTO public.country (code, name, native_name) VALUES ('JM', 'Jamaica', 'Jamaica');
INSERT INTO public.country (code, name, native_name) VALUES ('JO', 'Jordan', 'الأردن');
INSERT INTO public.country (code, name, native_name) VALUES ('JP', 'Japan', '日本');
INSERT INTO public.country (code, name, native_name) VALUES ('KE', 'Kenya', 'Kenya');
INSERT INTO public.country (code, name, native_name) VALUES ('KG', 'Kyrgyzstan', 'Кыргызстан');
INSERT INTO public.country (code, name, native_name) VALUES ('KH', 'Cambodia', 'កម្ពុជា');
INSERT INTO public.country (code, name, native_name) VALUES ('KI', 'Kiribati', 'Kiribati');
INSERT INTO public.country (code, name, native_name) VALUES ('KM', 'Comoros', 'جزر القمر');
INSERT INTO public.country (code, name, native_name) VALUES ('KN', 'St. Kitts & Nevis', 'St. Kitts & Nevis');
INSERT INTO public.country (code, name, native_name) VALUES ('KP', 'North Korea', '북한');
INSERT INTO public.country (code, name, native_name) VALUES ('KR', 'South Korea', '대한민국');
INSERT INTO public.country (code, name, native_name) VALUES ('KW', 'Kuwait', 'الكويت');
INSERT INTO public.country (code, name, native_name) VALUES ('KY', 'Cayman Islands', 'Cayman Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('KZ', 'Kazakhstan', 'Казахстан');
INSERT INTO public.country (code, name, native_name) VALUES ('LA', 'Laos', 'ລາວ');
INSERT INTO public.country (code, name, native_name) VALUES ('LB', 'Lebanon', 'لبنان');
INSERT INTO public.country (code, name, native_name) VALUES ('LC', 'St. Lucia', 'St. Lucia');
INSERT INTO public.country (code, name, native_name) VALUES ('LI', 'Liechtenstein', 'Liechtenstein');
INSERT INTO public.country (code, name, native_name) VALUES ('LK', 'Sri Lanka', 'ශ්‍රී ලංකාව');
INSERT INTO public.country (code, name, native_name) VALUES ('LR', 'Liberia', 'Liberia');
INSERT INTO public.country (code, name, native_name) VALUES ('LS', 'Lesotho', 'Lesotho');
INSERT INTO public.country (code, name, native_name) VALUES ('LT', 'Lithuania', 'Lietuva');
INSERT INTO public.country (code, name, native_name) VALUES ('LU', 'Luxembourg', 'Luxembourg');
INSERT INTO public.country (code, name, native_name) VALUES ('LV', 'Latvia', 'Latvija');
INSERT INTO public.country (code, name, native_name) VALUES ('LY', 'Libya', 'ليبيا');
INSERT INTO public.country (code, name, native_name) VALUES ('MA', 'Morocco', 'المغرب');
INSERT INTO public.country (code, name, native_name) VALUES ('MC', 'Monaco', 'Monaco');
INSERT INTO public.country (code, name, native_name) VALUES ('MD', 'Moldova', 'Republica Moldova');
INSERT INTO public.country (code, name, native_name) VALUES ('ME', 'Montenegro', 'Crna Gora');
INSERT INTO public.country (code, name, native_name) VALUES ('MF', 'St. Martin', 'Saint-Martin');
INSERT INTO public.country (code, name, native_name) VALUES ('MG', 'Madagascar', 'Madagasikara');
INSERT INTO public.country (code, name, native_name) VALUES ('MH', 'Marshall Islands', 'Marshall Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('MK', 'North Macedonia', 'Северна Македонија');
INSERT INTO public.country (code, name, native_name) VALUES ('ML', 'Mali', 'Mali');
INSERT INTO public.country (code, name, native_name) VALUES ('MM', 'Myanmar (Burma)', 'မြန်မာ');
INSERT INTO public.country (code, name, native_name) VALUES ('MN', 'Mongolia', 'Монгол');
INSERT INTO public.country (code, name, native_name) VALUES ('MO', 'Macao', '澳門');
INSERT INTO public.country (code, name, native_name) VALUES ('MP', 'Northern Mariana Islands', 'Northern Mariana Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('MQ', 'Martinique', 'Martinique');
INSERT INTO public.country (code, name, native_name) VALUES ('MR', 'Mauritania', 'موريتانيا');
INSERT INTO public.country (code, name, native_name) VALUES ('MS', 'Montserrat', 'Montserrat');
INSERT INTO public.country (code, name, native_name) VALUES ('MT', 'Malta', 'Malta');
INSERT INTO public.country (code, name, native_name) VALUES ('MU', 'Mauritius', 'Maurice');
INSERT INTO public.country (code, name, native_name) VALUES ('MV', 'Maldives', 'Maldives');
INSERT INTO public.country (code, name, native_name) VALUES ('MW', 'Malawi', 'Malawi');
INSERT INTO public.country (code, name, native_name) VALUES ('MX', 'Mexico', 'México');
INSERT INTO public.country (code, name, native_name) VALUES ('MY', 'Malaysia', 'Malaysia');
INSERT INTO public.country (code, name, native_name) VALUES ('MZ', 'Mozambique', 'Moçambique');
INSERT INTO public.country (code, name, native_name) VALUES ('NA', 'Namibia', 'Namibia');
INSERT INTO public.country (code, name, native_name) VALUES ('NC', 'New Caledonia', 'Nouvelle-Calédonie');
INSERT INTO public.country (code, name, native_name) VALUES ('NE', 'Niger', 'Niger');
INSERT INTO public.country (code, name, native_name) VALUES ('NF', 'Norfolk Island', 'Norfolk Island');
INSERT INTO public.country (code, name, native_name) VALUES ('NG', 'Nigeria', 'Nigeria');
INSERT INTO public.country (code, name, native_name) VALUES ('NI', 'Nicaragua', 'Nicaragua');
INSERT INTO public.country (code, name, native_name) VALUES ('NL', 'Netherlands', 'Nederland');
INSERT INTO public.country (code, name, native_name) VALUES ('NO', 'Norway', 'Norge');
INSERT INTO public.country (code, name, native_name) VALUES ('NP', 'Nepal', 'नेपाल');
INSERT INTO public.country (code, name, native_name) VALUES ('NR', 'Nauru', 'Nauru');
INSERT INTO public.country (code, name, native_name) VALUES ('NU', 'Niue', 'Niue');
INSERT INTO public.country (code, name, native_name) VALUES ('NZ', 'New Zealand', 'New Zealand');
INSERT INTO public.country (code, name, native_name) VALUES ('OM', 'Oman', 'عُمان');
INSERT INTO public.country (code, name, native_name) VALUES ('PA', 'Panama', 'Panamá');
INSERT INTO public.country (code, name, native_name) VALUES ('PE', 'Peru', 'Perú');
INSERT INTO public.country (code, name, native_name) VALUES ('PF', 'French Polynesia', 'Polynésie française');
INSERT INTO public.country (code, name, native_name) VALUES ('PG', 'Papua New Guinea', 'Papua Niugini');
INSERT INTO public.country (code, name, native_name) VALUES ('PH', 'Philippines', 'Philippines');
INSERT INTO public.country (code, name, native_name) VALUES ('PK', 'Pakistan', 'پاکستان');
INSERT INTO public.country (code, name, native_name) VALUES ('PL', 'Poland', 'Polska');
INSERT INTO public.country (code, name, native_name) VALUES ('PM', 'St. Pierre & Miquelon', 'Saint-Pierre-et-Miquelon');
INSERT INTO public.country (code, name, native_name) VALUES ('PN', 'Pitcairn Islands', 'Pitcairn Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('PR', 'Puerto Rico', 'Puerto Rico');
INSERT INTO public.country (code, name, native_name) VALUES ('PS', 'Palestine', 'فلسطين');
INSERT INTO public.country (code, name, native_name) VALUES ('PT', 'Portugal', 'Portugal');
INSERT INTO public.country (code, name, native_name) VALUES ('PW', 'Palau', 'Palau');
INSERT INTO public.country (code, name, native_name) VALUES ('PY', 'Paraguay', 'Paraguay');
INSERT INTO public.country (code, name, native_name) VALUES ('QA', 'Qatar', 'قطر');
INSERT INTO public.country (code, name, native_name) VALUES ('RE', 'Réunion', 'La Réunion');
INSERT INTO public.country (code, name, native_name) VALUES ('RO', 'Romania', 'România');
INSERT INTO public.country (code, name, native_name) VALUES ('RS', 'Serbia', 'Srbija');
INSERT INTO public.country (code, name, native_name) VALUES ('RU', 'Russia', 'Россия');
INSERT INTO public.country (code, name, native_name) VALUES ('RW', 'Rwanda', 'U Rwanda');
INSERT INTO public.country (code, name, native_name) VALUES ('SA', 'Saudi Arabia', 'المملكة العربية السعودية');
INSERT INTO public.country (code, name, native_name) VALUES ('SB', 'Solomon Islands', 'Solomon Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('SC', 'Seychelles', 'Seychelles');
INSERT INTO public.country (code, name, native_name) VALUES ('SD', 'Sudan', 'السودان');
INSERT INTO public.country (code, name, native_name) VALUES ('SE', 'Sweden', 'Sverige');
INSERT INTO public.country (code, name, native_name) VALUES ('SG', 'Singapore', 'Singapore');
INSERT INTO public.country (code, name, native_name) VALUES ('SH', 'St. Helena', 'St. Helena');
INSERT INTO public.country (code, name, native_name) VALUES ('SI', 'Slovenia', 'Slovenija');
INSERT INTO public.country (code, name, native_name) VALUES ('SJ', 'Svalbard & Jan Mayen', 'Svalbard og Jan Mayen');
INSERT INTO public.country (code, name, native_name) VALUES ('SK', 'Slovakia', 'Slovensko');
INSERT INTO public.country (code, name, native_name) VALUES ('SL', 'Sierra Leone', 'Sierra Leone');
INSERT INTO public.country (code, name, native_name) VALUES ('SM', 'San Marino', 'San Marino');
INSERT INTO public.country (code, name, native_name) VALUES ('SN', 'Senegal', 'Senegaal');
INSERT INTO public.country (code, name, native_name) VALUES ('SO', 'Somalia', 'Soomaaliya');
INSERT INTO public.country (code, name, native_name) VALUES ('SR', 'Suriname', 'Suriname');
INSERT INTO public.country (code, name, native_name) VALUES ('SS', 'South Sudan', 'South Sudan');
INSERT INTO public.country (code, name, native_name) VALUES ('ST', 'São Tomé & Príncipe', 'São Tomé e Príncipe');
INSERT INTO public.country (code, name, native_name) VALUES ('SV', 'El Salvador', 'El Salvador');
INSERT INTO public.country (code, name, native_name) VALUES ('SX', 'Sint Maarten', 'Sint Maarten');
INSERT INTO public.country (code, name, native_name) VALUES ('SY', 'Syria', 'سوريا');
INSERT INTO public.country (code, name, native_name) VALUES ('SZ', 'Eswatini', 'Eswatini');
INSERT INTO public.country (code, name, native_name) VALUES ('TC', 'Turks & Caicos Islands', 'Turks & Caicos Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('TD', 'Chad', 'تشاد');
INSERT INTO public.country (code, name, native_name) VALUES ('TF', 'French Southern Territories', 'Terres australes françaises');
INSERT INTO public.country (code, name, native_name) VALUES ('TG', 'Togo', 'Togo');
INSERT INTO public.country (code, name, native_name) VALUES ('TH', 'Thailand', 'ไทย');
INSERT INTO public.country (code, name, native_name) VALUES ('TJ', 'Tajikistan', 'Тоҷикистон');
INSERT INTO public.country (code, name, native_name) VALUES ('TK', 'Tokelau', 'Tokelau');
INSERT INTO public.country (code, name, native_name) VALUES ('TL', 'Timor-Leste', 'Timor-Leste');
INSERT INTO public.country (code, name, native_name) VALUES ('TM', 'Turkmenistan', 'Türkmenistan');
INSERT INTO public.country (code, name, native_name) VALUES ('TN', 'Tunisia', 'تونس');
INSERT INTO public.country (code, name, native_name) VALUES ('TO', 'Tonga', 'Tonga');
INSERT INTO public.country (code, name, native_name) VALUES ('TR', 'Türkiye', 'Türkiye');
INSERT INTO public.country (code, name, native_name) VALUES ('TT', 'Trinidad & Tobago', 'Trinidad & Tobago');
INSERT INTO public.country (code, name, native_name) VALUES ('TV', 'Tuvalu', 'Tuvalu');
INSERT INTO public.country (code, name, native_name) VALUES ('TW', 'Taiwan', '台灣');
INSERT INTO public.country (code, name, native_name) VALUES ('TZ', 'Tanzania', 'Tanzania');
INSERT INTO public.country (code, name, native_name) VALUES ('UA', 'Ukraine', 'Україна');
INSERT INTO public.country (code, name, native_name) VALUES ('UG', 'Uganda', 'Uganda');
INSERT INTO public.country (code, name, native_name) VALUES ('UM', 'U.S. Outlying Islands', 'U.S. Outlying Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('US', 'United States', 'United States');
INSERT INTO public.country (code, name, native_name) VALUES ('UY', 'Uruguay', 'Uruguay');
INSERT INTO public.country (code, name, native_name) VALUES ('UZ', 'Uzbekistan', 'Oʻzbekiston');
INSERT INTO public.country (code, name, native_name) VALUES ('VA', 'Vatican City', 'Città del Vaticano');
INSERT INTO public.country (code, name, native_name) VALUES ('VC', 'St. Vincent & Grenadines', 'St. Vincent & Grenadines');
INSERT INTO public.country (code, name, native_name) VALUES ('VE', 'Venezuela', 'Venezuela');
INSERT INTO public.country (code, name, native_name) VALUES ('VG', 'British Virgin Islands', 'British Virgin Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('VI', 'U.S. Virgin Islands', 'U.S. Virgin Islands');
INSERT INTO public.country (code, name, native_name) VALUES ('VN', 'Vietnam', 'Việt Nam');
INSERT INTO public.country (code, name, native_name) VALUES ('VU', 'Vanuatu', 'Vanuatu');
INSERT INTO public.country (code, name, native_name) VALUES ('WF', 'Wallis & Futuna', 'Wallis-et-Futuna');
INSERT INTO public.country (code, name, native_name) VALUES ('WS', 'Samoa', 'Samoa');
INSERT INTO public.country (code, name, native_name) VALUES ('YE', 'Yemen', 'اليمن');
INSERT INTO public.country (code, name, native_name) VALUES ('YT', 'Mayotte', 'Mayotte');
INSERT INTO public.country (code, name, native_name) VALUES ('ZA', 'South Africa', 'South Africa');
INSERT INTO public.country (code, name, native_name) VALUES ('ZM', 'Zambia', 'Zambia');
INSERT INTO public.country (code, name, native_name) VALUES ('ZW', 'Zimbabwe', 'Zimbabwe');


--
-- Data for Name: email_template; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'privacy_effective', 'Privacy Policy Now Effective', 'Announces that an updated privacy policy is effective', '[{"name": "recipient_email"}, {"name": "site_name"}, {"name": "privacy_url"}]', true, true, 'privacy_effective', NULL, '807ccd1a-3062-5717-ab49-be611504c41d');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'terms_update', 'Terms Update Notice', 'Announces an upcoming terms update', '[{"name": "recipient_email"}, {"name": "site_name"}, {"name": "effective_date"}, {"name": "preview_url"}, {"name": "policy_title"}]', true, true, 'terms_update', NULL, 'c597ac88-1ebb-528e-9f12-3de010c473e1');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'login_code', 'Login Code Email', 'Sends a code to sign in to an existing account', '[{"name": "login_code"}, {"name": "recipient_email"}, {"name": "site_name"}, {"name": "expires_in_minutes"}]', true, true, 'login_code', NULL, '97039fd1-1270-5e21-bbdd-5c6da12d9072');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'terms_effective', 'Terms Now Effective', 'Announces that updated terms are effective', '[{"name": "recipient_email"}, {"name": "site_name"}, {"name": "terms_url"}]', true, true, 'terms_effective', NULL, '0868b2b5-1964-57d3-8249-738e0130b960');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'account_deletion_confirm', 'Account Deletion Confirmation', 'Confirms a request to delete an account', '[{"name": "name"}, {"name": "confirm_url"}, {"name": "expires_in"}]', true, true, 'account_deletion_confirm', NULL, '588fea29-2730-574c-9585-f10910f710fa');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('4a0f4f83-0d38-4e1f-a875-64acb5de8f9e', 'account_security_change', 'Account Security Change', 'Notifies an account holder when a sign-in method changes', '[{"name": "method"}]', true, false, 'account_security_change', NULL, '934bd8c8-1114-5dc6-bd2a-d26933889321');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8001', 'primary_email_changed', 'Account Email Changed', 'Notifies the previous account email after the canonical account email changes', '[{"name": "old_email"}, {"name": "new_email"}]', true, true, 'primary_email_changed', NULL, 'a5bcd392-ffeb-567d-9d50-e93abfd81865');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8002', 'email_added', 'Email Sign-in Added', 'Notifies an account holder when an email-code address is added', '[{"name": "email"}]', true, true, 'email_added', NULL, '274f41b8-e037-560a-8695-fd4d3ac5d833');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8003', 'email_removed', 'Email Sign-in Removed', 'Notifies an account holder when an email-code address is removed', '[{"name": "email"}]', true, true, 'email_removed', NULL, 'ca373a6e-7ee1-5612-8ff0-6ec949759016');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8004', 'passkey_added', 'Passkey Added', 'Notifies an account holder when a passkey is added', '[]', true, true, 'passkey_added', NULL, '280de60d-55a7-50c2-8f60-d6f952306f56');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8005', 'passkey_removed', 'Passkey Removed', 'Notifies an account holder when a passkey is removed', '[]', true, true, 'passkey_removed', NULL, '7366d833-1d68-5890-aaca-4df7ce5d58d8');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8006', 'social_login_added', 'Social Sign-in Added', 'Notifies an account holder when a social sign-in is added', '[{"name": "provider"}]', true, true, 'social_login_added', NULL, '0541f243-1b82-5cc5-8e2c-b45b6268b0f2');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8007', 'social_login_removed', 'Social Sign-in Removed', 'Notifies an account holder when a social sign-in is removed', '[{"name": "provider"}]', true, true, 'social_login_removed', NULL, '13181ddb-e7bc-58a3-b35b-1d1381be7054');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'email_change_notification', 'Email Change Notification', 'Notifies the previous address after an email change', '[{"name": "old_email"}, {"name": "new_email"}]', true, false, 'email_change_notification', NULL, 'c5ec4cdf-94b6-5eb4-9668-77ecf3141381');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'account_recovery_complete', 'Account Recovery Complete', 'Confirms that an account was recovered', '[{"name": "name"}, {"name": "login_url"}]', true, true, 'account_recovery_complete', NULL, '6022998c-5ebd-58c9-a880-24f09210b106');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'account_deletion_scheduled', 'Account Deletion Scheduled', 'Confirms that account deletion is scheduled', '[{"name": "name"}, {"name": "scheduled_date"}, {"name": "grace_period"}, {"name": "cancel_url"}, {"name": "recover_url"}]', true, true, 'account_deletion_scheduled', NULL, 'c6757525-2503-5d06-a1c6-6b867270ce00');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'registration_code', 'Registration Code Email', 'Sends a code to verify an email before registration', '[{"name": "registration_code"}, {"name": "recipient_email"}, {"name": "site_name"}, {"name": "expires_in_minutes"}]', true, true, 'registration_code', NULL, 'f80cd929-5472-5b15-83f6-2a6e63ba582c');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'verification_code', 'Email Verification Code', 'Sends a code to verify an email address', '[{"name": "verification_code"}, {"name": "recipient_email"}, {"name": "site_name"}, {"name": "expires_in_minutes"}, {"name": "verification_url"}]', true, true, 'verification_code', NULL, '51429686-2340-5f0f-aecc-4bf3fb40ffc3');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'privacy_update', 'Privacy Policy Update Notice', 'Announces an upcoming privacy policy update', '[{"name": "recipient_email"}, {"name": "site_name"}, {"name": "effective_date"}, {"name": "preview_url"}, {"name": "policy_title"}]', true, true, 'privacy_update', NULL, '049aad1d-844a-5753-bc8a-0f91e75cdb21');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'welcome', 'Welcome', 'Welcomes a new account holder', '[{"name": "name"}, {"name": "site_name"}, {"name": "login_url"}]', true, true, 'welcome', NULL, '6a6a045d-ac55-5498-8254-fa6c4db95eb0');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'account_recovery_confirm', 'Account Recovery Confirmation', 'Confirms a request to recover an account scheduled for deletion', '[{"name": "name"}, {"name": "confirm_url"}, {"name": "expires_in"}]', true, true, 'account_recovery_confirm', NULL, '8013c80b-d997-5df1-a63c-9aaf2e052498');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'account_deletion_complete', 'Account Deletion Complete', 'Confirms that an account was permanently deleted', '[{"name": "name"}]', true, true, 'account_deletion_complete', NULL, 'd9e56cb5-ab13-528d-bcc7-aa5237801672');
INSERT INTO public.email_template (id, key, name, description, variables, is_system, is_active, event_key, layout_id, content_document_id) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'account_deletion_cancelled', 'Account Deletion Cancelled', 'Confirms that scheduled account deletion was cancelled', '[{"name": "name"}, {"name": "login_url"}]', true, true, 'account_deletion_cancelled', NULL, '43c1aa0d-0e08-57e2-a4aa-d67456c17553');


--
-- Data for Name: email_template_translation; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'ar', 'سياسة خصوصية {{site_name}} سارية الآن', '<p>{{recipient_email}}، أصبحت سياسة خصوصية {{site_name}} المحدّثة سارية الآن. قراءتها: <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}، أصبحت سياسة خصوصية {{site_name}} المحدّثة سارية الآن. قراءتها: {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'de', 'Die Datenschutzrichtlinie von {{site_name}} gilt jetzt', '<p>{{recipient_email}}, die aktualisierte Datenschutzrichtlinie von {{site_name}} gilt jetzt. Lesen: <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}, die aktualisierte Datenschutzrichtlinie von {{site_name}} gilt jetzt. Lesen: {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'en', 'The updated {{site_name}} privacy policy is now effective', '<p>{{recipient_email}}, the updated {{site_name}} privacy policy is now effective. Read the current policy at <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}, the updated {{site_name}} privacy policy is now effective. Read the current policy at {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'es', 'La política de privacidad de {{site_name}} ya está vigente', '<p>{{recipient_email}}, la política de privacidad actualizada de {{site_name}} ya está vigente. Consúltala: <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}, la política de privacidad actualizada de {{site_name}} ya está vigente. Consúltala: {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'fr', 'La politique de confidentialité de {{site_name}} est en vigueur', '<p>{{recipient_email}}, la politique de confidentialité mise à jour de {{site_name}} est désormais en vigueur. Consultez-la : <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}, la politique de confidentialité mise à jour de {{site_name}} est désormais en vigueur. Consultez-la : {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'it', 'L’informativa sulla privacy di {{site_name}} è ora in vigore', '<p>{{recipient_email}}, l’informativa sulla privacy aggiornata di {{site_name}} è ora in vigore. Leggila: <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}, l’informativa sulla privacy aggiornata di {{site_name}} è ora in vigore. Leggila: {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'ja', '{{site_name}}プライバシーポリシーが発効しました', '<p>{{recipient_email}}様、{{site_name}}の新しいプライバシーポリシーが発効しました。確認: <a href="{{privacy_url}}">{{privacy_url}}</a>。</p>', '{{recipient_email}}様、{{site_name}}の新しいプライバシーポリシーが発効しました。確認: {{privacy_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'ko', '{{site_name}} 개인정보 처리방침이 적용되었습니다', '<p>{{recipient_email}}님, {{site_name}}의 새 개인정보 처리방침이 적용되었습니다. 확인: <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}님, {{site_name}}의 새 개인정보 처리방침이 적용되었습니다. 확인: {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'nl', 'Het privacybeleid van {{site_name}} is nu van kracht', '<p>{{recipient_email}}, het bijgewerkte privacybeleid van {{site_name}} is nu van kracht. Lezen: <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}, het bijgewerkte privacybeleid van {{site_name}} is nu van kracht. Lezen: {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'pt-BR', 'A política de privacidade do {{site_name}} já está em vigor', '<p>{{recipient_email}}, a política de privacidade atualizada do {{site_name}} já está em vigor. Leia: <a href="{{privacy_url}}">{{privacy_url}}</a>.</p>', '{{recipient_email}}, a política de privacidade atualizada do {{site_name}} já está em vigor. Leia: {{privacy_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'zh-CN', '{{site_name}}隐私政策现已生效', '<p>{{recipient_email}}，{{site_name}}的新隐私政策现已生效。查看：<a href="{{privacy_url}}">{{privacy_url}}</a>。</p>', '{{recipient_email}}，{{site_name}}的新隐私政策现已生效。查看：{{privacy_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('01c7864b-a3a4-4a4c-88a6-b9f6f898f775', 'zh-TW', '{{site_name}}隱私權政策現已生效', '<p>{{recipient_email}}，{{site_name}}的新隱私權政策現已生效。查看：<a href="{{privacy_url}}">{{privacy_url}}</a>。</p>', '{{recipient_email}}，{{site_name}}的新隱私權政策現已生效。查看：{{privacy_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'ar', 'تحديث شروط {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}، تسري شروط {{site_name}} المحدّثة في {{effective_date}}. المعاينة: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}، تسري شروط {{site_name}} المحدّثة في {{effective_date}}. المعاينة: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'de', 'Aktualisierte Bedingungen von {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, die aktualisierten Bedingungen von {{site_name}} gelten ab dem {{effective_date}}. Vorschau: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, die aktualisierten Bedingungen von {{site_name}} gelten ab dem {{effective_date}}. Vorschau: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'en', 'Upcoming update to the {{site_name}} terms', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, the updated {{site_name}} terms take effect on {{effective_date}}. Review the changes before then at <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, the updated {{site_name}} terms take effect on {{effective_date}}. Review the changes before then at {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'es', 'Actualización de términos de {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, los términos actualizados de {{site_name}} entran en vigor el {{effective_date}}. Vista previa: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, los términos actualizados de {{site_name}} entran en vigor el {{effective_date}}. Vista previa: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'fr', 'Mise à jour des conditions de {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, les conditions mises à jour de {{site_name}} entreront en vigueur le {{effective_date}}. Aperçu : <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, les conditions mises à jour de {{site_name}} entreront en vigueur le {{effective_date}}. Aperçu : {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'it', 'Aggiornamento dei termini di {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, i termini aggiornati di {{site_name}} entreranno in vigore il {{effective_date}}. Anteprima: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, i termini aggiornati di {{site_name}} entreranno in vigore il {{effective_date}}. Anteprima: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'ja', '{{site_name}}利用規約の更新', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}様、{{site_name}}の新しい利用規約は{{effective_date}}に発効します。プレビュー: <a href="{{preview_url}}">{{preview_url}}</a>。</p>', '{{policy_title}}

{{recipient_email}}様、{{site_name}}の新しい利用規約は{{effective_date}}に発効します。プレビュー: {{preview_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'ko', '{{site_name}} 이용약관 업데이트', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}님, {{site_name}}의 새 이용약관은 {{effective_date}}부터 적용됩니다. 미리보기: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}님, {{site_name}}의 새 이용약관은 {{effective_date}}부터 적용됩니다. 미리보기: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'nl', 'Bijgewerkte voorwaarden van {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, de bijgewerkte voorwaarden van {{site_name}} gaan in op {{effective_date}}. Voorbeeld: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, de bijgewerkte voorwaarden van {{site_name}} gaan in op {{effective_date}}. Voorbeeld: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'pt-BR', 'Atualização dos termos do {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, os termos atualizados do {{site_name}} entram em vigor em {{effective_date}}. Prévia: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, os termos atualizados do {{site_name}} entram em vigor em {{effective_date}}. Prévia: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'zh-CN', '{{site_name}}条款更新', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}，{{site_name}}的新条款将于{{effective_date}}生效。预览：<a href="{{preview_url}}">{{preview_url}}</a>。</p>', '{{policy_title}}

{{recipient_email}}，{{site_name}}的新条款将于{{effective_date}}生效。预览：{{preview_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('09ed47a8-92d7-4b0f-96b9-d4f8d4f59750', 'zh-TW', '{{site_name}}條款更新', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}，{{site_name}}的新條款將於{{effective_date}}生效。預覽：<a href="{{preview_url}}">{{preview_url}}</a>。</p>', '{{policy_title}}

{{recipient_email}}，{{site_name}}的新條款將於{{effective_date}}生效。預覽：{{preview_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'ar', 'رمز تسجيل الدخول: {{login_code}}', '<p>استخدم <strong>{{login_code}}</strong> لتسجيل الدخول إلى {{site_name}} باسم {{recipient_email}} خلال {{expires_in_minutes}} دقيقة. تجاهل هذه الرسالة إذا لم تطلبها.</p>', 'استخدم {{login_code}} لتسجيل الدخول إلى {{site_name}} باسم {{recipient_email}} خلال {{expires_in_minutes}} دقيقة. تجاهل هذه الرسالة إذا لم تطلبها.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'de', 'Ihr Anmeldecode: {{login_code}}', '<p>Verwenden Sie <strong>{{login_code}}</strong>, um sich innerhalb von {{expires_in_minutes}} Minuten als {{recipient_email}} bei {{site_name}} anzumelden. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.</p>', 'Verwenden Sie {{login_code}}, um sich innerhalb von {{expires_in_minutes}} Minuten als {{recipient_email}} bei {{site_name}} anzumelden. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'en', 'Your login code: {{login_code}}', '<p>Use code <strong>{{login_code}}</strong> to sign in to {{site_name}} as {{recipient_email}} within {{expires_in_minutes}} minutes. If you did not request this code, ignore this email.</p>', 'Use code {{login_code}} to sign in to {{site_name}} as {{recipient_email}} within {{expires_in_minutes}} minutes. If you did not request this code, ignore this email.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'es', 'Tu código de acceso: {{login_code}}', '<p>Usa <strong>{{login_code}}</strong> para entrar en {{site_name}} como {{recipient_email}} durante los próximos {{expires_in_minutes}} minutos. Ignora este correo si no lo solicitaste.</p>', 'Usa {{login_code}} para entrar en {{site_name}} como {{recipient_email}} durante los próximos {{expires_in_minutes}} minutos. Ignora este correo si no lo solicitaste.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'fr', 'Votre code de connexion : {{login_code}}', '<p>Utilisez <strong>{{login_code}}</strong> pour vous connecter à {{site_name}} avec {{recipient_email}} dans les {{expires_in_minutes}} prochaines minutes. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.</p>', 'Utilisez {{login_code}} pour vous connecter à {{site_name}} avec {{recipient_email}} dans les {{expires_in_minutes}} prochaines minutes. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'it', 'Il tuo codice di accesso: {{login_code}}', '<p>Usa <strong>{{login_code}}</strong> per accedere a {{site_name}} come {{recipient_email}} entro {{expires_in_minutes}} minuti. Ignora questa e-mail se non hai fatto la richiesta.</p>', 'Usa {{login_code}} per accedere a {{site_name}} come {{recipient_email}} entro {{expires_in_minutes}} minuti. Ignora questa e-mail se non hai fatto la richiesta.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'ja', 'ログインコード: {{login_code}}', '<p>{{expires_in_minutes}}分以内に<strong>{{login_code}}</strong>を使って{{recipient_email}}として{{site_name}}にログインしてください。心当たりがない場合はこのメールを無視してください。</p>', '{{expires_in_minutes}}分以内に{{login_code}}を使って{{recipient_email}}として{{site_name}}にログインしてください。心当たりがない場合はこのメールを無視してください。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'ko', '로그인 코드: {{login_code}}', '<p>{{expires_in_minutes}}분 이내에 <strong>{{login_code}}</strong> 코드를 사용하여 {{recipient_email}} 계정으로 {{site_name}}에 로그인하세요. 요청하지 않았다면 이 이메일을 무시하세요.</p>', '{{expires_in_minutes}}분 이내에 {{login_code}} 코드를 사용하여 {{recipient_email}} 계정으로 {{site_name}}에 로그인하세요. 요청하지 않았다면 이 이메일을 무시하세요.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'nl', 'Je inlogcode: {{login_code}}', '<p>Gebruik <strong>{{login_code}}</strong> om binnen {{expires_in_minutes}} minuten als {{recipient_email}} bij {{site_name}} in te loggen. Negeer deze e-mail als je dit niet hebt aangevraagd.</p>', 'Gebruik {{login_code}} om binnen {{expires_in_minutes}} minuten als {{recipient_email}} bij {{site_name}} in te loggen. Negeer deze e-mail als je dit niet hebt aangevraagd.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'pt-BR', 'Seu código de acesso: {{login_code}}', '<p>Use <strong>{{login_code}}</strong> para entrar no {{site_name}} como {{recipient_email}} dentro de {{expires_in_minutes}} minutos. Ignore este e-mail se você não fez a solicitação.</p>', 'Use {{login_code}} para entrar no {{site_name}} como {{recipient_email}} dentro de {{expires_in_minutes}} minutos. Ignore este e-mail se você não fez a solicitação.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'zh-CN', '登录代码：{{login_code}}', '<p>请在{{expires_in_minutes}}分钟内使用<strong>{{login_code}}</strong>以{{recipient_email}}身份登录{{site_name}}。如果并非您本人请求，请忽略此邮件。</p>', '请在{{expires_in_minutes}}分钟内使用{{login_code}}以{{recipient_email}}身份登录{{site_name}}。如果并非您本人请求，请忽略此邮件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('31a53059-2d58-4af8-ba51-b97335858b35', 'zh-TW', '登入代碼：{{login_code}}', '<p>請在{{expires_in_minutes}}分鐘內使用<strong>{{login_code}}</strong>以{{recipient_email}}身分登入{{site_name}}。若非您本人要求，請忽略此郵件。</p>', '請在{{expires_in_minutes}}分鐘內使用{{login_code}}以{{recipient_email}}身分登入{{site_name}}。若非您本人要求，請忽略此郵件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'ar', 'شروط {{site_name}} سارية الآن', '<p>{{recipient_email}}، أصبحت شروط {{site_name}} المحدّثة سارية الآن. قراءتها: <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}، أصبحت شروط {{site_name}} المحدّثة سارية الآن. قراءتها: {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'de', 'Die Bedingungen von {{site_name}} gelten jetzt', '<p>{{recipient_email}}, die aktualisierten Bedingungen von {{site_name}} gelten jetzt. Lesen: <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}, die aktualisierten Bedingungen von {{site_name}} gelten jetzt. Lesen: {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'en', 'The updated {{site_name}} terms are now effective', '<p>{{recipient_email}}, the updated {{site_name}} terms are now effective. Read the current terms at <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}, the updated {{site_name}} terms are now effective. Read the current terms at {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'es', 'Los términos de {{site_name}} ya están vigentes', '<p>{{recipient_email}}, los términos actualizados de {{site_name}} ya están vigentes. Consúltalos: <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}, los términos actualizados de {{site_name}} ya están vigentes. Consúltalos: {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'fr', 'Les conditions de {{site_name}} sont en vigueur', '<p>{{recipient_email}}, les conditions mises à jour de {{site_name}} sont désormais en vigueur. Consultez-les : <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}, les conditions mises à jour de {{site_name}} sont désormais en vigueur. Consultez-les : {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'it', 'I termini di {{site_name}} sono ora in vigore', '<p>{{recipient_email}}, i termini aggiornati di {{site_name}} sono ora in vigore. Leggili: <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}, i termini aggiornati di {{site_name}} sono ora in vigore. Leggili: {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'ja', '{{site_name}}利用規約が発効しました', '<p>{{recipient_email}}様、{{site_name}}の新しい利用規約が発効しました。確認: <a href="{{terms_url}}">{{terms_url}}</a>。</p>', '{{recipient_email}}様、{{site_name}}の新しい利用規約が発効しました。確認: {{terms_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'ko', '{{site_name}} 이용약관이 적용되었습니다', '<p>{{recipient_email}}님, {{site_name}}의 새 이용약관이 적용되었습니다. 확인: <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}님, {{site_name}}의 새 이용약관이 적용되었습니다. 확인: {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'nl', 'De voorwaarden van {{site_name}} zijn nu van kracht', '<p>{{recipient_email}}, de bijgewerkte voorwaarden van {{site_name}} zijn nu van kracht. Lezen: <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}, de bijgewerkte voorwaarden van {{site_name}} zijn nu van kracht. Lezen: {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'pt-BR', 'Os termos do {{site_name}} já estão em vigor', '<p>{{recipient_email}}, os termos atualizados do {{site_name}} já estão em vigor. Leia: <a href="{{terms_url}}">{{terms_url}}</a>.</p>', '{{recipient_email}}, os termos atualizados do {{site_name}} já estão em vigor. Leia: {{terms_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'zh-CN', '{{site_name}}条款现已生效', '<p>{{recipient_email}}，{{site_name}}的新条款现已生效。查看：<a href="{{terms_url}}">{{terms_url}}</a>。</p>', '{{recipient_email}}，{{site_name}}的新条款现已生效。查看：{{terms_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('420e3fa6-9f67-4a3d-83ce-48deb200d67f', 'zh-TW', '{{site_name}}條款現已生效', '<p>{{recipient_email}}，{{site_name}}的新條款現已生效。查看：<a href="{{terms_url}}">{{terms_url}}</a>。</p>', '{{recipient_email}}，{{site_name}}的新條款現已生效。查看：{{terms_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'ar', 'أكّد حذف حسابك', '<p>مرحبًا {{name}}. أكّد الحذف عبر <a href="{{confirm_url}}">{{confirm_url}}</a> خلال {{expires_in}}. تجاهل هذه الرسالة إذا لم تطلب الحذف.</p>', 'مرحبًا {{name}}. أكّد الحذف عبر {{confirm_url}} خلال {{expires_in}}. تجاهل هذه الرسالة إذا لم تطلب الحذف.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'de', 'Kontolöschung bestätigen', '<p>Hallo {{name}}. Bestätigen Sie die Löschung innerhalb von {{expires_in}} unter <a href="{{confirm_url}}">{{confirm_url}}</a>. Wenn Sie die Löschung nicht angefordert haben, ignorieren Sie diese E-Mail.</p>', 'Hallo {{name}}. Bestätigen Sie die Löschung innerhalb von {{expires_in}} unter {{confirm_url}}. Wenn Sie die Löschung nicht angefordert haben, ignorieren Sie diese E-Mail.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'en', 'Confirm your account deletion', '<p>Hello {{name}}. We received a request to delete your account. Confirm the request at <a href="{{confirm_url}}">{{confirm_url}}</a> within {{expires_in}}. If you did not request deletion, ignore this email.</p>', 'Hello {{name}}. We received a request to delete your account. Confirm the request at {{confirm_url}} within {{expires_in}}. If you did not request deletion, ignore this email.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'es', 'Confirma la eliminación de tu cuenta', '<p>Hola, {{name}}. Confirma la eliminación en <a href="{{confirm_url}}">{{confirm_url}}</a> antes de {{expires_in}}. Si no solicitaste la eliminación, ignora este correo.</p>', 'Hola, {{name}}. Confirma la eliminación en {{confirm_url}} antes de {{expires_in}}. Si no solicitaste la eliminación, ignora este correo.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'fr', 'Confirmez la suppression de votre compte', '<p>Bonjour {{name}}. Confirmez la suppression sur <a href="{{confirm_url}}">{{confirm_url}}</a> dans un délai de {{expires_in}}. Si vous n’avez pas demandé la suppression, ignorez cet e-mail.</p>', 'Bonjour {{name}}. Confirmez la suppression sur {{confirm_url}} dans un délai de {{expires_in}}. Si vous n’avez pas demandé la suppression, ignorez cet e-mail.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'it', 'Conferma l’eliminazione del tuo account', '<p>Ciao {{name}}. Conferma l’eliminazione su <a href="{{confirm_url}}">{{confirm_url}}</a> entro {{expires_in}}. Se non hai richiesto l’eliminazione, ignora questa e-mail.</p>', 'Ciao {{name}}. Conferma l’eliminazione su {{confirm_url}} entro {{expires_in}}. Se non hai richiesto l’eliminazione, ignora questa e-mail.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'ja', 'アカウント削除を確認してください', '<p>{{name}}さん、{{expires_in}}以内に<a href="{{confirm_url}}">{{confirm_url}}</a>でアカウント削除を確認してください。 削除を依頼していない場合は、このメールを無視してください。</p>', '{{name}}さん、{{expires_in}}以内に{{confirm_url}}でアカウント削除を確認してください。 削除を依頼していない場合は、このメールを無視してください。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'ko', '계정 삭제를 확인해 주세요', '<p>{{name}}님, {{expires_in}} 이내에 <a href="{{confirm_url}}">{{confirm_url}}</a>에서 계정 삭제를 확인해 주세요. 삭제를 요청하지 않았다면 이 이메일을 무시하세요.</p>', '{{name}}님, {{expires_in}} 이내에 {{confirm_url}}에서 계정 삭제를 확인해 주세요. 삭제를 요청하지 않았다면 이 이메일을 무시하세요.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'nl', 'Bevestig de verwijdering van je account', '<p>Hallo {{name}}. Bevestig de verwijdering binnen {{expires_in}} via <a href="{{confirm_url}}">{{confirm_url}}</a>. Negeer deze e-mail als je de verwijdering niet hebt aangevraagd.</p>', 'Hallo {{name}}. Bevestig de verwijdering binnen {{expires_in}} via {{confirm_url}}. Negeer deze e-mail als je de verwijdering niet hebt aangevraagd.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'pt-BR', 'Confirme a exclusão da sua conta', '<p>Olá, {{name}}. Confirme a exclusão em <a href="{{confirm_url}}">{{confirm_url}}</a> dentro de {{expires_in}}. Se você não solicitou a exclusão, ignore este e-mail.</p>', 'Olá, {{name}}. Confirme a exclusão em {{confirm_url}} dentro de {{expires_in}}. Se você não solicitou a exclusão, ignore este e-mail.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'zh-CN', '请确认删除账户', '<p>{{name}}，请在{{expires_in}}内前往<a href="{{confirm_url}}">{{confirm_url}}</a>确认删除账户。 如果您未请求删除，请忽略此邮件。</p>', '{{name}}，请在{{expires_in}}内前往{{confirm_url}}确认删除账户。 如果您未请求删除，请忽略此邮件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('43e26bbc-1ebf-4c8b-96f6-f84e98d8a8ab', 'zh-TW', '請確認刪除帳戶', '<p>{{name}}，請在{{expires_in}}內前往<a href="{{confirm_url}}">{{confirm_url}}</a>確認刪除帳戶。 若您未要求刪除，請忽略此郵件。</p>', '{{name}}，請在{{expires_in}}內前往{{confirm_url}}確認刪除帳戶。 若您未要求刪除，請忽略此郵件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('4a0f4f83-0d38-4e1f-a875-64acb5de8f9e', 'en', 'Your sign-in methods changed', '<p>A sign-in method on your account was changed. Method: {{method}}.</p>', 'A sign-in method on your account was changed. Method: {{method}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8001', 'en', 'Your account email changed', '<p>Your account email changed from {{old_email}} to {{new_email}}. If you did not make this change, contact support immediately.</p>', 'Your account email changed from {{old_email}} to {{new_email}}. If you did not make this change, contact support immediately.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8002', 'en', 'An email address was added', '<p>The email address {{email}} was added to your account for email-code sign-in.</p>', 'The email address {{email}} was added to your account for email-code sign-in.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8003', 'en', 'An email address was removed', '<p>The email address {{email}} was removed from email-code sign-in on your account.</p>', 'The email address {{email}} was removed from email-code sign-in on your account.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8004', 'en', 'A passkey was added', '<p>A passkey was added to your account. If you did not make this change, review your security settings immediately.</p>', 'A passkey was added to your account. If you did not make this change, review your security settings immediately.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8005', 'en', 'A passkey was removed', '<p>A passkey was removed from your account. If you did not make this change, review your security settings immediately.</p>', 'A passkey was removed from your account. If you did not make this change, review your security settings immediately.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8006', 'en', 'A social sign-in was added', '<p>{{provider}} social sign-in was added to your account.</p>', '{{provider}} social sign-in was added to your account.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('5a0f4f83-0d38-4e1f-a875-64acb5de8007', 'en', 'A social sign-in was removed', '<p>{{provider}} social sign-in was removed from your account.</p>', '{{provider}} social sign-in was removed from your account.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'ar', 'تم تغيير عنوان بريدك الإلكتروني', '<p>تغيّر عنوان بريدك الإلكتروني من {{old_email}} إلى {{new_email}}. تواصل مع الدعم إذا لم تُجرِ هذا التغيير.</p>', 'تغيّر عنوان بريدك الإلكتروني من {{old_email}} إلى {{new_email}}. تواصل مع الدعم إذا لم تُجرِ هذا التغيير.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'de', 'Ihre E-Mail-Adresse wurde geändert', '<p>Ihre E-Mail-Adresse wurde von {{old_email}} in {{new_email}} geändert. Wenden Sie sich an den Support, wenn Sie dies nicht veranlasst haben.</p>', 'Ihre E-Mail-Adresse wurde von {{old_email}} in {{new_email}} geändert. Wenden Sie sich an den Support, wenn Sie dies nicht veranlasst haben.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'en', 'Your email address was changed', '<p>The email address for your account changed from {{old_email}} to {{new_email}}. Contact support immediately if you did not make this change.</p>', 'The email address for your account changed from {{old_email}} to {{new_email}}. Contact support immediately if you did not make this change.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'es', 'Tu dirección de correo cambió', '<p>Tu dirección de correo cambió de {{old_email}} a {{new_email}}. Contacta con soporte si no realizaste este cambio.</p>', 'Tu dirección de correo cambió de {{old_email}} a {{new_email}}. Contacta con soporte si no realizaste este cambio.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'fr', 'Votre adresse e-mail a changé', '<p>Votre adresse e-mail est passée de {{old_email}} à {{new_email}}. Contactez l’assistance si vous n’êtes pas à l’origine de ce changement.</p>', 'Votre adresse e-mail est passée de {{old_email}} à {{new_email}}. Contactez l’assistance si vous n’êtes pas à l’origine de ce changement.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'it', 'Il tuo indirizzo e-mail è cambiato', '<p>Il tuo indirizzo e-mail è cambiato da {{old_email}} a {{new_email}}. Contatta l’assistenza se non hai effettuato questa modifica.</p>', 'Il tuo indirizzo e-mail è cambiato da {{old_email}} a {{new_email}}. Contatta l’assistenza se non hai effettuato questa modifica.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'ja', 'メールアドレスが変更されました', '<p>メールアドレスが{{old_email}}から{{new_email}}に変更されました。心当たりがない場合はサポートへご連絡ください。</p>', 'メールアドレスが{{old_email}}から{{new_email}}に変更されました。心当たりがない場合はサポートへご連絡ください。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'ko', '이메일 주소가 변경되었습니다', '<p>이메일 주소가 {{old_email}}에서 {{new_email}}(으)로 변경되었습니다. 본인이 변경하지 않았다면 지원팀에 문의해 주세요.</p>', '이메일 주소가 {{old_email}}에서 {{new_email}}(으)로 변경되었습니다. 본인이 변경하지 않았다면 지원팀에 문의해 주세요.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'nl', 'Je e-mailadres is gewijzigd', '<p>Je e-mailadres is gewijzigd van {{old_email}} naar {{new_email}}. Neem contact op met ondersteuning als jij dit niet hebt gedaan.</p>', 'Je e-mailadres is gewijzigd van {{old_email}} naar {{new_email}}. Neem contact op met ondersteuning als jij dit niet hebt gedaan.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'pt-BR', 'Seu endereço de e-mail mudou', '<p>Seu endereço de e-mail mudou de {{old_email}} para {{new_email}}. Fale com o suporte se você não fez essa alteração.</p>', 'Seu endereço de e-mail mudou de {{old_email}} para {{new_email}}. Fale com o suporte se você não fez essa alteração.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'zh-CN', '电子邮箱地址已更改', '<p>您的电子邮箱地址已从{{old_email}}更改为{{new_email}}。如果不是您本人操作，请联系支持团队。</p>', '您的电子邮箱地址已从{{old_email}}更改为{{new_email}}。如果不是您本人操作，请联系支持团队。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('69c2459a-85bc-4a00-9033-9d620371d588', 'zh-TW', '電子郵件地址已變更', '<p>您的電子郵件地址已從{{old_email}}變更為{{new_email}}。若非您本人操作，請聯絡支援團隊。</p>', '您的電子郵件地址已從{{old_email}}變更為{{new_email}}。若非您本人操作，請聯絡支援團隊。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'ar', 'تم استرداد الحساب', '<p>مرحبًا {{name}}. أصبح حسابك نشطًا من جديد. تسجيل الدخول: <a href="{{login_url}}">{{login_url}}</a>.</p>', 'مرحبًا {{name}}. أصبح حسابك نشطًا من جديد. تسجيل الدخول: {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'de', 'Konto wiederhergestellt', '<p>Hallo {{name}}. Ihr Konto ist wieder aktiv. Anmelden: <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Hallo {{name}}. Ihr Konto ist wieder aktiv. Anmelden: {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'en', 'Your account has been recovered', '<p>Hello {{name}}. Your account recovery is complete and your account is active again. Sign in at <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Hello {{name}}. Your account recovery is complete and your account is active again. Sign in at {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'es', 'Cuenta recuperada', '<p>Hola, {{name}}. Tu cuenta vuelve a estar activa. Iniciar sesión: <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Hola, {{name}}. Tu cuenta vuelve a estar activa. Iniciar sesión: {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'fr', 'Compte récupéré', '<p>Bonjour {{name}}. Votre compte est de nouveau actif. Connexion : <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Bonjour {{name}}. Votre compte est de nouveau actif. Connexion : {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'it', 'Account recuperato', '<p>Ciao {{name}}. Il tuo account è di nuovo attivo. Accedi: <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Ciao {{name}}. Il tuo account è di nuovo attivo. Accedi: {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'ja', 'アカウントが復旧しました', '<p>{{name}}さん、アカウントは再び有効になりました。ログイン: <a href="{{login_url}}">{{login_url}}</a>。</p>', '{{name}}さん、アカウントは再び有効になりました。ログイン: {{login_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'ko', '계정이 복구되었습니다', '<p>{{name}}님, 계정이 다시 활성화되었습니다. 로그인: <a href="{{login_url}}">{{login_url}}</a>.</p>', '{{name}}님, 계정이 다시 활성화되었습니다. 로그인: {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'nl', 'Account hersteld', '<p>Hallo {{name}}. Je account is weer actief. Inloggen: <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Hallo {{name}}. Je account is weer actief. Inloggen: {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'pt-BR', 'Conta recuperada', '<p>Olá, {{name}}. Sua conta está ativa novamente. Entrar: <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Olá, {{name}}. Sua conta está ativa novamente. Entrar: {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'zh-CN', '账户已恢复', '<p>{{name}}，您的账户已重新启用。登录：<a href="{{login_url}}">{{login_url}}</a>。</p>', '{{name}}，您的账户已重新启用。登录：{{login_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('92d5a3f2-e1fa-4fa3-9d60-50d37e86a338', 'zh-TW', '帳戶已復原', '<p>{{name}}，您的帳戶已重新啟用。登入：<a href="{{login_url}}">{{login_url}}</a>。</p>', '{{name}}，您的帳戶已重新啟用。登入：{{login_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'ar', 'تمت جدولة حذف الحساب', '<p>مرحبًا {{name}}. سيُحذف حسابك في {{scheduled_date}} بعد مهلة قدرها {{grace_period}}. الإلغاء: <a href="{{cancel_url}}">{{cancel_url}}</a>. الاسترداد: <a href="{{recover_url}}">{{recover_url}}</a>.</p>', 'مرحبًا {{name}}. سيُحذف حسابك في {{scheduled_date}} بعد مهلة قدرها {{grace_period}}. الإلغاء: {{cancel_url}}. الاسترداد: {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'de', 'Kontolöschung geplant', '<p>Hallo {{name}}. Ihr Konto wird nach einer Frist von {{grace_period}} am {{scheduled_date}} gelöscht. Abbrechen: <a href="{{cancel_url}}">{{cancel_url}}</a>. Wiederherstellen: <a href="{{recover_url}}">{{recover_url}}</a>.</p>', 'Hallo {{name}}. Ihr Konto wird nach einer Frist von {{grace_period}} am {{scheduled_date}} gelöscht. Abbrechen: {{cancel_url}}. Wiederherstellen: {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'en', 'Your account deletion is scheduled', '<p>Hello {{name}}. Your account is scheduled for deletion on {{scheduled_date}} after the {{grace_period}} grace period. Cancel deletion at <a href="{{cancel_url}}">{{cancel_url}}</a> or start account recovery at <a href="{{recover_url}}">{{recover_url}}</a>.</p>', 'Hello {{name}}. Your account is scheduled for deletion on {{scheduled_date}} after the {{grace_period}} grace period. Cancel deletion at {{cancel_url}} or start account recovery at {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'es', 'Eliminación de cuenta programada', '<p>Hola, {{name}}. Tu cuenta se eliminará el {{scheduled_date}} tras un periodo de gracia de {{grace_period}}. Cancelar: <a href="{{cancel_url}}">{{cancel_url}}</a>. Recuperar: <a href="{{recover_url}}">{{recover_url}}</a>.</p>', 'Hola, {{name}}. Tu cuenta se eliminará el {{scheduled_date}} tras un periodo de gracia de {{grace_period}}. Cancelar: {{cancel_url}}. Recuperar: {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'fr', 'Suppression du compte planifiée', '<p>Bonjour {{name}}. Votre compte sera supprimé le {{scheduled_date}} après un délai de grâce de {{grace_period}}. Annuler : <a href="{{cancel_url}}">{{cancel_url}}</a>. Récupérer : <a href="{{recover_url}}">{{recover_url}}</a>.</p>', 'Bonjour {{name}}. Votre compte sera supprimé le {{scheduled_date}} après un délai de grâce de {{grace_period}}. Annuler : {{cancel_url}}. Récupérer : {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'it', 'Eliminazione dell’account programmata', '<p>Ciao {{name}}. Il tuo account verrà eliminato il {{scheduled_date}} dopo un periodo di tolleranza di {{grace_period}}. Annulla: <a href="{{cancel_url}}">{{cancel_url}}</a>. Recupera: <a href="{{recover_url}}">{{recover_url}}</a>.</p>', 'Ciao {{name}}. Il tuo account verrà eliminato il {{scheduled_date}} dopo un periodo di tolleranza di {{grace_period}}. Annulla: {{cancel_url}}. Recupera: {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'ja', 'アカウント削除が予定されました', '<p>{{name}}さん、アカウントは{{grace_period}}の猶予期間後、{{scheduled_date}}に削除されます。キャンセル: <a href="{{cancel_url}}">{{cancel_url}}</a>。復旧: <a href="{{recover_url}}">{{recover_url}}</a>。</p>', '{{name}}さん、アカウントは{{grace_period}}の猶予期間後、{{scheduled_date}}に削除されます。キャンセル: {{cancel_url}}。復旧: {{recover_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'ko', '계정 삭제가 예약되었습니다', '<p>{{name}}님, 계정은 {{grace_period}}의 유예 기간 후 {{scheduled_date}}에 삭제됩니다. 취소: <a href="{{cancel_url}}">{{cancel_url}}</a>. 복구: <a href="{{recover_url}}">{{recover_url}}</a>.</p>', '{{name}}님, 계정은 {{grace_period}}의 유예 기간 후 {{scheduled_date}}에 삭제됩니다. 취소: {{cancel_url}}. 복구: {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'nl', 'Accountverwijdering gepland', '<p>Hallo {{name}}. Je account wordt na een bedenktijd van {{grace_period}} op {{scheduled_date}} verwijderd. Annuleren: <a href="{{cancel_url}}">{{cancel_url}}</a>. Herstellen: <a href="{{recover_url}}">{{recover_url}}</a>.</p>', 'Hallo {{name}}. Je account wordt na een bedenktijd van {{grace_period}} op {{scheduled_date}} verwijderd. Annuleren: {{cancel_url}}. Herstellen: {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'pt-BR', 'Exclusão da conta agendada', '<p>Olá, {{name}}. Sua conta será excluída em {{scheduled_date}} após um período de carência de {{grace_period}}. Cancelar: <a href="{{cancel_url}}">{{cancel_url}}</a>. Recuperar: <a href="{{recover_url}}">{{recover_url}}</a>.</p>', 'Olá, {{name}}. Sua conta será excluída em {{scheduled_date}} após um período de carência de {{grace_period}}. Cancelar: {{cancel_url}}. Recuperar: {{recover_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'zh-CN', '账户删除已安排', '<p>{{name}}，您的账户将在{{grace_period}}宽限期后于{{scheduled_date}}删除。取消：<a href="{{cancel_url}}">{{cancel_url}}</a>。恢复：<a href="{{recover_url}}">{{recover_url}}</a>。</p>', '{{name}}，您的账户将在{{grace_period}}宽限期后于{{scheduled_date}}删除。取消：{{cancel_url}}。恢复：{{recover_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('9f663fe7-181f-4afa-99e8-95f5d9d48a6d', 'zh-TW', '帳戶刪除已排定', '<p>{{name}}，您的帳戶將在{{grace_period}}寬限期後於{{scheduled_date}}刪除。取消：<a href="{{cancel_url}}">{{cancel_url}}</a>。復原：<a href="{{recover_url}}">{{recover_url}}</a>。</p>', '{{name}}，您的帳戶將在{{grace_period}}寬限期後於{{scheduled_date}}刪除。取消：{{cancel_url}}。復原：{{recover_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'ar', 'رمز التسجيل: {{registration_code}}', '<p>استخدم <strong>{{registration_code}}</strong> لتسجيل {{recipient_email}} في {{site_name}} خلال {{expires_in_minutes}} دقيقة. تجاهل هذه الرسالة إذا لم تطلبها.</p>', 'استخدم {{registration_code}} لتسجيل {{recipient_email}} في {{site_name}} خلال {{expires_in_minutes}} دقيقة. تجاهل هذه الرسالة إذا لم تطلبها.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'de', 'Ihr Registrierungscode: {{registration_code}}', '<p>Verwenden Sie <strong>{{registration_code}}</strong>, um {{recipient_email}} innerhalb von {{expires_in_minutes}} Minuten bei {{site_name}} zu registrieren. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.</p>', 'Verwenden Sie {{registration_code}}, um {{recipient_email}} innerhalb von {{expires_in_minutes}} Minuten bei {{site_name}} zu registrieren. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'en', 'Your registration code: {{registration_code}}', '<p>Use code <strong>{{registration_code}}</strong> to register {{recipient_email}} with {{site_name}} within {{expires_in_minutes}} minutes. If you did not request this code, ignore this email.</p>', 'Use code {{registration_code}} to register {{recipient_email}} with {{site_name}} within {{expires_in_minutes}} minutes. If you did not request this code, ignore this email.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'es', 'Tu código de registro: {{registration_code}}', '<p>Usa <strong>{{registration_code}}</strong> para registrar {{recipient_email}} en {{site_name}} durante los próximos {{expires_in_minutes}} minutos. Ignora este correo si no lo solicitaste.</p>', 'Usa {{registration_code}} para registrar {{recipient_email}} en {{site_name}} durante los próximos {{expires_in_minutes}} minutos. Ignora este correo si no lo solicitaste.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'fr', 'Votre code d’inscription : {{registration_code}}', '<p>Utilisez <strong>{{registration_code}}</strong> pour inscrire {{recipient_email}} sur {{site_name}} dans les {{expires_in_minutes}} prochaines minutes. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.</p>', 'Utilisez {{registration_code}} pour inscrire {{recipient_email}} sur {{site_name}} dans les {{expires_in_minutes}} prochaines minutes. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'it', 'Il tuo codice di registrazione: {{registration_code}}', '<p>Usa <strong>{{registration_code}}</strong> per registrare {{recipient_email}} su {{site_name}} entro {{expires_in_minutes}} minuti. Ignora questa e-mail se non hai fatto la richiesta.</p>', 'Usa {{registration_code}} per registrare {{recipient_email}} su {{site_name}} entro {{expires_in_minutes}} minuti. Ignora questa e-mail se non hai fatto la richiesta.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'ja', '登録コード: {{registration_code}}', '<p>{{expires_in_minutes}}分以内に<strong>{{registration_code}}</strong>を使って{{recipient_email}}を{{site_name}}に登録してください。心当たりがない場合はこのメールを無視してください。</p>', '{{expires_in_minutes}}分以内に{{registration_code}}を使って{{recipient_email}}を{{site_name}}に登録してください。心当たりがない場合はこのメールを無視してください。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'ko', '가입 코드: {{registration_code}}', '<p>{{expires_in_minutes}}분 이내에 <strong>{{registration_code}}</strong> 코드를 사용하여 {{recipient_email}}을(를) {{site_name}}에 등록하세요. 요청하지 않았다면 이 이메일을 무시하세요.</p>', '{{expires_in_minutes}}분 이내에 {{registration_code}} 코드를 사용하여 {{recipient_email}}을(를) {{site_name}}에 등록하세요. 요청하지 않았다면 이 이메일을 무시하세요.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'nl', 'Je registratiecode: {{registration_code}}', '<p>Gebruik <strong>{{registration_code}}</strong> om {{recipient_email}} binnen {{expires_in_minutes}} minuten bij {{site_name}} te registreren. Negeer deze e-mail als je dit niet hebt aangevraagd.</p>', 'Gebruik {{registration_code}} om {{recipient_email}} binnen {{expires_in_minutes}} minuten bij {{site_name}} te registreren. Negeer deze e-mail als je dit niet hebt aangevraagd.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'pt-BR', 'Seu código de cadastro: {{registration_code}}', '<p>Use <strong>{{registration_code}}</strong> para cadastrar {{recipient_email}} no {{site_name}} dentro de {{expires_in_minutes}} minutos. Ignore este e-mail se você não fez a solicitação.</p>', 'Use {{registration_code}} para cadastrar {{recipient_email}} no {{site_name}} dentro de {{expires_in_minutes}} minutos. Ignore este e-mail se você não fez a solicitação.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'zh-CN', '注册代码：{{registration_code}}', '<p>请在{{expires_in_minutes}}分钟内使用<strong>{{registration_code}}</strong>在{{site_name}}注册{{recipient_email}}。如果并非您本人请求，请忽略此邮件。</p>', '请在{{expires_in_minutes}}分钟内使用{{registration_code}}在{{site_name}}注册{{recipient_email}}。如果并非您本人请求，请忽略此邮件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('a0d1f894-b25e-439e-9d20-378fcede66c7', 'zh-TW', '註冊代碼：{{registration_code}}', '<p>請在{{expires_in_minutes}}分鐘內使用<strong>{{registration_code}}</strong>在{{site_name}}註冊{{recipient_email}}。若非您本人要求，請忽略此郵件。</p>', '請在{{expires_in_minutes}}分鐘內使用{{registration_code}}在{{site_name}}註冊{{recipient_email}}。若非您本人要求，請忽略此郵件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'ar', 'رمز التحقق: {{verification_code}}', '<p>استخدم <strong>{{verification_code}}</strong> للتحقق من {{recipient_email}} في {{site_name}} خلال {{expires_in_minutes}} دقيقة، أو افتح <a href="{{verification_url}}">{{verification_url}}</a>. تجاهل هذه الرسالة إذا لم تطلبها.</p>', 'استخدم {{verification_code}} للتحقق من {{recipient_email}} في {{site_name}} خلال {{expires_in_minutes}} دقيقة، أو افتح {{verification_url}}. تجاهل هذه الرسالة إذا لم تطلبها.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'de', 'Ihr Bestätigungscode: {{verification_code}}', '<p>Verwenden Sie <strong>{{verification_code}}</strong>, um {{recipient_email}} bei {{site_name}} innerhalb von {{expires_in_minutes}} Minuten zu bestätigen, oder öffnen Sie <a href="{{verification_url}}">{{verification_url}}</a>. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.</p>', 'Verwenden Sie {{verification_code}}, um {{recipient_email}} bei {{site_name}} innerhalb von {{expires_in_minutes}} Minuten zu bestätigen, oder öffnen Sie {{verification_url}}. Ignorieren Sie diese E-Mail, falls Sie sie nicht angefordert haben.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'en', 'Your verification code: {{verification_code}}', '<p>Use code <strong>{{verification_code}}</strong> to verify {{recipient_email}} for {{site_name}} within {{expires_in_minutes}} minutes, or open <a href="{{verification_url}}">{{verification_url}}</a>. If you did not request this code, ignore this email.</p>', 'Use code {{verification_code}} to verify {{recipient_email}} for {{site_name}} within {{expires_in_minutes}} minutes, or open {{verification_url}}. If you did not request this code, ignore this email.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'es', 'Tu código de verificación: {{verification_code}}', '<p>Usa <strong>{{verification_code}}</strong> para verificar {{recipient_email}} en {{site_name}} durante los próximos {{expires_in_minutes}} minutos, o abre <a href="{{verification_url}}">{{verification_url}}</a>. Ignora este correo si no lo solicitaste.</p>', 'Usa {{verification_code}} para verificar {{recipient_email}} en {{site_name}} durante los próximos {{expires_in_minutes}} minutos, o abre {{verification_url}}. Ignora este correo si no lo solicitaste.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'fr', 'Votre code de vérification : {{verification_code}}', '<p>Utilisez <strong>{{verification_code}}</strong> pour vérifier {{recipient_email}} sur {{site_name}} dans les {{expires_in_minutes}} prochaines minutes, ou ouvrez <a href="{{verification_url}}">{{verification_url}}</a>. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.</p>', 'Utilisez {{verification_code}} pour vérifier {{recipient_email}} sur {{site_name}} dans les {{expires_in_minutes}} prochaines minutes, ou ouvrez {{verification_url}}. Ignorez cet e-mail si vous n’êtes pas à l’origine de la demande.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'it', 'Il tuo codice di verifica: {{verification_code}}', '<p>Usa <strong>{{verification_code}}</strong> per verificare {{recipient_email}} su {{site_name}} entro {{expires_in_minutes}} minuti oppure apri <a href="{{verification_url}}">{{verification_url}}</a>. Ignora questa e-mail se non hai fatto la richiesta.</p>', 'Usa {{verification_code}} per verificare {{recipient_email}} su {{site_name}} entro {{expires_in_minutes}} minuti oppure apri {{verification_url}}. Ignora questa e-mail se non hai fatto la richiesta.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'ja', '確認コード: {{verification_code}}', '<p>{{expires_in_minutes}}分以内に<strong>{{verification_code}}</strong>を使って{{site_name}}の{{recipient_email}}を確認してください。または<a href="{{verification_url}}">{{verification_url}}</a>を開いてください。心当たりがない場合はこのメールを無視してください。</p>', '{{expires_in_minutes}}分以内に{{verification_code}}を使って{{site_name}}の{{recipient_email}}を確認してください。または{{verification_url}}を開いてください。心当たりがない場合はこのメールを無視してください。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'ko', '인증 코드: {{verification_code}}', '<p>{{expires_in_minutes}}분 이내에 <strong>{{verification_code}}</strong> 코드를 사용하여 {{site_name}}의 {{recipient_email}}을(를) 인증하세요. 또는 <a href="{{verification_url}}">{{verification_url}}</a>을(를) 여세요. 요청하지 않았다면 이 이메일을 무시하세요.</p>', '{{expires_in_minutes}}분 이내에 {{verification_code}} 코드를 사용하여 {{site_name}}의 {{recipient_email}}을(를) 인증하세요. 또는 {{verification_url}}을(를) 여세요. 요청하지 않았다면 이 이메일을 무시하세요.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'nl', 'Je verificatiecode: {{verification_code}}', '<p>Gebruik <strong>{{verification_code}}</strong> om {{recipient_email}} binnen {{expires_in_minutes}} minuten bij {{site_name}} te verifiëren, of open <a href="{{verification_url}}">{{verification_url}}</a>. Negeer deze e-mail als je dit niet hebt aangevraagd.</p>', 'Gebruik {{verification_code}} om {{recipient_email}} binnen {{expires_in_minutes}} minuten bij {{site_name}} te verifiëren, of open {{verification_url}}. Negeer deze e-mail als je dit niet hebt aangevraagd.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'pt-BR', 'Seu código de verificação: {{verification_code}}', '<p>Use <strong>{{verification_code}}</strong> para verificar {{recipient_email}} no {{site_name}} dentro de {{expires_in_minutes}} minutos ou abra <a href="{{verification_url}}">{{verification_url}}</a>. Ignore este e-mail se você não fez a solicitação.</p>', 'Use {{verification_code}} para verificar {{recipient_email}} no {{site_name}} dentro de {{expires_in_minutes}} minutos ou abra {{verification_url}}. Ignore este e-mail se você não fez a solicitação.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'zh-CN', '验证码：{{verification_code}}', '<p>请在{{expires_in_minutes}}分钟内使用<strong>{{verification_code}}</strong>验证{{site_name}}的{{recipient_email}}，或打开<a href="{{verification_url}}">{{verification_url}}</a>。如果并非您本人请求，请忽略此邮件。</p>', '请在{{expires_in_minutes}}分钟内使用{{verification_code}}验证{{site_name}}的{{recipient_email}}，或打开{{verification_url}}。如果并非您本人请求，请忽略此邮件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('b02ea444-9d73-4176-8b33-7b9b65ac9baf', 'zh-TW', '驗證碼：{{verification_code}}', '<p>請在{{expires_in_minutes}}分鐘內使用<strong>{{verification_code}}</strong>驗證{{site_name}}的{{recipient_email}}，或開啟<a href="{{verification_url}}">{{verification_url}}</a>。若非您本人要求，請忽略此郵件。</p>', '請在{{expires_in_minutes}}分鐘內使用{{verification_code}}驗證{{site_name}}的{{recipient_email}}，或開啟{{verification_url}}。若非您本人要求，請忽略此郵件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'ar', 'تحديث سياسة خصوصية {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}، تسري سياسة خصوصية {{site_name}} المحدّثة في {{effective_date}}. المعاينة: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}، تسري سياسة خصوصية {{site_name}} المحدّثة في {{effective_date}}. المعاينة: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'de', 'Aktualisierte Datenschutzrichtlinie von {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, die aktualisierte Datenschutzrichtlinie von {{site_name}} gilt ab dem {{effective_date}}. Vorschau: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, die aktualisierte Datenschutzrichtlinie von {{site_name}} gilt ab dem {{effective_date}}. Vorschau: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'en', 'Upcoming update to the {{site_name}} privacy policy', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, the updated {{site_name}} privacy policy takes effect on {{effective_date}}. Review the changes before then at <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, the updated {{site_name}} privacy policy takes effect on {{effective_date}}. Review the changes before then at {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'es', 'Actualización de privacidad de {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, la política de privacidad actualizada de {{site_name}} entra en vigor el {{effective_date}}. Vista previa: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, la política de privacidad actualizada de {{site_name}} entra en vigor el {{effective_date}}. Vista previa: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'fr', 'Mise à jour de la confidentialité de {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, la politique de confidentialité mise à jour de {{site_name}} entrera en vigueur le {{effective_date}}. Aperçu : <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, la politique de confidentialité mise à jour de {{site_name}} entrera en vigueur le {{effective_date}}. Aperçu : {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'it', 'Aggiornamento della privacy di {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, l’informativa sulla privacy aggiornata di {{site_name}} entrerà in vigore il {{effective_date}}. Anteprima: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, l’informativa sulla privacy aggiornata di {{site_name}} entrerà in vigore il {{effective_date}}. Anteprima: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'ja', '{{site_name}}プライバシーポリシーの更新', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}様、{{site_name}}の新しいプライバシーポリシーは{{effective_date}}に発効します。プレビュー: <a href="{{preview_url}}">{{preview_url}}</a>。</p>', '{{policy_title}}

{{recipient_email}}様、{{site_name}}の新しいプライバシーポリシーは{{effective_date}}に発効します。プレビュー: {{preview_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'ko', '{{site_name}} 개인정보 처리방침 업데이트', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}님, {{site_name}}의 새 개인정보 처리방침은 {{effective_date}}부터 적용됩니다. 미리보기: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}님, {{site_name}}의 새 개인정보 처리방침은 {{effective_date}}부터 적용됩니다. 미리보기: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'nl', 'Bijgewerkt privacybeleid van {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, het bijgewerkte privacybeleid van {{site_name}} gaat in op {{effective_date}}. Voorbeeld: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, het bijgewerkte privacybeleid van {{site_name}} gaat in op {{effective_date}}. Voorbeeld: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'pt-BR', 'Atualização de privacidade do {{site_name}}', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}, a política de privacidade atualizada do {{site_name}} entra em vigor em {{effective_date}}. Prévia: <a href="{{preview_url}}">{{preview_url}}</a>.</p>', '{{policy_title}}

{{recipient_email}}, a política de privacidade atualizada do {{site_name}} entra em vigor em {{effective_date}}. Prévia: {{preview_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'zh-CN', '{{site_name}}隐私政策更新', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}，{{site_name}}的新隐私政策将于{{effective_date}}生效。预览：<a href="{{preview_url}}">{{preview_url}}</a>。</p>', '{{policy_title}}

{{recipient_email}}，{{site_name}}的新隐私政策将于{{effective_date}}生效。预览：{{preview_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('c25d4f1c-6429-40e4-bfaf-23c10d4f7388', 'zh-TW', '{{site_name}}隱私權政策更新', '<p><strong>{{policy_title}}</strong></p><p>{{recipient_email}}，{{site_name}}的新隱私權政策將於{{effective_date}}生效。預覽：<a href="{{preview_url}}">{{preview_url}}</a>。</p>', '{{policy_title}}

{{recipient_email}}，{{site_name}}的新隱私權政策將於{{effective_date}}生效。預覽：{{preview_url}}。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'ar', 'مرحبًا بك في {{site_name}}', '<p>مرحبًا {{name}}. أهلًا بك في {{site_name}}. تسجيل الدخول: <a href="{{login_url}}">{{login_url}}</a>. شكرًا لانضمامك إلينا.</p>', 'مرحبًا {{name}}. أهلًا بك في {{site_name}}. تسجيل الدخول: {{login_url}}. شكرًا لانضمامك إلينا.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'de', 'Willkommen bei {{site_name}}', '<p>Hallo {{name}}. Willkommen bei {{site_name}}. Anmelden: <a href="{{login_url}}">{{login_url}}</a>. Vielen Dank, dass Sie dabei sind.</p>', 'Hallo {{name}}. Willkommen bei {{site_name}}. Anmelden: {{login_url}}. Vielen Dank, dass Sie dabei sind.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'en', 'Welcome to {{site_name}}', '<p>Hello {{name}}. Welcome to {{site_name}}, and thanks for joining us. You can sign in at <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Hello {{name}}. Welcome to {{site_name}}, and thanks for joining us. You can sign in at {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'es', 'Te damos la bienvenida a {{site_name}}', '<p>Hola, {{name}}. Te damos la bienvenida a {{site_name}}. Iniciar sesión: <a href="{{login_url}}">{{login_url}}</a>. Gracias por unirte.</p>', 'Hola, {{name}}. Te damos la bienvenida a {{site_name}}. Iniciar sesión: {{login_url}}. Gracias por unirte.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'fr', 'Bienvenue sur {{site_name}}', '<p>Bonjour {{name}}. Bienvenue sur {{site_name}}. Connexion : <a href="{{login_url}}">{{login_url}}</a>. Merci de nous avoir rejoints.</p>', 'Bonjour {{name}}. Bienvenue sur {{site_name}}. Connexion : {{login_url}}. Merci de nous avoir rejoints.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'it', 'Benvenuto su {{site_name}}', '<p>Ciao {{name}}. Benvenuto su {{site_name}}. Accedi: <a href="{{login_url}}">{{login_url}}</a>. Grazie per esserti unito.</p>', 'Ciao {{name}}. Benvenuto su {{site_name}}. Accedi: {{login_url}}. Grazie per esserti unito.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'ja', '{{site_name}}へようこそ', '<p>{{name}}さん、{{site_name}}へようこそ。ログイン: <a href="{{login_url}}">{{login_url}}</a>。 ご参加いただきありがとうございます。</p>', '{{name}}さん、{{site_name}}へようこそ。ログイン: {{login_url}}。 ご参加いただきありがとうございます。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'ko', '{{site_name}}에 오신 것을 환영합니다', '<p>{{name}}님, {{site_name}}에 오신 것을 환영합니다. 로그인: <a href="{{login_url}}">{{login_url}}</a>. 함께해 주셔서 감사합니다.</p>', '{{name}}님, {{site_name}}에 오신 것을 환영합니다. 로그인: {{login_url}}. 함께해 주셔서 감사합니다.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'nl', 'Welkom bij {{site_name}}', '<p>Hallo {{name}}. Welkom bij {{site_name}}. Inloggen: <a href="{{login_url}}">{{login_url}}</a>. Bedankt dat je meedoet.</p>', 'Hallo {{name}}. Welkom bij {{site_name}}. Inloggen: {{login_url}}. Bedankt dat je meedoet.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'pt-BR', 'Boas-vindas ao {{site_name}}', '<p>Olá, {{name}}. Boas-vindas ao {{site_name}}. Entrar: <a href="{{login_url}}">{{login_url}}</a>. Agradecemos por fazer parte.</p>', 'Olá, {{name}}. Boas-vindas ao {{site_name}}. Entrar: {{login_url}}. Agradecemos por fazer parte.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'zh-CN', '欢迎使用{{site_name}}', '<p>{{name}}，欢迎使用{{site_name}}。登录：<a href="{{login_url}}">{{login_url}}</a>。 感谢您的加入。</p>', '{{name}}，欢迎使用{{site_name}}。登录：{{login_url}}。 感谢您的加入。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('d3b6c635-2d07-4145-9270-090156c309d8', 'zh-TW', '歡迎使用{{site_name}}', '<p>{{name}}，歡迎使用{{site_name}}。登入：<a href="{{login_url}}">{{login_url}}</a>。 感謝您的加入。</p>', '{{name}}，歡迎使用{{site_name}}。登入：{{login_url}}。 感謝您的加入。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'ar', 'أكّد استرداد حسابك', '<p>مرحبًا {{name}}. أكّد الاسترداد عبر <a href="{{confirm_url}}">{{confirm_url}}</a> خلال {{expires_in}}. تجاهل هذه الرسالة إذا لم تطلب الاسترداد.</p>', 'مرحبًا {{name}}. أكّد الاسترداد عبر {{confirm_url}} خلال {{expires_in}}. تجاهل هذه الرسالة إذا لم تطلب الاسترداد.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'de', 'Kontowiederherstellung bestätigen', '<p>Hallo {{name}}. Bestätigen Sie die Wiederherstellung innerhalb von {{expires_in}} unter <a href="{{confirm_url}}">{{confirm_url}}</a>. Wenn Sie die Wiederherstellung nicht angefordert haben, ignorieren Sie diese E-Mail.</p>', 'Hallo {{name}}. Bestätigen Sie die Wiederherstellung innerhalb von {{expires_in}} unter {{confirm_url}}. Wenn Sie die Wiederherstellung nicht angefordert haben, ignorieren Sie diese E-Mail.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'en', 'Confirm your account recovery', '<p>Hello {{name}}. We received a request to recover your account. Confirm recovery at <a href="{{confirm_url}}">{{confirm_url}}</a> within {{expires_in}}. If you did not request recovery, ignore this email.</p>', 'Hello {{name}}. We received a request to recover your account. Confirm recovery at {{confirm_url}} within {{expires_in}}. If you did not request recovery, ignore this email.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'es', 'Confirma la recuperación de tu cuenta', '<p>Hola, {{name}}. Confirma la recuperación en <a href="{{confirm_url}}">{{confirm_url}}</a> antes de {{expires_in}}. Si no solicitaste la recuperación, ignora este correo.</p>', 'Hola, {{name}}. Confirma la recuperación en {{confirm_url}} antes de {{expires_in}}. Si no solicitaste la recuperación, ignora este correo.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'fr', 'Confirmez la récupération de votre compte', '<p>Bonjour {{name}}. Confirmez la récupération sur <a href="{{confirm_url}}">{{confirm_url}}</a> dans un délai de {{expires_in}}. Si vous n’avez pas demandé la récupération, ignorez cet e-mail.</p>', 'Bonjour {{name}}. Confirmez la récupération sur {{confirm_url}} dans un délai de {{expires_in}}. Si vous n’avez pas demandé la récupération, ignorez cet e-mail.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'it', 'Conferma il recupero del tuo account', '<p>Ciao {{name}}. Conferma il recupero su <a href="{{confirm_url}}">{{confirm_url}}</a> entro {{expires_in}}. Se non hai richiesto il recupero, ignora questa e-mail.</p>', 'Ciao {{name}}. Conferma il recupero su {{confirm_url}} entro {{expires_in}}. Se non hai richiesto il recupero, ignora questa e-mail.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'ja', 'アカウント復旧を確認してください', '<p>{{name}}さん、{{expires_in}}以内に<a href="{{confirm_url}}">{{confirm_url}}</a>でアカウント復旧を確認してください。 復旧を依頼していない場合は、このメールを無視してください。</p>', '{{name}}さん、{{expires_in}}以内に{{confirm_url}}でアカウント復旧を確認してください。 復旧を依頼していない場合は、このメールを無視してください。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'ko', '계정 복구를 확인해 주세요', '<p>{{name}}님, {{expires_in}} 이내에 <a href="{{confirm_url}}">{{confirm_url}}</a>에서 계정 복구를 확인해 주세요. 복구를 요청하지 않았다면 이 이메일을 무시하세요.</p>', '{{name}}님, {{expires_in}} 이내에 {{confirm_url}}에서 계정 복구를 확인해 주세요. 복구를 요청하지 않았다면 이 이메일을 무시하세요.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'nl', 'Bevestig het herstel van je account', '<p>Hallo {{name}}. Bevestig het herstel binnen {{expires_in}} via <a href="{{confirm_url}}">{{confirm_url}}</a>. Negeer deze e-mail als je het herstel niet hebt aangevraagd.</p>', 'Hallo {{name}}. Bevestig het herstel binnen {{expires_in}} via {{confirm_url}}. Negeer deze e-mail als je het herstel niet hebt aangevraagd.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'pt-BR', 'Confirme a recuperação da sua conta', '<p>Olá, {{name}}. Confirme a recuperação em <a href="{{confirm_url}}">{{confirm_url}}</a> dentro de {{expires_in}}. Se você não solicitou a recuperação, ignore este e-mail.</p>', 'Olá, {{name}}. Confirme a recuperação em {{confirm_url}} dentro de {{expires_in}}. Se você não solicitou a recuperação, ignore este e-mail.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'zh-CN', '请确认恢复账户', '<p>{{name}}，请在{{expires_in}}内前往<a href="{{confirm_url}}">{{confirm_url}}</a>确认恢复账户。 如果您未请求恢复，请忽略此邮件。</p>', '{{name}}，请在{{expires_in}}内前往{{confirm_url}}确认恢复账户。 如果您未请求恢复，请忽略此邮件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('e233cead-9c95-4653-9b30-504c6a5e888b', 'zh-TW', '請確認復原帳戶', '<p>{{name}}，請在{{expires_in}}內前往<a href="{{confirm_url}}">{{confirm_url}}</a>確認復原帳戶。 若您未要求復原，請忽略此郵件。</p>', '{{name}}，請在{{expires_in}}內前往{{confirm_url}}確認復原帳戶。 若您未要求復原，請忽略此郵件。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'ar', 'تم حذف الحساب', '<p>مرحبًا {{name}}. حُذف حسابك نهائيًا كما طلبت. لا يلزم اتخاذ أي إجراء آخر.</p>', 'مرحبًا {{name}}. حُذف حسابك نهائيًا كما طلبت. لا يلزم اتخاذ أي إجراء آخر.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'de', 'Konto gelöscht', '<p>Hallo {{name}}. Ihr Konto wurde wie gewünscht dauerhaft gelöscht. Es ist keine weitere Aktion erforderlich.</p>', 'Hallo {{name}}. Ihr Konto wurde wie gewünscht dauerhaft gelöscht. Es ist keine weitere Aktion erforderlich.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'en', 'Your account has been deleted', '<p>Hello {{name}}. Your account has been permanently deleted as requested. No further action is required.</p>', 'Hello {{name}}. Your account has been permanently deleted as requested. No further action is required.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'es', 'Cuenta eliminada', '<p>Hola, {{name}}. Tu cuenta se eliminó permanentemente tal como solicitaste. No es necesario que hagas nada más.</p>', 'Hola, {{name}}. Tu cuenta se eliminó permanentemente tal como solicitaste. No es necesario que hagas nada más.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'fr', 'Compte supprimé', '<p>Bonjour {{name}}. Votre compte a été supprimé définitivement comme demandé. Aucune autre action n’est requise.</p>', 'Bonjour {{name}}. Votre compte a été supprimé définitivement comme demandé. Aucune autre action n’est requise.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'it', 'Account eliminato', '<p>Ciao {{name}}. Il tuo account è stato eliminato definitivamente come richiesto. Non è richiesta alcuna altra azione.</p>', 'Ciao {{name}}. Il tuo account è stato eliminato definitivamente come richiesto. Non è richiesta alcuna altra azione.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'ja', 'アカウントが削除されました', '<p>{{name}}さん、ご依頼どおりアカウントは完全に削除されました。 これ以上の操作は必要ありません。</p>', '{{name}}さん、ご依頼どおりアカウントは完全に削除されました。 これ以上の操作は必要ありません。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'ko', '계정이 삭제되었습니다', '<p>{{name}}님, 요청하신 대로 계정이 영구 삭제되었습니다. 추가로 할 일은 없습니다.</p>', '{{name}}님, 요청하신 대로 계정이 영구 삭제되었습니다. 추가로 할 일은 없습니다.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'nl', 'Account verwijderd', '<p>Hallo {{name}}. Je account is zoals gevraagd permanent verwijderd. Er is geen verdere actie nodig.</p>', 'Hallo {{name}}. Je account is zoals gevraagd permanent verwijderd. Er is geen verdere actie nodig.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'pt-BR', 'Conta excluída', '<p>Olá, {{name}}. Sua conta foi excluída permanentemente como solicitado. Nenhuma outra ação é necessária.</p>', 'Olá, {{name}}. Sua conta foi excluída permanentemente como solicitado. Nenhuma outra ação é necessária.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'zh-CN', '账户已删除', '<p>{{name}}，您的账户已按要求永久删除。 无需采取其他操作。</p>', '{{name}}，您的账户已按要求永久删除。 无需采取其他操作。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('ed8c8311-ddd8-4a6f-88ac-961f26c63b39', 'zh-TW', '帳戶已刪除', '<p>{{name}}，您的帳戶已依要求永久刪除。 無需採取其他動作。</p>', '{{name}}，您的帳戶已依要求永久刪除。 無需採取其他動作。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'ar', 'تم إلغاء حذف الحساب', '<p>مرحبًا {{name}}. أُلغي طلب حذف حسابك. تسجيل الدخول: <a href="{{login_url}}">{{login_url}}</a>. سيبقى حسابك نشطًا.</p>', 'مرحبًا {{name}}. أُلغي طلب حذف حسابك. تسجيل الدخول: {{login_url}}. سيبقى حسابك نشطًا.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'de', 'Kontolöschung abgebrochen', '<p>Hallo {{name}}. Ihr Löschauftrag wurde abgebrochen. Anmelden: <a href="{{login_url}}">{{login_url}}</a>. Ihr Konto bleibt aktiv.</p>', 'Hallo {{name}}. Ihr Löschauftrag wurde abgebrochen. Anmelden: {{login_url}}. Ihr Konto bleibt aktiv.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'en', 'Your account deletion was cancelled', '<p>Hello {{name}}. Your scheduled account deletion was cancelled and your account remains active. Sign in at <a href="{{login_url}}">{{login_url}}</a>.</p>', 'Hello {{name}}. Your scheduled account deletion was cancelled and your account remains active. Sign in at {{login_url}}.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'es', 'Eliminación de cuenta cancelada', '<p>Hola, {{name}}. Se canceló tu solicitud de eliminación. Iniciar sesión: <a href="{{login_url}}">{{login_url}}</a>. Tu cuenta sigue activa.</p>', 'Hola, {{name}}. Se canceló tu solicitud de eliminación. Iniciar sesión: {{login_url}}. Tu cuenta sigue activa.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'fr', 'Suppression du compte annulée', '<p>Bonjour {{name}}. Votre demande de suppression a été annulée. Connexion : <a href="{{login_url}}">{{login_url}}</a>. Votre compte reste actif.</p>', 'Bonjour {{name}}. Votre demande de suppression a été annulée. Connexion : {{login_url}}. Votre compte reste actif.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'it', 'Eliminazione dell’account annullata', '<p>Ciao {{name}}. La richiesta di eliminazione è stata annullata. Accedi: <a href="{{login_url}}">{{login_url}}</a>. Il tuo account resta attivo.</p>', 'Ciao {{name}}. La richiesta di eliminazione è stata annullata. Accedi: {{login_url}}. Il tuo account resta attivo.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'ja', 'アカウント削除がキャンセルされました', '<p>{{name}}さん、アカウント削除のリクエストはキャンセルされました。ログイン: <a href="{{login_url}}">{{login_url}}</a>。 アカウントは引き続き有効です。</p>', '{{name}}さん、アカウント削除のリクエストはキャンセルされました。ログイン: {{login_url}}。 アカウントは引き続き有効です。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'ko', '계정 삭제가 취소되었습니다', '<p>{{name}}님, 계정 삭제 요청이 취소되었습니다. 로그인: <a href="{{login_url}}">{{login_url}}</a>. 계정은 계속 활성 상태입니다.</p>', '{{name}}님, 계정 삭제 요청이 취소되었습니다. 로그인: {{login_url}}. 계정은 계속 활성 상태입니다.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'nl', 'Accountverwijdering geannuleerd', '<p>Hallo {{name}}. Je verzoek tot verwijdering is geannuleerd. Inloggen: <a href="{{login_url}}">{{login_url}}</a>. Je account blijft actief.</p>', 'Hallo {{name}}. Je verzoek tot verwijdering is geannuleerd. Inloggen: {{login_url}}. Je account blijft actief.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'pt-BR', 'Exclusão da conta cancelada', '<p>Olá, {{name}}. Sua solicitação de exclusão foi cancelada. Entrar: <a href="{{login_url}}">{{login_url}}</a>. Sua conta continua ativa.</p>', 'Olá, {{name}}. Sua solicitação de exclusão foi cancelada. Entrar: {{login_url}}. Sua conta continua ativa.');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'zh-CN', '账户删除已取消', '<p>{{name}}，您的账户删除请求已取消。登录：<a href="{{login_url}}">{{login_url}}</a>。 您的账户仍处于启用状态。</p>', '{{name}}，您的账户删除请求已取消。登录：{{login_url}}。 您的账户仍处于启用状态。');
INSERT INTO public.email_template_translation (entity_id, locale, subject, content_html, content_text) VALUES ('fa81a495-e74c-47a0-8d49-32cb69daef1e', 'zh-TW', '帳戶刪除已取消', '<p>{{name}}，您的帳戶刪除要求已取消。登入：<a href="{{login_url}}">{{login_url}}</a>。 您的帳戶仍維持啟用狀態。</p>', '{{name}}，您的帳戶刪除要求已取消。登入：{{login_url}}。 您的帳戶仍維持啟用狀態。');


--
-- Data for Name: map_theme; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.map_theme (id, name, callout_scale, callout_offset_x, callout_offset_y, callout_fields, attribution_font_size, created_at, updated_at, show_area_labels, show_poi_labels, light_background_color, light_water_color, light_land_color, light_road_color, light_building_fill_color, light_building_stroke_enabled, light_building_stroke_color, light_callout_line_color, light_callout_text_color, light_callout_background_color, light_callout_description_color, light_attribution_color, light_label_text_color, light_cluster_color, light_cluster_hover_color, light_cluster_text_color, light_cluster_text_hover_color, light_callout_hover_line_color, light_callout_hover_text_color, light_callout_hover_description_color, light_callout_hover_background_color, dark_background_color, dark_water_color, dark_land_color, dark_road_color, dark_building_fill_color, dark_building_stroke_enabled, dark_building_stroke_color, dark_callout_line_color, dark_callout_text_color, dark_callout_background_color, dark_callout_description_color, dark_attribution_color, dark_label_text_color, dark_cluster_color, dark_cluster_hover_color, dark_cluster_text_color, dark_cluster_text_hover_color, dark_callout_hover_line_color, dark_callout_hover_text_color, dark_callout_hover_description_color, dark_callout_hover_background_color, edit_version) VALUES ('4c9d27eb-7595-40e6-bbf1-f8324a5479fa', 'Built-in', 1, 0, 0, '{name,address}', 11, '2026-08-06 00:00:00+00', '2026-08-06 00:00:00+00', true, false, '#f5f5f5', '#aadaff', '#e8e8e8', '#ffffff', '#dcdcdc', false, '#c8c8c8', '#333333', '#333333', 'rgba(255,255,255,0.56)', '#666666', '#808080', 'rgba(51,65,85,0.82)', 'rgba(15,23,42,0.08)', 'rgba(15,23,42,0.14)', 'rgba(15,23,42,0.9)', 'rgba(15,23,42,1)', '#1d4ed8', '#111827', 'rgba(31,41,55,0.92)', 'rgba(255,255,255,0.98)', '#1a1a2e', '#0f3460', '#16213e', '#2a2a4a', '#1f1f3d', false, '#3a3a5a', '#ffffff', '#ffffff', 'rgba(15,23,42,0.4)', '#b0b0b0', '#808080', 'rgba(226,232,240,0.82)', 'rgba(248,250,252,0.08)', 'rgba(248,250,252,0.16)', 'rgba(248,250,252,0.94)', '#ffffff', '#93c5fd', '#ffffff', 'rgba(255,255,255,0.92)', 'rgba(15,23,42,0.94)', 1);


--
-- Data for Name: site_settings; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.site_settings (id, site_title, company_name, company_address, tax_id, legal_email, support_email, privacy_email, social_links, logo_email_file_id, favicon_file_id, primary_color, default_comments_enabled, homepage_page_id, menu_header_id, menu_secondary_id, menu_footer_id, menu_avatar_dropdown_id, meta_description, google_analytics_id, og_image_config, created_at, updated_at, site_og_background_file_id, privacy_og_background_file_id, terms_og_background_file_id, logo_light_file_id, logo_dark_file_id, site_og_asset_id, default_map_theme_id) VALUES (1, '', '', '', '', '', '', '', '{}', NULL, NULL, '#b02d23', true, NULL, NULL, NULL, NULL, NULL, '', NULL, NULL, '2026-08-03 07:42:50.9478+00', '2026-08-03 07:42:50.9478+00', NULL, NULL, NULL, NULL, NULL, NULL, '4c9d27eb-7595-40e6-bbf1-f8324a5479fa');


--
-- Data for Name: translation_settings; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.translation_settings (id, default_locale, protected_terms, created_at, updated_at) VALUES (1, 'en', '{}', '2026-08-03 07:42:51.195274+00', '2026-08-03 07:42:51.195274+00');


--
-- PostgreSQL database dump complete
--
COMMIT;

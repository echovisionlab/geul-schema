-- Forward-only upgrade. Apply before deploying an API that reads Page access policy.
-- Existing Pages keep public access through the empty policy. No Page content changes.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.page
    ADD COLUMN IF NOT EXISTS access_policy jsonb DEFAULT '{}'::jsonb NOT NULL;

DO $$
DECLARE
    policy_column record;
    policy_constraint record;
BEGIN
    SELECT attribute.atttypid, attribute.attnotnull, attribute.attgenerated, attribute.attidentity,
           attribute.attnum, pg_get_expr(definition.adbin, definition.adrelid) AS default_expression
      INTO policy_column
      FROM pg_attribute AS attribute
      LEFT JOIN pg_attrdef AS definition
        ON definition.adrelid = attribute.attrelid AND definition.adnum = attribute.attnum
     WHERE attribute.attrelid = 'public.page'::regclass
       AND attribute.attname = 'access_policy' AND NOT attribute.attisdropped;

    IF NOT FOUND OR policy_column.atttypid <> 'jsonb'::regtype
       OR NOT policy_column.attnotnull OR policy_column.attgenerated <> ''
       OR policy_column.attidentity <> ''
       OR policy_column.default_expression IS DISTINCT FROM '''{}''::jsonb' THEN
        RAISE EXCEPTION 'Page access_policy must be plain jsonb NOT NULL with default empty object';
    END IF;

    SELECT contype, convalidated, conkey, pg_get_expr(conbin, conrelid) AS expression
      INTO policy_constraint
      FROM pg_constraint
     WHERE conrelid = 'public.page'::regclass AND conname = 'chk_page_access_policy_object';

    IF FOUND THEN
        IF policy_constraint.contype <> 'c' OR NOT policy_constraint.convalidated
           OR policy_constraint.conkey IS DISTINCT FROM ARRAY[policy_column.attnum]::smallint[]
           OR policy_constraint.expression IS DISTINCT FROM '(jsonb_typeof(access_policy) = ''object''::text)' THEN
            RAISE EXCEPTION 'Page access_policy object constraint does not match the required validated contract';
        END IF;
    ELSE
        ALTER TABLE public.page ADD CONSTRAINT chk_page_access_policy_object
            CHECK (jsonb_typeof(access_policy) = 'object');
    END IF;
END
$$;

COMMIT;

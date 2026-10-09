-- Legal policies support deletion in every lifecycle. Delivery runs retain
-- their sealed policy UUID/version and render snapshot as historical facts,
-- rather than requiring the mutable policy row to remain present.
-- Deploy before the API that permits deleting policies with delivery history.
BEGIN;
SET LOCAL lock_timeout = '10s';
ALTER TABLE public.email_delivery_run
    DROP CONSTRAINT IF EXISTS email_delivery_run_terms_id_fkey,
    DROP CONSTRAINT IF EXISTS email_delivery_run_privacy_id_fkey;
COMMIT;

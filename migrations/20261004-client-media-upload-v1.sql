-- Forward-only upgrade for existing installations. Apply before the API upgrade.
-- Retry safe: no existing upload session or original-upload state is changed.
BEGIN;

ALTER TABLE public.upload_session
    ADD COLUMN IF NOT EXISTS client_media_bundle_id uuid,
    ADD COLUMN IF NOT EXISTS client_media_manifest jsonb;

ALTER TABLE public.file
    ADD COLUMN IF NOT EXISTS client_media_bundle_id uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.upload_session'::regclass
          AND conname = 'chk_upload_session_client_media_pair'
    ) THEN
        ALTER TABLE public.upload_session
            ADD CONSTRAINT chk_upload_session_client_media_pair
            CHECK ((client_media_bundle_id IS NULL) = (client_media_manifest IS NULL));
    END IF;
END
$$;

COMMIT;

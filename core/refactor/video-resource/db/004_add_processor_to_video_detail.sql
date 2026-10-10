-- =============================================================================
-- Migration: Add processor table + processor_id FK on video_detail
--
-- Reason: video_detail is an ingestion event record. Storing processor_id
-- captures WHO ran ffprobe and produced the metadata JSONB — a provenance fact
-- that is distinct from WHERE the file lives now (that is the vault's job).
--
-- This enables:
--   - Direct DB queries: WHERE processor_id = X (no URI parsing or vault joins)
--   - Audit trail: which machine / ffmpeg version produced this metadata
--   - Safe re-ingestion: new video_detail row per ingestion event, each with
--     its own processor_id — no drift, no update conflicts
--
-- Nullable: existing rows have no processor context; iframes never have one.
-- Safe to run: additive only — no existing column is altered or dropped.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Create processor table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.processor (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text        NOT NULL,
    hostname    text,
    status      text        NOT NULL DEFAULT 'active',
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.processor            IS 'Registered ingestion/processing nodes';
COMMENT ON COLUMN public.processor.name       IS 'Human-readable label (e.g. "mac-studio-local")';
COMMENT ON COLUMN public.processor.hostname   IS 'OS hostname at registration time';
COMMENT ON COLUMN public.processor.status     IS 'active | inactive | retired';


-- -----------------------------------------------------------------------------
-- 2. Add processor_id FK to video_detail
-- -----------------------------------------------------------------------------
ALTER TABLE public.video_detail
    ADD COLUMN IF NOT EXISTS processor_id uuid
        REFERENCES public.processor(id)
        ON DELETE SET NULL;

COMMENT ON COLUMN public.video_detail.processor_id IS
    'Processor that ran ffprobe and created this video_detail record. '
    'Answers "who analyzed this file", not "where is the file now" (that is the vault). '
    'NULL for legacy rows and iframe-only resources.';


-- -----------------------------------------------------------------------------
-- 3. Index for processor-scoped queries
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_video_detail_processor_id
    ON public.video_detail (processor_id)
    WHERE processor_id IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 4. Audit: how many existing rows will remain unlinked after this migration
-- -----------------------------------------------------------------------------
SELECT
    COUNT(*)                                            AS total_video_detail_rows,
    COUNT(*) FILTER (WHERE processor_id IS NOT NULL)   AS already_linked,
    COUNT(*) FILTER (WHERE processor_id IS NULL)        AS will_be_null
FROM public.video_detail;

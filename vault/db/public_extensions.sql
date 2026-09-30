-- =============================================================================
-- monkey-vault — extensions to the public schema
-- =============================================================================
-- Adds a slug column to the existing public.processor table.
-- The slug is used as PROCESSOR_ID in each monkey-vault instance's .env.
-- =============================================================================

ALTER TABLE public.processor
  ADD COLUMN IF NOT EXISTS slug TEXT UNIQUE;

CREATE INDEX IF NOT EXISTS idx_processor_slug ON public.processor(slug);

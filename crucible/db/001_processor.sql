-- =============================================================================
-- crucible — processor migration
-- =============================================================================
-- public.processor is kept as the authoritative table (old system still uses it).
-- This file adds the new Crucible columns to it, then creates
-- monkey_crucible.processor as a VIEW pointing at public.processor.
-- Crucible ORM queries via monkey_crucible schema; old ORM keeps querying public.
--
-- Run order: 001 (depends on 000_schema.sql)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: Add Crucible-specific columns to the existing public.processor table
-- ---------------------------------------------------------------------------

ALTER TABLE public.processor
  ADD COLUMN IF NOT EXISTS capacity      INT         NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS tags          TEXT[]      NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS heartbeat_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_task_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_processor_heartbeat
  ON public.processor (heartbeat_at)
  WHERE in_progress = true;

-- ---------------------------------------------------------------------------
-- Step 2: Expose public.processor through the monkey_crucible schema as a view
-- Crucible ORM creates clients with { db: { schema: 'monkey_crucible' } } and
-- queries .from('processor') — this view satisfies that without moving the table.
-- Writes through the view go directly to public.processor.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW monkey_crucible.processor AS
  SELECT * FROM public.processor;

-- =============================================================================
-- crucible — schema bootstrap
-- =============================================================================
-- Run this first before any other crucible DB file.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS monkey_crucible;

-- ---------------------------------------------------------------------------
-- Compatibility view (run AFTER tables are created in monkey_crucible)
-- Allows existing Node.js ORM code that queries public.processor to keep
-- working without changes during migration.
-- ---------------------------------------------------------------------------
-- CREATE OR REPLACE VIEW public.processor AS
--   SELECT * FROM monkey_crucible.processor;
--
-- CREATE OR REPLACE VIEW public.task AS
--   SELECT * FROM monkey_crucible.task;

-- =============================================================================
-- monkey-vault — PostgREST grants (Supabase)
-- =============================================================================
-- Run after schema.sql.
-- Also required in Supabase dashboard: API → Exposed schemas → add monkey_vault
-- =============================================================================

GRANT USAGE ON SCHEMA monkey_vault TO anon, authenticated, service_role;

-- service_role: full access (used by monkey-vault service via SUPABASE_SERVICE_KEY)
GRANT ALL ON ALL TABLES    IN SCHEMA monkey_vault TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA monkey_vault TO service_role;

-- anon / authenticated: read-only (tighten per table as needed)
GRANT SELECT ON ALL TABLES IN SCHEMA monkey_vault TO anon, authenticated;

-- Cover tables created after this grant is run
ALTER DEFAULT PRIVILEGES IN SCHEMA monkey_vault
  GRANT ALL ON TABLES TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA monkey_vault
  GRANT SELECT ON TABLES TO anon, authenticated;

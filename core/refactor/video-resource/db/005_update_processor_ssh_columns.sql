-- =============================================================================
-- Migration: Add SSH connection columns to processor table
--
-- Reason: standardize SSH connection string generation (ssh user@host) through
-- the processor table instead of hardcoded env vars. Supports local-first
-- routing with a public hostname fallback.
--
-- Changes:
--   ip_address  → renamed to local_host (covers IPs and hostnames)
--   + public_host  text  — public IP or domain, fallback when not on LAN
--   + ssh_user     text  — SSH username for this processor
--
-- Safe to run: ip_address rename is backward-compatible (same data, new name).
--   public_host and ssh_user are nullable — no existing rows broken.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Rename ip_address → local_host
--    local_host accepts both IPs (192.168.1.50) and hostnames (mac-studio.local)
-- -----------------------------------------------------------------------------
ALTER TABLE public.processor
    RENAME COLUMN ip_address TO local_host;

COMMENT ON COLUMN public.processor.local_host IS
    'Primary SSH target — LAN IP or mDNS hostname (e.g. 192.168.1.50 or mac-studio.local). '
    'Used when caller is on the same network as the processor.';


-- -----------------------------------------------------------------------------
-- 2. Add public hostname fallback
-- -----------------------------------------------------------------------------
ALTER TABLE public.processor
    ADD COLUMN IF NOT EXISTS public_host text;

COMMENT ON COLUMN public.processor.public_host IS
    'Fallback SSH target — public IP or domain (e.g. fabricio.server.com). '
    'Used when local_host is unreachable or caller is outside the LAN.';


-- -----------------------------------------------------------------------------
-- 3. Add SSH user
-- -----------------------------------------------------------------------------
ALTER TABLE public.processor
    ADD COLUMN IF NOT EXISTS ssh_user text;

COMMENT ON COLUMN public.processor.ssh_user IS
    'SSH username for this processor. Combined with local_host or public_host '
    'to build the connection prefix: "ssh {ssh_user}@{host}".';


-- -----------------------------------------------------------------------------
-- 4. Verify
-- -----------------------------------------------------------------------------
SELECT
    id,
    name,
    slug,
    local_host,
    public_host,
    ssh_user,
    enabled
FROM public.processor
ORDER BY id;

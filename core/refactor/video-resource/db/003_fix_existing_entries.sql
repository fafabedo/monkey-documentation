-- =============================================================================
-- Fix existing entries — run AFTER preflight audit, BEFORE column drop migrations
--
-- Prerequisites:
--   000_preflight_audit.sql reviewed — especially queries 1 and 4
--
-- This script links any video_resource rows that still have video_detail_id = NULL
-- (non-iframe) to their correct video_detail row, using a three-pass strategy
-- that mirrors the original backfill migration.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- PASS 1 — Exact match: video_id + codec + height + mime
-- -----------------------------------------------------------------------------
UPDATE public.video_resource vr
SET video_detail_id = vd.id
FROM public.video_detail vd
WHERE vr.video_detail_id IS NULL
  AND vr.mime <> 'iframe'
  AND vd.video   = vr.video_id
  AND vd.codec   = vr.codec
  AND vd.height  = vr.height
  AND vd.mime    = vr.mime;

-- Show how many were linked in Pass 1
SELECT
    'pass_1_exact' AS pass,
    COUNT(*)       AS matched
FROM public.video_resource
WHERE video_detail_id IS NOT NULL
  AND mime <> 'iframe';


-- -----------------------------------------------------------------------------
-- PASS 2 — Relaxed match: video_id + height only
--   Handles cases where mime drifted (e.g. video/mp4 stored as video/x-matroska).
-- -----------------------------------------------------------------------------
UPDATE public.video_resource vr
SET video_detail_id = vd.id
FROM public.video_detail vd
WHERE vr.video_detail_id IS NULL
  AND vr.mime <> 'iframe'
  AND vd.video  = vr.video_id
  AND vd.height = vr.height;

SELECT
    'pass_2_height_only' AS pass,
    COUNT(*)             AS still_unlinked
FROM public.video_resource
WHERE video_detail_id IS NULL
  AND mime <> 'iframe';


-- -----------------------------------------------------------------------------
-- PASS 3 — Closest-height tiebreaker for multi-detail videos
--   For videos that still have no match, pick the video_detail row whose height
--   is closest to the resource's height.
-- -----------------------------------------------------------------------------
UPDATE public.video_resource vr
SET video_detail_id = closest.detail_id
FROM (
    SELECT DISTINCT ON (vr2.id)
        vr2.id         AS resource_id,
        vd2.id         AS detail_id
    FROM public.video_resource vr2
    JOIN public.video_detail vd2 ON vd2.video = vr2.video_id
    WHERE vr2.video_detail_id IS NULL
      AND vr2.mime <> 'iframe'
    ORDER BY vr2.id,
             ABS(COALESCE(vd2.height, 0) - COALESCE(vr2.height, 0)) ASC,
             vd2.id DESC
) closest
WHERE vr.id = closest.resource_id;

SELECT
    'pass_3_closest_height' AS pass,
    COUNT(*)                AS still_unlinked
FROM public.video_resource
WHERE video_detail_id IS NULL
  AND mime <> 'iframe';


-- -----------------------------------------------------------------------------
-- POST-FIX: Backfill codec from metadata JSONB where codec IS NULL
--   Mirrors the null_codec fix from the original backfill (1,038 rows cleaned).
-- -----------------------------------------------------------------------------
UPDATE public.video_resource
SET codec = metadata->>'codec'
WHERE codec IS NULL
  AND metadata IS NOT NULL
  AND metadata->>'codec' IS NOT NULL;

SELECT
    'codec_backfill' AS step,
    COUNT(*)         AS rows_updated
FROM public.video_resource
WHERE codec IS NOT NULL
  AND metadata->>'codec' IS NOT NULL;


-- -----------------------------------------------------------------------------
-- FINAL AUDIT: Any rows still unlinked after all three passes.
--   If this returns rows, investigate manually before running column drop migrations.
-- -----------------------------------------------------------------------------
SELECT
    vr.id,
    vr.video_id,
    vr.mime,
    vr.resource_type,
    vr.height,
    vr.codec,
    vr.resource,
    v.title AS video_title
FROM public.video_resource vr
JOIN public.video v ON v.id = vr.video_id
WHERE vr.video_detail_id IS NULL
  AND vr.mime <> 'iframe'
ORDER BY vr.video_id, vr.id;

-- =============================================================================
-- Pre-flight audit — run BEFORE any migration
-- All queries are read-only. Review each result set before proceeding.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Non-iframe resources with video_detail_id IS NULL
--    These are unlinked and will lose metadata after the metadata column is dropped.
--    Expected: 0 rows. Any rows here must be fixed by 003_fix_existing_entries.sql
--    before running 001_drop_video_resource_metadata.sql.
-- -----------------------------------------------------------------------------
SELECT
    vr.id,
    vr.video_id,
    vr.mime,
    vr.resource_type,
    vr.height,
    vr.codec,
    vr.resource
FROM public.video_resource vr
WHERE vr.video_detail_id IS NULL
  AND vr.mime <> 'iframe'
ORDER BY vr.video_id, vr.id;


-- -----------------------------------------------------------------------------
-- 2. Videos that have ONLY legacy video_detail.public and no video_resource rows.
--    These will have no playable resource after video_detail.public is deprecated.
--    Expected: 0 rows for any active, published video.
-- -----------------------------------------------------------------------------
SELECT
    v.id       AS video_id,
    v.title,
    v.status,
    vd.id      AS video_detail_id,
    vd.public  IS NOT NULL AS has_legacy_public
FROM public.video v
LEFT JOIN public.video_detail vd ON vd.video = v.id
LEFT JOIN public.video_resource vr ON vr.video_id = v.id
WHERE vr.id IS NULL
  AND vd.public IS NOT NULL
ORDER BY v.id;


-- -----------------------------------------------------------------------------
-- 3. Videos with no video_resource rows AND no video_detail.public.
--    These have no resource at all — investigate before any migration.
-- -----------------------------------------------------------------------------
SELECT
    v.id    AS video_id,
    v.title,
    v.status
FROM public.video v
LEFT JOIN public.video_detail vd ON vd.video = v.id
LEFT JOIN public.video_resource vr ON vr.video_id = v.id
WHERE vr.id IS NULL
  AND (vd.public IS NULL OR vd.id IS NULL)
ORDER BY v.id;


-- -----------------------------------------------------------------------------
-- 4. Rows where video_resource.metadata differs from video_detail.metadata.
--    These are drift cases — the copied column got out of sync.
--    Expected: small number. Informational only; the column is being dropped.
-- -----------------------------------------------------------------------------
SELECT
    vr.id              AS resource_id,
    vr.video_id,
    vr.mime,
    vr.video_detail_id
FROM public.video_resource vr
JOIN public.video_detail vd ON vd.id = vr.video_detail_id
WHERE vr.metadata IS NOT NULL
  AND vr.metadata <> vd.metadata
ORDER BY vr.video_id;


-- -----------------------------------------------------------------------------
-- 5. Summary counts — overall health check
-- -----------------------------------------------------------------------------
SELECT
    COUNT(*)                                                    AS total_resources,
    COUNT(*) FILTER (WHERE video_detail_id IS NOT NULL)        AS linked_to_detail,
    COUNT(*) FILTER (WHERE video_detail_id IS NULL
                       AND mime <> 'iframe')                   AS unlinked_non_iframe,
    COUNT(*) FILTER (WHERE mime = 'iframe')                    AS iframe_resources,
    COUNT(*) FILTER (WHERE metadata IS NOT NULL)               AS has_metadata_copy,
    COUNT(*) FILTER (WHERE metadata IS NULL
                       AND mime <> 'iframe')                   AS missing_metadata_non_iframe
FROM public.video_resource;


-- -----------------------------------------------------------------------------
-- 6. Confirm synopsis column exists and check if any rows have data in it.
--    Expected: 0 rows with non-null synopsis (column is unused).
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS rows_with_synopsis
FROM public.video_detail
WHERE synopsis IS NOT NULL AND synopsis <> '';


-- -----------------------------------------------------------------------------
-- 7. processor_id coverage — run AFTER 004_add_processor_to_video_detail.sql
--    Shows how many video_detail rows have a processor linked vs. still NULL.
--    NULL rows are legacy ingestions — expected, not a blocker.
-- -----------------------------------------------------------------------------
SELECT
    COUNT(*)                                           AS total_rows,
    COUNT(*) FILTER (WHERE processor_id IS NOT NULL)  AS linked_to_processor,
    COUNT(*) FILTER (WHERE processor_id IS NULL)       AS unlinked_legacy
FROM public.video_detail;


-- -----------------------------------------------------------------------------
-- 8. List processors and how many video_detail rows each owns.
--    Useful to confirm new ingestions are being attributed correctly.
-- -----------------------------------------------------------------------------
SELECT
    p.id,
    p.name,
    p.hostname,
    p.status,
    COUNT(vd.id) AS video_detail_count
FROM public.processor p
LEFT JOIN public.video_detail vd ON vd.processor_id = p.id
GROUP BY p.id, p.name, p.hostname, p.status
ORDER BY video_detail_count DESC;

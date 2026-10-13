-- ============================================================
-- Backfill performer.last_upload_at and studio.last_upload_at
--
-- One-off script. last_upload_at was not being maintained, so most
-- rows still hold the column default (2020-01-01). This recomputes
-- it for every entity from video.created_at.
--
-- Semantics (matches recalculate_* functions):
--   performer.last_upload_at = MAX(created_at) of videos the
--                              performer appears in (video_performer)
--   studio.last_upload_at    = MAX(created_at) of videos directly
--                              under the studio (video.studio)
--
-- Entities with no videos are left untouched.
-- Safe to re-run (idempotent).
-- ============================================================

-- Performers
UPDATE performer p
SET    last_upload_at = sub.last_upload
FROM (
    SELECT vp.performer      AS performer_id,
           MAX(v.created_at) AS last_upload
    FROM   video_performer vp
    JOIN   video v ON vp.video = v.id
    GROUP  BY vp.performer
) sub
WHERE p.id = sub.performer_id;

-- Studios (direct videos only — same semantics as counter / visited)
UPDATE studio s
SET    last_upload_at = sub.last_upload
FROM (
    SELECT v.studio          AS studio_id,
           MAX(v.created_at) AS last_upload
    FROM   video v
    WHERE  v.studio IS NOT NULL
    GROUP  BY v.studio
) sub
WHERE s.id = sub.studio_id;

-- Parent studios: roll up from their children's videos as well,
-- so a parent with no direct videos reflects child activity.
UPDATE studio parent
SET    last_upload_at = GREATEST(parent.last_upload_at, sub.last_upload)
FROM (
    SELECT s.parent          AS parent_id,
           MAX(v.created_at) AS last_upload
    FROM   studio s
    JOIN   video v ON v.studio = s.id
    WHERE  s.parent IS NOT NULL
    GROUP  BY s.parent
) sub
WHERE parent.id = sub.parent_id;

-- Sanity check
-- SELECT 'performer' AS entity, count(*) FILTER (WHERE last_upload_at > '2020-01-01') AS updated, count(*) AS total FROM performer
-- UNION ALL
-- SELECT 'studio', count(*) FILTER (WHERE last_upload_at > '2020-01-01'), count(*) FROM studio;

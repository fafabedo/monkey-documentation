-- Migration: Drop video_detail.synopsis
--
-- Reason: synopsis is catalog-level data (belongs on video, not on the source file record).
-- The column is confirmed unused — synopsis is read from video_metadata via
-- VideoOrm.getVideoMetadata(video.id, "synopsis") in Load.js, not from this column.
--
-- Safe to run: column is nullable with no dependents.

ALTER TABLE public.video_detail
  DROP COLUMN IF EXISTS synopsis;

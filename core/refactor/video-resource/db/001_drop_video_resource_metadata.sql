-- Migration: Drop video_resource.metadata
--
-- Reason: video_resource.metadata was a denormalized copy of video_detail.metadata
-- written at backfill time. With video_detail_id FK in place, metadata is always
-- reachable via JOIN — the copy is no longer needed and creates drift risk.
--
-- Prerequisites before running:
--   1. ORM updated: retrieveVideoResourcesByVideoId uses JOIN video_detail!video_detail_id(metadata)
--   2. Load.js updated: retrieveVideoResources spreads metadata fields from the JOIN result
--   3. Ingestion pipeline no longer writes to video_resource.metadata
--
-- Safe to run: column is nullable; dropping it does not affect any NOT NULL constraint.

ALTER TABLE public.video_resource
  DROP COLUMN IF EXISTS metadata;

-- =============================================================================
-- crucible — monkey_crucible.task_type_registry
-- =============================================================================
-- Self-documenting registry of all available task handler slugs.
-- Manager uses this for validation and UI enumeration.
-- Run order: 002 (depends on 000_schema.sql)
-- =============================================================================

CREATE TABLE IF NOT EXISTS monkey_crucible.task_type_registry (
  slug                   TEXT        PRIMARY KEY,
  label                  TEXT        NOT NULL,
  description            TEXT,
  is_heavy               BOOLEAN     NOT NULL DEFAULT false,
  is_schedulable         BOOLEAN     NOT NULL DEFAULT false,
  default_timeout_secs   INT,
  default_retry_limit    INT         NOT NULL DEFAULT 0,
  required_metadata      JSONB,      -- JSON Schema fragment for validation
  enabled                BOOLEAN     NOT NULL DEFAULT true,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Seed: built-in task types
-- ---------------------------------------------------------------------------

INSERT INTO monkey_crucible.task_type_registry
  (slug, label, description, is_heavy, is_schedulable, default_timeout_secs, default_retry_limit)
VALUES
  ('backlog',                    'Backlog',                    'Initialize metadata template for a new task',                   false, false,   60, 0),
  ('adjust',                     'Adjust',                     'Manual gate: admin sets scrape link, title, and task options',  false, false, NULL, 0),
  ('rename',                     'Rename',                     'Rename file based on studio naming rules',                      false, false,   60, 0),
  ('dispatch',                   'Dispatch',                   'Assign task to a specific processor',                           false, false,   30, 0),
  ('draft_video',                'Draft Video',                'Create initial video record from file metadata',                 false, false,  120, 0),
  ('sort',                       'Sort',                       'Move file to studio-specific folder',                           false, false,  120, 1),
  ('scrape',                     'Scrape',                     'Fetch metadata from external scraper source',                   false, false,  300, 1),
  ('refine_title',               'Refine Title',               'Apply title normalization and video_key generation',            false, false,   60, 0),
  ('validate',                   'Validate',                   'Check codec, HLS presence, media, and preview status',          false, false,   60, 0),
  ('encode',                     'Encode',                     'Re-encode video file to HEVC target codec',                     true,  false, 7200, 1),
  ('generate_hls',               'Generate HLS',               'Generate HLS stream variants and manifest',                    true,  false, 3600, 1),
  ('generate_preview',           'Generate Preview',           'Create preview clip (WebM/MP4) from video',                    true,  false, 1800, 1),
  ('generate_preview_from_link', 'Generate Preview from Link', 'Download and convert preview clip from external URL',          true,  false, 1800, 1),
  ('extract_image',              'Extract Image',              'Pull thumbnail frames from video at specified timecodes',       true,  false,  300, 0),
  ('set_image',                  'Set Image',                  'Assign an image as the video thumbnail',                       false, false,   60, 0),
  ('collage_image',              'Collage Image',              'Composite multiple images into a single output',                true,  false,  600, 0),
  ('collage_video',              'Collage Video',              'Composite multiple video clips into a single output',           true,  false, 3600, 0),
  ('rewrite_video',              'Rewrite Video',              'Replace video file via rsync and refresh metadata via API',     false, false,  600, 1),
  ('publish',                    'Publish',                    'Finalize publication: status=1, index, rename to video_key',    false, false,  120, 0),
  ('task_clear',                 'Task Clear',                 'Archive and clean up completed tasks',                          false, true,   300, 0),
  ('temp_file_clear',            'Temp File Clear',            'Delete files from temp and trash processor folders',            false, true,   300, 0),
  ('delete_file',                'Delete File',                'Remove video file from filesystem',                             false, false,   60, 0),
  ('sync_video',                 'Sync Video',                 'Bi-directional sync of video metadata with external source',    false, true,   300, 1),
  ('scan_queue',                 'Scan Queue',                 'Scan processor queue folder and create backlog tasks for new files', false, true,  120, 0),
  ('mock_task',                  'Mock Task',                  'Test/placeholder handler — always returns success',             false, false,   10, 0)
ON CONFLICT (slug) DO UPDATE SET
  label                = EXCLUDED.label,
  description          = EXCLUDED.description,
  is_heavy             = EXCLUDED.is_heavy,
  is_schedulable       = EXCLUDED.is_schedulable,
  default_timeout_secs = EXCLUDED.default_timeout_secs,
  default_retry_limit  = EXCLUDED.default_retry_limit;

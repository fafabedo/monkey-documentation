-- =============================================================================
-- crucible — seed examples
-- =============================================================================
-- Concrete INSERT examples for task instances.
-- Run AFTER 000–008.
--
-- task.file uses vault URI schemes (temp://, queue://, hub://, etc.)
-- resolved at runtime by the processor that picks up the task.
-- processor_id = 10 is used as an example — replace with your actual id.
-- Run: SELECT id, name FROM public.processor; to find yours.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Processor setup: tag existing processors with Crucible capacity + tags
-- ---------------------------------------------------------------------------

-- UPDATE public.processor SET capacity = 2, tags = ARRAY['encoder', 'heavy']  WHERE id = 10;
-- UPDATE public.processor SET capacity = 3, tags = ARRAY['scraper', 'regular'] WHERE id = 11;

-- ---------------------------------------------------------------------------
-- 1. New file scanned from queue — full ingest, any processor
-- ---------------------------------------------------------------------------

INSERT INTO monkey_crucible.task
  (file, workflow_template_id, current_step_id, processor_id, status, step_status, weight, metadata)
SELECT
  'queue://studio-scene-001.mp4',
  wt.id,
  ws.id,
  NULL,
  'active',
  'pending',
  100,
  '{"validation": {}}'::jsonb
FROM monkey_crucible.workflow_template wt
JOIN monkey_crucible.workflow_step ws ON ws.workflow_id = wt.id
WHERE wt.slug = 'full_ingest'
ORDER BY ws.step_order ASC
LIMIT 1;

-- ---------------------------------------------------------------------------
-- 2. File pinned to processor 10, full ingest
-- ---------------------------------------------------------------------------

INSERT INTO monkey_crucible.task
  (file, workflow_template_id, current_step_id, processor_id, status, step_status, weight, metadata)
SELECT
  'queue://scene-002.mp4',
  wt.id,
  ws.id,
  10,
  'active',
  'pending',
  100,
  '{"validation": {}}'::jsonb
FROM monkey_crucible.workflow_template wt
JOIN monkey_crucible.workflow_step ws ON ws.workflow_id = wt.id
WHERE wt.slug = 'full_ingest'
ORDER BY ws.step_order ASC
LIMIT 1;

-- ---------------------------------------------------------------------------
-- 3. Video already drafted — scrape only, any processor
-- ---------------------------------------------------------------------------

INSERT INTO monkey_crucible.task
  (video_id, workflow_template_id, current_step_id, processor_id, status, step_status, weight, metadata)
SELECT
  417,
  wt.id,
  ws.id,
  NULL,
  'active',
  'pending',
  80,
  '{
    "scrape": {
      "force": true,
      "link":  "https://www.evilangel.com/en/video/example-scene/417"
    }
  }'::jsonb
FROM monkey_crucible.workflow_template wt
JOIN monkey_crucible.workflow_step ws ON ws.workflow_id = wt.id
WHERE wt.slug = 'scrape_only'
  AND ws.task_type = 'scrape'
LIMIT 1;

-- ---------------------------------------------------------------------------
-- 4. Encode-only — file in temp, pinned to processor 10 (encoder)
-- ---------------------------------------------------------------------------

INSERT INTO monkey_crucible.task
  (video_id, file, workflow_template_id, current_step_id, processor_id, status, step_status, weight, metadata)
SELECT
  418,
  'temp://scene-418-raw.mkv',
  wt.id,
  ws.id,
  10,
  'active',
  'pending',
  50,
  '{"encode": {"force": true}}'::jsonb
FROM monkey_crucible.workflow_template wt
JOIN monkey_crucible.workflow_step ws ON ws.workflow_id = wt.id
WHERE wt.slug = 'encode_only'
  AND ws.task_type = 'encode'
LIMIT 1;

-- ---------------------------------------------------------------------------
-- 5. Scheduled file cleanse — cron, any processor, low priority
-- ---------------------------------------------------------------------------

INSERT INTO monkey_crucible.task
  (workflow_template_id, current_step_id, processor_id, status, step_status,
   schedule_type, frequency, next_execution, weight, metadata)
SELECT
  wt.id,
  ws.id,
  NULL,
  'active',
  'pending',
  'cron',
  '0 0 * * *',
  (now() AT TIME ZONE 'UTC')::date + interval '1 day',
  200,
  '{}'::jsonb
FROM monkey_crucible.workflow_template wt
JOIN monkey_crucible.workflow_step ws ON ws.workflow_id = wt.id
WHERE wt.slug = 'file_cleanse'
ORDER BY ws.step_order ASC
LIMIT 1;

-- ---------------------------------------------------------------------------
-- 6. Validation only — video with partial metadata
-- ---------------------------------------------------------------------------

INSERT INTO monkey_crucible.task
  (video_id, workflow_template_id, current_step_id, processor_id, status, step_status, weight, metadata)
SELECT
  420,
  wt.id,
  ws.id,
  NULL,
  'active',
  'pending',
  90,
  '{
    "validation": {
      "codec":   true,
      "hls":     true,
      "media":   false,
      "preview": false
    }
  }'::jsonb
FROM monkey_crucible.workflow_template wt
JOIN monkey_crucible.workflow_step ws ON ws.workflow_id = wt.id
WHERE wt.slug = 'validation'
  AND ws.task_type = 'validate'
LIMIT 1;

-- ---------------------------------------------------------------------------
-- 7. Preview from temp file — pinned to processor 10
-- ---------------------------------------------------------------------------

INSERT INTO monkey_crucible.task
  (video_id, file, workflow_template_id, current_step_id, processor_id, status, step_status, weight, metadata)
SELECT
  421,
  'temp://scene-421.mp4',
  wt.id,
  ws.id,
  10,
  'active',
  'pending',
  100,
  '{
    "preview": {
      "force":    true,
      "codec":    "libx264",
      "format":   "mp4",
      "segments": [30, 60, 90]
    }
  }'::jsonb
FROM monkey_crucible.workflow_template wt
JOIN monkey_crucible.workflow_step ws ON ws.workflow_id = wt.id
WHERE wt.slug = 'encode_only'
  AND ws.task_type = 'generate_preview'
LIMIT 1;

-- ---------------------------------------------------------------------------
-- Custom workflow: scrape then preview (creates template + steps if new)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  wf_id BIGINT;
BEGIN
  INSERT INTO monkey_crucible.workflow_template (name, slug, description, weight)
  VALUES ('Scrape + Preview', 'scrape_and_preview', 'Scrape metadata then generate preview', 100)
  ON CONFLICT (slug) DO NOTHING
  RETURNING id INTO wf_id;

  IF wf_id IS NOT NULL THEN
    INSERT INTO monkey_crucible.workflow_step
      (workflow_id, task_type, step_order, label, is_final, config)
    VALUES
      (wf_id, 'scrape',           10, 'Scrape',           false, '{"scrape": {"force": true}}'),
      (wf_id, 'refine_title',     20, 'Refine Title',     false, '{}'),
      (wf_id, 'generate_preview', 30, 'Generate Preview', true,  '{"preview": {"codec": "libvpx-vp9"}}');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- scan_queue workflow + scheduled task
-- Creates a single-step workflow that runs ScanQueue on a cron.
-- One task row per processor — each processor scans its own queue folder.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  wf_id   BIGINT;
  step_id BIGINT;
BEGIN
  -- Workflow template
  INSERT INTO monkey_crucible.workflow_template (name, slug, description, weight)
  VALUES ('Scan Queue', 'scan_queue', 'Scan processor queue folder and queue new files for backlog', 50)
  ON CONFLICT (slug) DO NOTHING
  RETURNING id INTO wf_id;

  IF wf_id IS NULL THEN
    SELECT id INTO wf_id FROM monkey_crucible.workflow_template WHERE slug = 'scan_queue';
  END IF;

  -- Single schedulable step (no is_final because reschedule_task resets to step 1 on cron)
  INSERT INTO monkey_crucible.workflow_step
    (workflow_id, task_type, step_order, label, is_schedulable, is_final, config)
  VALUES
    (wf_id, 'scan_queue', 10, 'Scan Queue', true, true, '{}')
  ON CONFLICT DO NOTHING
  RETURNING id INTO step_id;

  IF step_id IS NULL THEN
    SELECT id INTO step_id FROM monkey_crucible.workflow_step
    WHERE workflow_id = wf_id AND task_type = 'scan_queue';
  END IF;

  -- One cron task pinned to processor 10 — runs every minute.
  -- Add one row per processor that should scan its own queue folder.
  -- Replace processor_id = 10 with the actual processor id.
  INSERT INTO monkey_crucible.task
    (workflow_template_id, current_step_id, processor_id,
     status, step_status, schedule_type, frequency, next_execution, weight)
  VALUES
    (wf_id, step_id, 10,
     'active', 'pending', 'cron', '* * * * *', now(), 50)
  ON CONFLICT DO NOTHING;
END $$;

-- ---------------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------------

SELECT
  t.id,
  t.video_id,
  t.file,
  t.processor_id,
  t.status,
  t.step_status,
  t.schedule_type,
  t.frequency,
  t.weight,
  wt.slug        AS workflow,
  ws.task_type   AS current_step,
  ws.step_order
FROM monkey_crucible.task t
JOIN monkey_crucible.workflow_template wt ON wt.id = t.workflow_template_id
JOIN monkey_crucible.workflow_step     ws ON ws.id = t.current_step_id
ORDER BY t.id;

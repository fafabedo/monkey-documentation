-- =============================================================================
-- crucible — adjust step migration
-- =============================================================================
-- Run this against an existing Crucible database (after 000–009 are applied).
-- Safe to re-run (all statements are idempotent).
-- =============================================================================

-- 1. Add is_manual column to workflow_step
ALTER TABLE monkey_crucible.workflow_step
  ADD COLUMN IF NOT EXISTS is_manual BOOLEAN NOT NULL DEFAULT false;

-- 2. Add 'waiting' to the step_status check constraint on task.
--    PostgreSQL requires dropping and re-adding the constraint.
ALTER TABLE monkey_crucible.task
  DROP CONSTRAINT IF EXISTS task_step_status_check;

ALTER TABLE monkey_crucible.task
  ADD CONSTRAINT task_step_status_check
  CHECK (step_status IN ('pending','running','success','failed','skipped','waiting'));

-- 3. Register the adjust task type
INSERT INTO monkey_crucible.task_type_registry
  (slug, label, description, is_heavy, is_schedulable, default_timeout_secs, default_retry_limit)
VALUES
  ('adjust', 'Adjust', 'Manual gate: admin sets scrape link, title, and task options', false, false, NULL, 0)
ON CONFLICT (slug) DO UPDATE SET
  label       = EXCLUDED.label,
  description = EXCLUDED.description;

-- 4. Add adjust step to full_ingest workflow (between rename=20 and dispatch=30)
DO $$
DECLARE wf_id BIGINT;
BEGIN
  SELECT id INTO wf_id FROM monkey_crucible.workflow_template WHERE slug = 'full_ingest';
  IF wf_id IS NOT NULL THEN
    INSERT INTO monkey_crucible.workflow_step
      (workflow_id, task_type, step_order, label, is_final, is_heavy, is_manual)
    VALUES
      (wf_id, 'adjust', 25, 'Adjust', false, false, true)
    ON CONFLICT (workflow_id, step_order) DO UPDATE SET
      task_type = EXCLUDED.task_type,
      label     = EXCLUDED.label,
      is_manual = EXCLUDED.is_manual;
  END IF;
END $$;

-- 5. Recreate view_task_queue to include step_is_manual.
--    acquire_task_batch returns SETOF view_task_queue so it depends on the view type.
--    CASCADE drops that function too; we recreate it immediately after.
DROP VIEW IF EXISTS monkey_crucible.view_task_queue CASCADE;
CREATE VIEW monkey_crucible.view_task_queue AS
SELECT
  t.id                    AS task_id,
  t.video_id,
  t.file,
  t.status,
  t.step_status,
  t.weight,
  t.enabled,
  t.manual_mode,
  t.sorted,
  t.schedule_type,
  t.frequency,
  t.next_execution,
  t.last_executed_at,
  t.attempt_count,
  t.metadata,
  t.result,
  t.processor_id,
  t.locked_by,
  t.locked_at,
  t.created_at,
  t.updated_at,
  t.completed_at,
  s.id                    AS step_id,
  s.task_type             AS step_task_type,
  s.step_order,
  s.label                 AS step_label,
  s.is_final              AS step_is_final,
  s.is_heavy              AS step_is_heavy,
  s.is_schedulable        AS step_is_schedulable,
  s.is_manual             AS step_is_manual,
  s.weight                AS step_weight,
  s.retry_limit           AS step_retry_limit,
  s.timeout_seconds       AS step_timeout_seconds,
  s.config                AS step_config,
  wt.id                   AS workflow_template_id,
  wt.name                 AS workflow_name,
  wt.slug                 AS workflow_slug,
  wt.weight               AS workflow_weight
FROM monkey_crucible.task t
LEFT JOIN monkey_crucible.workflow_step     s  ON s.id  = t.current_step_id
LEFT JOIN monkey_crucible.workflow_template wt ON wt.id = t.workflow_template_id;

-- 6. Recreate acquire_task_batch (dropped by CASCADE above)
CREATE OR REPLACE FUNCTION monkey_crucible.acquire_task_batch(
  p_processor_id  BIGINT,
  p_mode          TEXT,
  p_limit         INT DEFAULT 5
)
RETURNS SETOF monkey_crucible.view_task_queue
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  WITH acquired AS (
    UPDATE monkey_crucible.task t
    SET
      locked_by     = p_processor_id,
      locked_at     = now(),
      step_status   = 'running',
      attempt_count = attempt_count + 1,
      updated_at    = now()
    WHERE t.id IN (
      SELECT vt.task_id
      FROM monkey_crucible.view_task_queue vt
      WHERE (vt.processor_id IS NULL OR vt.processor_id = p_processor_id)
        AND vt.status       = 'active'
        AND vt.step_status  = 'pending'
        AND vt.enabled      = true
        AND vt.manual_mode  = false
        AND vt.locked_by    IS NULL
        AND NOT vt.step_is_manual
        AND CASE p_mode
              WHEN 'regular'   THEN NOT vt.step_is_heavy AND NOT vt.step_is_schedulable
              WHEN 'heavy'     THEN vt.step_is_heavy AND NOT vt.step_is_schedulable
              WHEN 'scheduled' THEN vt.step_is_schedulable
                                    AND (vt.next_execution IS NULL OR vt.next_execution <= now())
              ELSE false
            END
      ORDER BY vt.weight ASC, vt.step_weight ASC, vt.updated_at ASC
      LIMIT p_limit
    )
    RETURNING t.id
  )
  SELECT vq.*
  FROM monkey_crucible.view_task_queue vq
  INNER JOIN acquired a ON a.id = vq.task_id;
END;
$$;

-- Verify: show the full_ingest step order
SELECT step_order, task_type, label, is_manual, is_heavy, is_final
FROM monkey_crucible.workflow_step ws
JOIN monkey_crucible.workflow_template wt ON wt.id = ws.workflow_id
WHERE wt.slug = 'full_ingest'
ORDER BY step_order;

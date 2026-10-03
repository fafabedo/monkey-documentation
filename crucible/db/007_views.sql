-- =============================================================================
-- crucible — views
-- =============================================================================
-- view_task_queue: the main query surface for Manager.acquireTaskBatch().
-- Joins task → workflow_step → workflow_template → processor for all fields
-- needed to route, acquire, and execute a task in a single query.
-- Run order: 007 (depends on all prior files)
-- =============================================================================

CREATE OR REPLACE VIEW monkey_crucible.view_task_queue AS
SELECT
  -- task core
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

  -- current step
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

  -- workflow template
  wt.id                   AS workflow_template_id,
  wt.name                 AS workflow_name,
  wt.slug                 AS workflow_slug,
  wt.weight               AS workflow_weight

FROM monkey_crucible.task t
LEFT JOIN monkey_crucible.workflow_step     s  ON s.id  = t.current_step_id
LEFT JOIN monkey_crucible.workflow_template wt ON wt.id = t.workflow_template_id;

-- ---------------------------------------------------------------------------
-- view_processor_health — used by UI and stale-lock sweep
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW monkey_crucible.view_processor_health AS
SELECT
  p.id,
  p.name,
  p.enabled,
  p.in_progress,
  p.breaker,
  p.capacity,
  p.tags,
  p.heartbeat_at,
  p.last_task_at,
  CASE
    WHEN p.heartbeat_at IS NULL                          THEN 'never_started'
    WHEN p.heartbeat_at < now() - interval '5 minutes'  THEN 'stale'
    WHEN p.in_progress                                   THEN 'running'
    ELSE 'idle'
  END AS health_status,
  (SELECT count(*) FROM monkey_crucible.task t WHERE t.locked_by = p.id) AS locked_task_count
FROM monkey_crucible.processor p;

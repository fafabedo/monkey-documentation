-- =============================================================================
-- crucible — RPC functions (Supabase callable)
-- =============================================================================
-- All functions live in monkey_crucible schema and are SECURITY DEFINER.
-- Called by Manager.js via client.schema('monkey_crucible').rpc('fn_name', {}).
-- Run order: 008 (depends on all prior files)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- acquire_task_batch
-- Atomically locks up to p_limit tasks for a given processor and mode.
-- Returns acquired task rows via view_task_queue.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monkey_crucible.acquire_task_batch(
  p_processor_id  BIGINT,
  p_mode          TEXT,    -- 'regular' | 'heavy' | 'scheduled'
  p_limit         INT      DEFAULT 5
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

-- ---------------------------------------------------------------------------
-- advance_task_step
-- Move task to the next step. Marks completed when no next step exists.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monkey_crucible.advance_task_step(
  p_task_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_task         monkey_crucible.task%ROWTYPE;
  v_current_step monkey_crucible.workflow_step%ROWTYPE;
  v_next_step    monkey_crucible.workflow_step%ROWTYPE;
BEGIN
  SELECT * INTO v_task FROM monkey_crucible.task WHERE id = p_task_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'task not found', 'task_id', p_task_id);
  END IF;

  SELECT * INTO v_current_step FROM monkey_crucible.workflow_step WHERE id = v_task.current_step_id;

  SELECT * INTO v_next_step
  FROM monkey_crucible.workflow_step
  WHERE workflow_id = v_current_step.workflow_id
    AND step_order  > v_current_step.step_order
  ORDER BY step_order ASC
  LIMIT 1;

  IF FOUND AND NOT v_current_step.is_final THEN
    UPDATE monkey_crucible.task SET
      current_step_id  = v_next_step.id,
      step_status      = 'pending',
      locked_by        = NULL,
      locked_at        = NULL,
      last_executed_at = now(),
      updated_at       = now()
    WHERE id = p_task_id;

    RETURN jsonb_build_object(
      'action',    'advanced',
      'next_step', v_next_step.id,
      'task_type', v_next_step.task_type
    );
  ELSE
    UPDATE monkey_crucible.task SET
      status           = 'completed',
      step_status      = 'success',
      locked_by        = NULL,
      locked_at        = NULL,
      last_executed_at = now(),
      completed_at     = now(),
      updated_at       = now()
    WHERE id = p_task_id;

    RETURN jsonb_build_object('action', 'completed');
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- release_task_lock
-- Release the lock on a task after step execution.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monkey_crucible.release_task_lock(
  p_task_id  BIGINT,
  p_status   TEXT,          -- 'success' | 'failed' | 'skipped'
  p_result   JSONB DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE monkey_crucible.task SET
    step_status = p_status,
    result      = p_result,
    locked_by   = NULL,
    locked_at   = NULL,
    updated_at  = now()
  WHERE id = p_task_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- release_stale_locks
-- Called on Manager startup. Releases locks from processors with stale
-- heartbeats. Returns count of tasks unlocked.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monkey_crucible.release_stale_locks(
  p_stale_after_minutes INT DEFAULT 5
)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_count INT;
BEGIN
  WITH stale_processors AS (
    SELECT id FROM public.processor
    WHERE heartbeat_at < now() - (p_stale_after_minutes || ' minutes')::INTERVAL
      AND in_progress = true
  ),
  released AS (
    UPDATE monkey_crucible.task SET
      locked_by     = NULL,
      locked_at     = NULL,
      step_status   = 'pending',
      attempt_count = GREATEST(attempt_count - 1, 0),
      updated_at    = now()
    WHERE locked_by IN (SELECT id FROM stale_processors)
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM released;

  UPDATE public.processor SET
    in_progress = false
  WHERE heartbeat_at < now() - (p_stale_after_minutes || ' minutes')::INTERVAL
    AND in_progress = true;

  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- reschedule_task
-- For cron tasks: reset to first step with a new next_execution timestamp.
-- The cron calculation is done in application code; pass the result here.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monkey_crucible.reschedule_task(
  p_task_id        BIGINT,
  p_next_execution TIMESTAMPTZ
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_workflow_id   BIGINT;
  v_first_step_id BIGINT;
BEGIN
  SELECT workflow_template_id INTO v_workflow_id
  FROM monkey_crucible.task WHERE id = p_task_id;

  SELECT id INTO v_first_step_id
  FROM monkey_crucible.workflow_step
  WHERE workflow_id = v_workflow_id
  ORDER BY step_order ASC
  LIMIT 1;

  UPDATE monkey_crucible.task SET
    current_step_id  = v_first_step_id,
    step_status      = 'pending',
    status           = 'active',
    locked_by        = NULL,
    locked_at        = NULL,
    next_execution   = p_next_execution,
    last_executed_at = now(),
    updated_at       = now()
  WHERE id = p_task_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- processor_heartbeat
-- Called every 30s by a running Manager. Updates heartbeat_at.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monkey_crucible.processor_heartbeat(
  p_processor_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.processor SET
    heartbeat_at = now(),
    in_progress  = true,
    updated_at   = now()
  WHERE id = p_processor_id;
END;
$$;

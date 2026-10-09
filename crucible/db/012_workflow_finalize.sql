-- =============================================================================
-- crucible — full_ingest: move is_final to validate + configure validation
-- =============================================================================
-- publish was the terminal step, but encode → generate_hls → validate must
-- run after it. This migration:
--   1. Removes is_final from publish so the chain continues.
--   2. Sets is_final on validate — the real terminal step.
--   3. Configures the validate step with what full_ingest should check.
--
-- The `validate` key in step config is merged into task.metadata at runtime
-- (via buildCompatTask) and read by Validate.retrieveValidationConfig().
-- It uses a different key (`validate`) from the runtime marker (`validation`)
-- set by previous steps, so the two never conflict.
--
-- Run order: 012 (depends on 004 workflow_step)
-- =============================================================================

DO $$
DECLARE wf_id BIGINT;
BEGIN
  SELECT id INTO wf_id FROM monkey_crucible.workflow_template WHERE slug = 'full_ingest';

  -- publish is no longer the end of the workflow
  UPDATE monkey_crucible.workflow_step
  SET    is_final = false
  WHERE  task_type = 'publish' AND workflow_id = wf_id;

  -- validate is the terminal step
  UPDATE monkey_crucible.workflow_step
  SET    is_final = true,
         config   = '{"validate": {"codec": true, "media": true, "preview": true}}'::jsonb
  WHERE  task_type = 'validate' AND workflow_id = wf_id;
END $$;

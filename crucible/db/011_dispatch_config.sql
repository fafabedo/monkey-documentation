-- =============================================================================
-- crucible — dispatch step config: assign repository processor
-- =============================================================================
-- Sets the default dispatch target for the full_ingest workflow.
-- The `dispatch.processor_id` key is read by Dispatch.retrieveProcessorDefault()
-- before falling back to the running processor's metadata or the interactive prompt.
--
-- To reassign to a different repository processor, update this config value.
-- When multiple repository processors exist, switch to role-based dispatch and
-- set: config = '{"dispatch": {"strategy": "role", "role": "repository"}}'
--
-- Run order: 011 (depends on 004 workflow_step)
-- =============================================================================

UPDATE monkey_crucible.workflow_step
SET    config = '{"dispatch": {"processor_id": 3}}'::jsonb
WHERE  task_type   = 'dispatch'
  AND  workflow_id = (
         SELECT id FROM monkey_crucible.workflow_template WHERE slug = 'full_ingest'
       );

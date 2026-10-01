# Crucible — Task Runner & Workflow Engine

**Crucible** is a multi-processor, workflow-based task orchestration system for video processing pipelines. Tasks flow through ordered workflow steps, processors compete to acquire them, and cron scheduling handles recurring work — all without manual intervention.

The name reflects the intent: raw inputs enter, controlled processing transforms them, finished output emerges.

---

## Core Concepts

### Task Type (Handler)
A registered, reusable function/script that performs a single unit of work — `encode`, `scrape`, `sort`, `validate`, `publish`, etc. Handlers are identified by a slug and loaded dynamically at runtime.

### Workflow Template
A named, reusable sequence of steps. Example: `full_ingest` runs 12 steps from `backlog` to `publish`. Templates are defined once and instantiated as many tasks as needed.

### Workflow Step
One node in a template. Steps have an explicit order (`step_order: 10, 20, 30`), a `task_type` slug, weight, and optional per-step config that merges into the task's metadata at runtime. Gap-numbered to allow insertion without renumbering.

### Task
An instance of a workflow for a specific entity (video, file). Tracks which step it's currently on, its status, which processor holds it, and a full metadata scratchpad.

### Processor
A machine/worker process. Registers itself with a heartbeat. Picks up tasks where `processor_id IS NULL` (any processor) or `processor_id = me`. Multiple processors can run simultaneously without coordination — the lock is on the task row.

---

## Execution Flow

```
yarn tm run
  ↓
Manager.start()
  registerProcessor()          -- upsert row, clear own stale locks
  heartbeatLoop(30s)           -- background: UPDATE processor SET heartbeat_at = now()
  staleLockSweep()             -- release locks from processors with heartbeat > 5min old
  ↓
for mode in [regular, heavy, scheduled]:
  ↓
  acquireTaskBatch(mode, limit)
    -- Atomic UPDATE … RETURNING to avoid race:
    UPDATE task
    SET locked_by = $me,
        locked_at = now(),
        step_status = 'running',
        attempt_count = attempt_count + 1
    WHERE id IN (
      SELECT id FROM view_task_queue
      WHERE (processor_id IS NULL OR processor_id = $me)
        AND step_is_heavy = $isHeavy
        AND status = 'active'
        AND step_status = 'pending'
        AND enabled = true
        AND (schedule_type = 'once' OR next_execution <= now())
        AND locked_by IS NULL
      ORDER BY weight ASC, step_weight ASC, updated_at ASC
      LIMIT $limit
    )
    RETURNING *
  ↓
  for each task:
    handler  = loadHandler(task_type_slug)
    config   = merge(step.config, task.metadata)   -- step.config wins on conflicts
    result   = await handler.run(task, config)
    ↓
    logStepExecution(task, result)                 -- insert task_step_log row
    ↓
    if result.success:
      nextStep = getNextStep(task)
      if nextStep:
        advanceTask(task, nextStep)                -- update current_step_id, step_status='pending'
      else (is_final):
        completeTask(task)                         -- status='completed', completed_at=now()
      if schedule_type = 'cron':
        reschedule(task)                           -- next_execution = cronNext(), reset to step 1
    else:
      if attempt_count < step.retry_limit:
        requeueForRetry(task)                      -- step_status='pending', backoff delay
      else:
        failTask(task)                             -- step_status='failed', status='failed'
    ↓
    releaseLock(task)
```

---

## Task Status Machine

```
            created
               ↓
            active  ──────────────────────────────────── paused
               ↓                                            ↓
     ┌─── running ───────────────────────────────────── disabled
     │         │
     │    step_status:
     │      pending → running → success → [next step] → … → completed
     │                        ↘ failed → retry? → failed (final)
     │
     └──────────────────────────────────────────────── cancelled
```

**task.status** tracks overall lifecycle: `active | paused | disabled | hidden | completed | failed | cancelled`

**task.step_status** tracks the current step: `pending | running | success | failed | skipped`

---

## Scheduling

Each task has a `schedule_type`:

| Type | Behavior |
|---|---|
| `once` | Run when eligible, mark completed after final step |
| `cron` | After final step, recalculate `next_execution` from `frequency` expression and reset to step 1 |

Cron expressions follow standard 5-field format (`*/10 * * * *`). Parsed via `CronExpressionParser`.

---

## Processor Assignment

| `processor_id` | Behavior |
|---|---|
| `NULL` | Any processor with capacity can pick it up |
| `<id>` | Only that specific processor will run it |

Processors self-register on startup. Heartbeat loop updates `heartbeat_at` every 30s. Manager sweeps for stale locks (heartbeat > 5min) and releases them automatically — no manual `unlock` command needed.

---

## Priority & Weight

Two levels:
1. **`task.weight`** — overall task priority (lower = higher priority). Default 100.
2. **`workflow_step.weight`** — step priority within same workflow (lower = higher priority). Default 100.

Queue order: `weight ASC, step_weight ASC, updated_at ASC`

---

## Queues (Modes)

Three independent execution queues — each run capped at `--max`:

| Mode | Flag | Condition |
|---|---|---|
| **Regular** | `--regular` | `step.is_heavy = false AND step.is_schedulable = false` |
| **Heavy** | `--heavy` | `step.is_heavy = true` |
| **Scheduled** | `--cron` | `step.is_schedulable = true AND next_execution <= now()` |

---

## Predefined Workflow Templates

| Slug | Steps |
|---|---|
| `full_ingest` | backlog → rename → dispatch → draft_video → sort → encode → generate_hls → scrape → refine_title → generate_preview → validate → publish |
| `scrape_only` | scrape → refine_title → validate |
| `encode_only` | encode → generate_hls → validate |
| `validation` | validate |
| `file_cleanse` | temp_file_clear → task_clear |
| `sync_local` | copy_file_to_local → validate → sort |
| `scan` | backlog → validate → draft_video |

---

## Registered Task Types

| Slug | Heavy | Schedulable | Description |
|---|---|---|---|
| `backlog` | no | no | Initialize metadata template for new task |
| `rename` | no | no | Rename file based on studio rules |
| `dispatch` | no | no | Assign task to processor |
| `draft_video` | no | no | Create initial video record from file |
| `sort` | no | no | Move file to studio folder |
| `scrape` | no | no | Fetch metadata from external scraper |
| `refine_title` | no | no | Apply title normalization rules |
| `validate` | no | no | Check codec, HLS, media, preview presence |
| `encode` | yes | no | Re-encode video to HEVC |
| `generate_hls` | yes | no | Generate HLS stream variants |
| `generate_preview` | yes | no | Create preview clips |
| `generate_preview_from_link` | yes | no | Download and convert preview from URL |
| `extract_image` | yes | no | Pull thumbnails from video frames |
| `set_image` | no | no | Assign image as video thumbnail |
| `collage_image` | yes | no | Composite multiple images |
| `collage_video` | yes | no | Composite video clips |
| `rewrite_video` | no | no | Replace video file and refresh metadata |
| `publish` | no | no | Finalize publication, index, rename to video_key |
| `task_clear` | no | yes | Archive completed tasks |
| `temp_file_clear` | no | yes | Clean up temp/trash folders |
| `delete_file` | no | no | Remove video file from filesystem |
| `sync_video` | no | yes | Bi-directional sync with external source |
| `mock_task` | no | no | Test/placeholder — always returns success |

---

## File Structure

```
venux-library/
  Processor/
    Manager.js                  -- orchestration loop, lock acquisition, heartbeat
    Task/
      AbstractTask.js           -- base class: lock, unlock, advance, log
      Encode.js                 -- handler: encode
      Scrape.js                 -- handler: scrape
      Publish.js                -- handler: publish
      … (one file per task type)
  ORM/
    Task.js                     -- task table queries + view_task_queue
    Workflow.js                 -- workflow_template + workflow_step queries
    Processor.js                -- processor registration + heartbeat
```

---

## Schema

All tables live in the `monkey_crucible` schema. Cross-schema FK to `public.video` is valid in Postgres. Compatibility views (`public.processor`, `public.task`) preserve existing ORM code without changes during migration.

## Database Files

See [`db/`](./db/) for full schema (run in order):

| File | Contents |
|---|---|
| `000_schema.sql` | `CREATE SCHEMA monkey_crucible` + compat view stubs |
| `001_processor.sql` | `monkey_crucible.processor` + `public.processor` compat view |
| `002_task_type_registry.sql` | Handler registry + seed data |
| `003_workflow_template.sql` | Named workflow templates + seed data |
| `004_workflow_step.sql` | Ordered steps per template + full seed |
| `005_task.sql` | Task table + indexes + `public.task` compat view |
| `006_task_step_log.sql` | Per-execution audit log + indexes |
| `007_views.sql` | `view_task_queue`, `view_processor_health` |
| `008_rpc_functions.sql` | Supabase RPC helpers (acquire, advance, release, heartbeat) |

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| **`step_order` integer over linked-list `prior`** | Explicit order allows insertion without chain repair; easier to query "next step" |
| **Row-level lock on task (`locked_by`)** | Multiple processors compete safely; no coordinator needed |
| **Heartbeat + stale-lock sweep** | Handles crashed processors automatically — no manual `unlock` |
| **`!err.response` as retry-on-fallback gate** | Only retry on network errors, not HTTP 4xx/5xx (server received and processed the request) |
| **Step config merged into task metadata** | Step defines defaults; task overrides at instance level |
| **Gap-numbered `step_order` (10, 20, 30…)** | New steps insertable without renumbering the entire chain |
| **`task_type_registry` table** | Single source of truth for UI, validation, and documentation |

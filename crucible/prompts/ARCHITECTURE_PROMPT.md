# Crucible — Architecture & Implementation Prompt

Use this document to implement, extend, port, or integrate the Crucible task runner into another application, language, or AI coding session. It is fully self-contained and describes the complete design rationale, database schema, execution model, and key decisions.

---

## What is Crucible?

**Crucible** is a multi-processor, workflow-based task orchestration system for video processing pipelines. It runs as a Node.js CLI process (`yarn tm run`) on one or more machines simultaneously.

Core responsibilities:
- Maintain a queue of **tasks**, each progressing through ordered **workflow steps**
- Distribute work across **processors** without a coordinator — processors compete for row-level locks
- Support two execution profiles: **regular** (lightweight) and **heavy** (CPU/IO-intensive)
- Support **cron-scheduled** tasks that repeat on a cadence
- Recover automatically from crashed processors via heartbeat + stale-lock sweep
- Provide a full per-step **audit log** of every execution attempt

The system replaces a simpler linear-chain workflow system with: explicit step ordering, row-level locking, heartbeat-based crash recovery, retry limits per step, and a structured audit trail.

---

## System Entities

### 1. task_type_registry
A static catalog of all available handler slugs. Each slug maps to a concrete JavaScript class file (`Encode.js`, `Scrape.js`, etc.). The registry documents capability flags and default timeouts.

Key fields: `slug` (PK), `is_heavy`, `is_schedulable`, `default_timeout_secs`, `default_retry_limit`

### 2. workflow_template
A named, reusable workflow definition. Example: `full_ingest`, `scrape_only`, `file_cleanse`. Templates are instantiated into task rows.

Key fields: `id`, `slug` (unique), `name`, `weight` (priority vs other workflows), `enabled`

### 3. workflow_step
One node in a workflow template. Steps are explicitly ordered via `step_order` (gap-numbered: 10, 20, 30) so new steps can be inserted without renumbering. Each step specifies a `task_type` slug and optional `config` JSONB that is merged into the task's metadata at runtime.

Key fields: `workflow_id` (FK), `task_type`, `step_order`, `is_final`, `is_heavy`, `is_schedulable`, `retry_limit`, `timeout_seconds`, `config`

Finding the next step after current:
```sql
SELECT * FROM workflow_step
WHERE workflow_id = $current_workflow_id
  AND step_order > $current_step_order
ORDER BY step_order ASC
LIMIT 1;
```

### 4. task
One row per task instance. Tracks current step, status, processor lock, scheduling cadence, and a metadata scratchpad.

**status** (lifecycle): `active | paused | disabled | hidden | completed | failed | cancelled`
**step_status** (current step): `pending | running | success | failed | skipped`

Key fields:
- `workflow_template_id` — which workflow this task runs
- `current_step_id` — which step it is currently on
- `processor_id` — if set, only this processor may run it; if NULL, any processor may
- `locked_by` / `locked_at` — which processor currently holds the lock
- `schedule_type`: `once` (default) or `cron`
- `frequency` — cron expression (used when `schedule_type = 'cron'`)
- `next_execution` — when the task becomes eligible for the scheduled queue
- `weight` — priority (lower = higher priority, default 100)
- `metadata` — JSON scratchpad for task-specific config and intermediate state
- `result` — last step result snapshot

### 5. task_step_log
One row per execution attempt. Provides structured audit trail (who ran it, when, how long, what happened, any error).

Key fields: `task_id`, `step_id`, `processor_id`, `attempt`, `status`, `started_at`, `completed_at`, `duration_ms`, `result`, `error`

### 6. processor
`public.processor` remains the authoritative table — the old task manager system (`yarn tm run`) still reads and writes it directly. Crucible adds four columns to it via `ALTER TABLE`:

| New column | Purpose |
|---|---|
| `capacity INT` | Max concurrent task locks this processor will hold |
| `tags TEXT[]` | Capability routing tags (e.g. `['encoder','scraper']`) |
| `heartbeat_at TIMESTAMPTZ` | Updated every 30s while Manager loop is running |
| `last_task_at TIMESTAMPTZ` | Updated when a task lock is acquired |

`monkey_crucible.processor` is a **view** of `public.processor`. Crucible ORM creates clients with `{ db: { schema: 'monkey_crucible' } }` and queries `.from('processor')` — the view satisfies this transparently. Both old and new systems read/write the same underlying rows.

---

## Execution Flow

```
Manager.start()
  ↓
registerProcessor()          -- upsert processor row; clear own stale locks
heartbeatLoop(30s)           -- background: UPDATE processor SET heartbeat_at = now()
staleLockSweep()             -- release locks from dead processors (heartbeat > 5min)
  ↓
for mode in ['regular', 'heavy', 'scheduled']:
  ↓
  acquireTaskBatch(mode, limit)
    -- Single atomic UPDATE to avoid race conditions across processors:
    UPDATE task
    SET locked_by = $me, locked_at = now(), step_status = 'running', attempt_count = attempt_count + 1
    WHERE id IN (
      SELECT task_id FROM view_task_queue
      WHERE (processor_id IS NULL OR processor_id = $me)
        AND status = 'active' AND step_status = 'pending' AND enabled = true
        AND locked_by IS NULL AND manual_mode = false
        AND <mode filter: is_heavy / is_schedulable / next_execution>
      ORDER BY weight ASC, step_weight ASC, updated_at ASC
      LIMIT $limit
    )
    RETURNING *
  ↓
  for each acquired task:
    handler     = loadHandler(task.step_task_type)    -- dynamic require by slug
    config      = merge(task.step_config, task.metadata)  -- step config wins
    startedAt   = Date.now()
    result      = await handler.run(task, config)
    durationMs  = Date.now() - startedAt
    ↓
    logStepExecution({ task_id, step_id, processor_id, status, startedAt, durationMs, result })
    ↓
    if result.success:
      nextStep = getNextStep(task)          -- query: step_order > current, LIMIT 1
      if nextStep EXISTS and NOT step.is_final:
        advanceTask(task, nextStep)         -- UPDATE current_step_id, step_status='pending'
      else:
        completeTask(task)                  -- status='completed', completed_at=now()
      if schedule_type = 'cron':
        reschedule(task)                    -- next_execution = cron.next(), reset to step 1
    else:
      if attempt_count < step.retry_limit:
        requeueForRetry(task)               -- step_status='pending', backoff delay
      else:
        failTask(task)                      -- step_status='failed', status='failed'
    ↓
    releaseLock(task)                       -- locked_by=NULL, locked_at=NULL
```

---

## Queue Modes

| Mode | `step_is_heavy` | `step_is_schedulable` | Additional condition |
|---|---|---|---|
| `regular` | false | false | — |
| `heavy` | true | false | — |
| `scheduled` | any | true | `next_execution <= now()` |

Each mode runs independently up to `--max` tasks per invocation.

---

## Locking Strategy

**Acquire (atomic):** `UPDATE task SET locked_by = $me WHERE locked_by IS NULL RETURNING *`
If 0 rows returned for a given task_id, another processor won the race — skip it.

**Release:** `UPDATE task SET locked_by = NULL, locked_at = NULL WHERE id = $task_id`

**Stale lock recovery:**
```sql
UPDATE task SET locked_by = NULL, locked_at = NULL, step_status = 'pending',
  attempt_count = GREATEST(attempt_count - 1, 0)
WHERE locked_by IN (
  SELECT id FROM processor WHERE heartbeat_at < now() - interval '5 minutes'
);
```
Run on Manager startup and every N minutes.

---

## Scheduling (Cron Tasks)

When `schedule_type = 'cron'` and the final step completes successfully:
1. Compute `next_execution` from `frequency` using `CronExpressionParser.parse(frequency).next().toDate()`
2. Reset `current_step_id` to the first step of the workflow
3. Set `step_status = 'pending'`, `status = 'active'`

The task re-enters the scheduled queue on the next manager run after `next_execution`.

---

## Processor Assignment

| `task.processor_id` | Behavior |
|---|---|
| `NULL` | Any processor with capacity may acquire it |
| `<processor_id>` | Only that processor may acquire it |

For capability-based routing, use `processor.tags` (e.g., `['encoder', 'scraper']`) and filter in the acquire query:
```sql
AND (p_tags IS NULL OR processor.tags && p_tags)
```

---

## Step Config Merge

At runtime, per-step defaults are merged with task-level overrides:
```js
const config = { ...step.config, ...task.metadata };
// step.config wins on conflicts — provides per-step defaults
// task.metadata allows per-instance overrides
```

---

## Retry Logic

Per step: `step.retry_limit` (default 0 = no retry). When a step fails:
- If `attempt_count < retry_limit`: reset `step_status = 'pending'`, apply exponential backoff to `next_execution`
- If `attempt_count >= retry_limit`: set `step_status = 'failed'`, `status = 'failed'`

Backoff formula (suggested): `next_execution = now() + (2^attempt_count * 60 seconds)`

---

## Registered Workflows

| Slug | Steps (slug: step_order) |
|---|---|
| `full_ingest` | backlog:10 → rename:20 → dispatch:30 → draft_video:40 → sort:50 → encode:60 → generate_hls:70 → scrape:80 → refine_title:90 → generate_preview:100 → validate:110 → publish:120 |
| `scrape_only` | scrape:10 → refine_title:20 → validate:30 |
| `encode_only` | encode:10 → generate_hls:20 → validate:30 |
| `validation` | validate:10 |
| `file_cleanse` | temp_file_clear:10 → task_clear:20 |
| `sync_local` | sort:10 → validate:20 → sort:30 |
| `scan` | backlog:10 → validate:20 → draft_video:30 |

---

## Registered Task Types

| Slug | Heavy | Schedulable | Default timeout | Default retries |
|---|---|---|---|---|
| `backlog` | no | no | 60s | 0 |
| `rename` | no | no | 60s | 0 |
| `dispatch` | no | no | 30s | 0 |
| `draft_video` | no | no | 120s | 0 |
| `sort` | no | no | 120s | 1 |
| `scrape` | no | no | 300s | 1 |
| `refine_title` | no | no | 60s | 0 |
| `validate` | no | no | 60s | 0 |
| `encode` | yes | no | 7200s | 1 |
| `generate_hls` | yes | no | 3600s | 1 |
| `generate_preview` | yes | no | 1800s | 1 |
| `generate_preview_from_link` | yes | no | 1800s | 1 |
| `extract_image` | yes | no | 300s | 0 |
| `set_image` | no | no | 60s | 0 |
| `collage_image` | yes | no | 600s | 0 |
| `collage_video` | yes | no | 3600s | 0 |
| `rewrite_video` | no | no | 600s | 1 |
| `publish` | no | no | 120s | 0 |
| `task_clear` | no | yes | 300s | 0 |
| `temp_file_clear` | no | yes | 300s | 0 |
| `delete_file` | no | no | 60s | 0 |
| `sync_video` | no | yes | 300s | 1 |
| `mock_task` | no | no | 10s | 0 |

---

## Schema

All tables live in the `monkey_crucible` schema. The only cross-schema reference is `monkey_crucible.task.video_id → public.video(id)` — cross-schema FKs are valid in Postgres. Compatibility views in `public` (`public.processor`, `public.task`) mean existing ORM code requires no changes during migration.

## Database Files (run in order)

```
000_schema.sql               -- CREATE SCHEMA monkey_crucible
001_processor.sql            -- monkey_crucible.processor + public.processor compat view
002_task_type_registry.sql   -- handler catalog + seed
003_workflow_template.sql    -- named workflow definitions + seed
004_workflow_step.sql        -- ordered steps per template + seed
005_task.sql                 -- task table + indexes + public.task compat view
006_task_step_log.sql        -- per-execution audit log + indexes
007_views.sql                -- view_task_queue, view_processor_health
008_rpc_functions.sql        -- Supabase RPC helpers (acquire, advance, release, heartbeat)
```

---

## Key Design Decisions

**`step_order` integer over linked-list `prior`**
The original system used a `prior` FK to chain steps. This makes insertion, reordering, and querying the next step brittle. Explicit integers with gaps (10, 20, 30) solve all three.

**Row-level lock on task (`locked_by`) over binary `in_progress` on processor**
Processor-level `in_progress` allows only one task at a time per processor and requires manual unlock on crash. Task-level `locked_by` + heartbeat sweep handles any number of concurrent tasks per processor and recovers from crashes automatically.

**Heartbeat-based stale lock recovery**
Instead of a manual `yarn tm unlock` command, processors update `heartbeat_at` every 30s. The Manager's startup sweep detects processors with stale heartbeats and releases their task locks — no operator intervention needed.

**`!err.response` as the retry-on-fallback gate in AbstractHelper.callApi**
Network errors (`EHOSTUNREACH`, `ECONNREFUSED`) have no `err.response` — the server never received the request. HTTP errors (4xx/5xx) do have `err.response` — the server received and processed the request. Retrying on fallback only makes sense for the former.

**Step config merged at runtime (step.config wins)**
Steps provide per-type defaults via `config` JSONB. Task metadata provides per-instance overrides. Merging at runtime (`{ ...step.config, ...task.metadata }`) means step-level defaults are never baked into task rows — changing a step's config propagates to all future runs of that step.

**Gap-numbered `step_order`**
Using 10, 20, 30 instead of 1, 2, 3 means a new step between `sort` (50) and `encode` (60) can be inserted as 55 without touching any other row. Renumbering a long chain is a migration risk avoided entirely.

**`task_type_registry` as single source of truth**
UI, validation, and documentation all read from the same table. Adding a new handler means adding a row here; removing one disables it without deleting workflow history.

---

## What This Replaces

| Before | After |
|---|---|
| `workflow` linked-list (`prior` FK) | `workflow_step` with explicit `step_order` |
| `workflow` rows are both template and instance | `workflow_template` + `workflow_step` (template) / `task` (instance) |
| `processor.in_progress` binary flag | `task.locked_by` + `task.locked_at` |
| Manual `yarn tm unlock` on crash | Automatic stale-lock sweep via heartbeat |
| `process_log` free-form messages | `task_step_log` structured per-execution rows |
| No retry logic | `workflow_step.retry_limit` with backoff |
| Dispatch task assigns processor | Queue-time routing: `processor_id IS NULL OR = me` |
| Circuit breaker kills entire queue | Per-task failure isolation |

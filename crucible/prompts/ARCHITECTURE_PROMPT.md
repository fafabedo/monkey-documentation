# Crucible — Architecture & Implementation Prompt

Use this document to implement, extend, port, or integrate the Crucible task runner into another application, language, or AI coding session. It is fully self-contained and describes the complete design rationale, database schema, execution model, and key decisions.

---

## What is Crucible?

**Crucible** is a multi-processor, workflow-based task orchestration system for video processing pipelines. It runs as a Node.js CLI process (`yarn crucible run`) on one or more machines simultaneously.

Core responsibilities:
- Maintain a queue of **tasks**, each progressing through ordered **workflow steps**
- Distribute work across **processors** without a coordinator — processors compete for row-level locks
- Support two execution profiles: **regular** (lightweight) and **heavy** (CPU/IO-intensive)
- Support **cron-scheduled** tasks that repeat on a cadence
- Support **manual gate steps** — tasks park at `waiting` until an admin submits data via UI
- Recover automatically from crashed processors via heartbeat + stale-lock sweep
- Resolve **vault URI** file references (`queue://`, `temp://`, etc.) to real filesystem paths at execution time
- Provide a full per-step **audit log** of every execution attempt

The system replaces a simpler linear-chain workflow system with: explicit step ordering, row-level locking, human gates, vault file references, heartbeat-based crash recovery, retry limits per step, and a structured audit trail.

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

Key fields: `workflow_id` (FK), `task_type`, `step_order`, `is_final`, `is_heavy`, `is_schedulable`, `is_manual`, `retry_limit`, `timeout_seconds`, `config`

**`is_manual = true`**: Manager does not dispatch a handler. Instead the task's `step_status` is set to `'waiting'`. The task stays parked until an admin updates `step_status = 'pending'` externally (via UI/API). Used for the `adjust` step where a human provides a scrape link, title override, or configuration flags before the workflow continues.

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
**step_status** (current step): `pending | running | success | failed | skipped | waiting`

- `waiting` — task is at a manual step. Will not be picked up by the queue until reset to `pending`.

Key fields:
- `workflow_template_id` — which workflow this task runs
- `current_step_id` — which step it is currently on
- `file` — vault URI of the source file (e.g. `queue://scene.mp4`, `temp://raw.mkv`). Resolved to a real path at execution time via `VaultResolver`.
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

## Vault URI File References

Task rows store file references as **vault URIs** rather than absolute paths:

| Scheme | Maps to processor metadata key | Example |
|---|---|---|
| `queue://` | `metadata.queue_path` | `queue://scene-001.mp4` |
| `temp://` | `metadata.temp_path` | `temp://raw-scene.mkv` |
| `hub://` | `metadata.hub_path` | `hub://final.mp4` |
| `hold://` | `metadata.hold_path` | `hold://pending.mp4` |
| `trash://` | `metadata.trash_path` | `trash://old.mp4` |

The `ScanQueue` handler scans the processor's queue folder and stores new files as `queue://filename.mp4`. At execution time, `Manager._executeHandler` resolves the URI to a real path via `VaultResolver.resolve(uri, processor)` before passing it to the handler via `compatTask.file`. Handlers always receive a real filesystem path — they never see the URI.

```js
// venux-library/Utils/VaultResolver.js
resolve('queue://scene.mp4', processor)
// → '/mnt/venux/queue/scene.mp4'  (from processor.metadata.queue_path)
```

The reverse (`VaultResolver.toUri(absolutePath, processor)`) converts a resolved path back to a vault URI for storage.

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
    -- Single atomic UPDATE to avoid race conditions across processors.
    -- Manual steps (step_is_manual = true) are excluded from acquisition entirely.
    UPDATE task
    SET locked_by = $me, locked_at = now(), step_status = 'running', attempt_count = attempt_count + 1
    WHERE id IN (
      SELECT task_id FROM view_task_queue
      WHERE (processor_id IS NULL OR processor_id = $me)
        AND status = 'active' AND step_status = 'pending' AND enabled = true
        AND locked_by IS NULL AND manual_mode = false
        AND NOT step_is_manual
        AND <mode filter: is_heavy / is_schedulable / next_execution>
      ORDER BY weight ASC, step_weight ASC, updated_at ASC
      LIMIT $limit
    )
    RETURNING *
  ↓
  for each acquired task:
    if task.step_is_manual:
      releaseLock(task, 'waiting')   -- park task; no handler runs
      continue

    handler     = loadHandler(task.step_task_type)   -- dynamic require by slug
    file        = VaultResolver.resolve(task.file, processor)  -- resolve vault URI
    config      = merge(task.step_config, task.metadata)       -- step config wins
    startedAt   = Date.now()
    result      = await handler.run(task.task_id)
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

## Manual Gate Steps (`is_manual`)

When a workflow step has `is_manual = true`, Manager **does not run a handler**. It releases the lock and sets `step_status = 'waiting'`. The task is invisible to the queue until an external actor (admin UI, API endpoint) sets `step_status = 'pending'`.

Typical use case — the `adjust` step:
```
rename ✓
  → adjust (step_status = 'waiting')
      Admin fills in: scrape.link, metadata.title, encode options
      Sets: step_status = 'pending'
  → dispatch → draft_video → scrape → ...
```

The `acquire_task_batch` RPC also includes `AND NOT step_is_manual` so manual steps can never be acquired even if `step_status` is somehow `pending`.

To resume a parked task from SQL:
```sql
UPDATE monkey_crucible.task SET step_status = 'pending', updated_at = now()
WHERE id = $task_id AND step_status = 'waiting';
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

`scan_queue` is a built-in scheduled task (cron: `* * * * *`) — one row per processor — that scans the processor's queue folder for new video files and creates a `monkey_crucible.task` at the `backlog` step of `full_ingest` for each new file found.

---

## Handler Compatibility Shim

All 26 existing handlers under `venux-library/Processor/Task/` extend the old `Processor/Task/AbstractTask` and are used **without modification**. The Manager builds a compatibility object before calling `handler.run()`:

```js
const compatTask = {
    ...task,                                      // all view_task_queue fields
    id:        task.task_id,                      // handlers use task.id
    processor: task.processor_id || processorId,  // handlers use task.processor (fallback to running processor)
    workflow:  task.step_id,                      // handlers use task.workflow
    metadata:  { ...task.step_config, ...task.metadata },
    file:      VaultResolver.resolve(task.file, processor), // resolved real path
};

// Prevent handlers calling retrieveTask() from querying public.task
handler.retrieveTask    = async () => compatTask;
handler.retrieveProcess = async () => compatTask;
```

The `processor` field falls back to the running processor's ID when `task.processor_id` is NULL. This ensures handlers that call `ProcessorOrm.retrieveProcessorById(this.task.processor)` always receive a valid ID.

---

## Processor Assignment

| `task.processor_id` | Behavior |
|---|---|
| `NULL` | Any processor with capacity may acquire it |
| `<processor_id>` | Only that processor may acquire it |

`PROCESSOR_ID` in `.env.local` must be the numeric `id` from `public.processor`. Use `SELECT id, name FROM public.processor` to find yours.

---

## Step Config Merge

At runtime, per-step defaults are merged with task-level overrides:
```js
const config = { ...step.config, ...task.metadata };
// step.config provides per-step defaults
// task.metadata allows per-instance overrides (task.metadata wins on conflict)
```

---

## Retry Logic

Per step: `step.retry_limit` (default 0 = no retry). When a step fails:
- If `attempt_count < retry_limit`: reset `step_status = 'pending'`, apply exponential backoff to `next_execution`
- If `attempt_count >= retry_limit`: set `step_status = 'failed'`, `status = 'failed'`

Backoff formula: `next_execution = now() + (2^attempt_count * 60 seconds)`

---

## Registered Workflows

| Slug | Steps (task_type: step_order) |
|---|---|
| `full_ingest` | backlog:10 → rename:20 → **adjust:25** → dispatch:30 → draft_video:40 → sort:50 → encode:60 → generate_hls:70 → scrape:80 → refine_title:90 → generate_preview:100 → validate:110 → publish:120 |
| `scrape_only` | scrape:10 → refine_title:20 → validate:30 |
| `encode_only` | encode:10 → generate_hls:20 → validate:30 |
| `validation` | validate:10 |
| `file_cleanse` | temp_file_clear:10 → task_clear:20 |
| `sync_local` | sort:10 → validate:20 → sort:30 |
| `scan` | backlog:10 → validate:20 → draft_video:30 |
| `scan_queue` | scan_queue:10 *(cron, schedulable)* |

`adjust` is marked `is_manual = true` — task parks at `waiting` until admin input.

---

## Registered Task Types

| Slug | Heavy | Schedulable | Manual | Default timeout | Default retries |
|---|---|---|---|---|---|
| `backlog` | no | no | no | 60s | 0 |
| `adjust` | no | no | **yes** | — | 0 |
| `rename` | no | no | no | 60s | 0 |
| `dispatch` | no | no | no | 30s | 0 |
| `draft_video` | no | no | no | 120s | 0 |
| `sort` | no | no | no | 120s | 1 |
| `scrape` | no | no | no | 300s | 1 |
| `refine_title` | no | no | no | 60s | 0 |
| `validate` | no | no | no | 60s | 0 |
| `encode` | yes | no | no | 7200s | 1 |
| `generate_hls` | yes | no | no | 3600s | 1 |
| `generate_preview` | yes | no | no | 1800s | 1 |
| `generate_preview_from_link` | yes | no | no | 1800s | 1 |
| `extract_image` | yes | no | no | 300s | 0 |
| `set_image` | no | no | no | 60s | 0 |
| `collage_image` | yes | no | no | 600s | 0 |
| `collage_video` | yes | no | no | 3600s | 0 |
| `rewrite_video` | no | no | no | 600s | 1 |
| `publish` | no | no | no | 120s | 0 |
| `task_clear` | no | yes | no | 300s | 0 |
| `temp_file_clear` | no | yes | no | 300s | 0 |
| `delete_file` | no | no | no | 60s | 0 |
| `sync_video` | no | yes | no | 300s | 1 |
| `scan_queue` | no | yes | no | 120s | 0 |
| `mock_task` | no | no | no | 10s | 0 |

---

## Key Utility: AbstractHelper.callApi

All Core API calls go through `AbstractHelper.callApi(method, pathname, data)`. It reads the primary and fallback URLs from `admin_settings.vx_core.api.resources` (cached after first load) and falls back only on **network errors** (no `err.response`), never on HTTP errors:

```js
const isNetworkError = !primaryErr.response;
if (!fallback || !isNetworkError) throw primaryErr;
// retry on fallback only when primary was unreachable
```

HTTP 4xx/5xx from primary are thrown immediately — the server received and processed the request; retrying on a different URL would be incorrect.

---

## Logger Timezone

All log timestamps use local time in the `America/New_York` timezone (EDT/EST) via `Intl.DateTimeFormat.formatToParts()`. Format: `[YYYY-MM-DD HH:MM:SS EDT]`.

---

## Schema

All tables live in the `monkey_crucible` schema. Cross-schema references:
- `monkey_crucible.task.video_id → public.video(id)`
- `monkey_crucible.task.processor_id → public.processor(id)` *(not the view)*
- `monkey_crucible.task.locked_by → public.processor(id)` *(not the view)*
- `monkey_crucible.task_step_log.processor_id → public.processor(id)`

## Database Files (run in order)

```
000_schema.sql               -- CREATE SCHEMA monkey_crucible
001_processor.sql            -- ALTER public.processor; monkey_crucible.processor view
002_task_type_registry.sql   -- handler catalog + seed (includes adjust, scan_queue)
003_workflow_template.sql    -- named workflow definitions + seed
004_workflow_step.sql        -- ordered steps + is_manual column + seed (includes adjust at 25)
005_task.sql                 -- task table + indexes (step_status includes 'waiting')
006_task_step_log.sql        -- per-execution audit log + indexes
007_views.sql                -- view_task_queue (includes step_is_manual), view_processor_health
008_rpc_functions.sql        -- Supabase RPC: acquire_task_batch (excludes step_is_manual), advance, release, heartbeat
009_seed_examples.sql        -- example task inserts with vault URIs; scan_queue workflow + cron task
010_adjust_step.sql          -- migration: adds is_manual, 'waiting' status, adjust step, recreates view + RPC
```

### Supabase permissions (required after schema creation)
```sql
GRANT USAGE ON SCHEMA monkey_crucible TO service_role;
GRANT ALL ON ALL TABLES    IN SCHEMA monkey_crucible TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA monkey_crucible TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA monkey_crucible TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA monkey_crucible GRANT ALL ON TABLES    TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA monkey_crucible GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA monkey_crucible GRANT ALL ON FUNCTIONS TO service_role;
```
Also add `monkey_crucible` to **Supabase Dashboard → Settings → API → Exposed schemas**.

---

## Key Design Decisions

**`step_order` integer over linked-list `prior`**
The original system used a `prior` FK to chain steps. This makes insertion, reordering, and querying the next step brittle. Explicit integers with gaps (10, 20, 30) solve all three.

**Row-level lock on task (`locked_by`) over binary `in_progress` on processor**
Processor-level `in_progress` allows only one task at a time per processor and requires manual unlock on crash. Task-level `locked_by` + heartbeat sweep handles any number of concurrent tasks per processor and recovers from crashes automatically.

**Heartbeat-based stale lock recovery**
Instead of a manual `yarn tm unlock` command, processors update `heartbeat_at` every 30s. The Manager's startup sweep detects processors with stale heartbeats and releases their task locks — no operator intervention needed.

**`is_manual` step flag over `manual_mode` task flag**
`task.manual_mode` pauses the entire task from the queue. `step.is_manual` pauses the task at a specific step while the rest of the workflow runs automatically. The adjust gate uses `is_manual` so only that step requires human input — all others proceed normally.

**Vault URI scheme for file references**
Storing `queue://filename.mp4` instead of `/mnt/processor-a/queue/filename.mp4` decouples the file reference from any specific processor's mount. When a task moves between processors or a mount point changes, only the processor metadata changes — task rows require no updates. `VaultResolver.resolve(uri, processor)` converts to a real path at execution time.

**`!err.response` as the retry-on-fallback gate in AbstractHelper.callApi**
Network errors (`EHOSTUNREACH`, `ECONNREFUSED`) have no `err.response` — the server never received the request. HTTP errors (4xx/5xx) do have `err.response` — the server received and processed the request. Retrying on fallback only makes sense for the former.

**Step config merged at runtime (task.metadata wins)**
Steps provide per-type defaults via `config` JSONB. Task metadata provides per-instance overrides. Merging at runtime means step-level defaults are never baked into task rows — changing a step's config propagates to all future runs.

**Gap-numbered `step_order`**
Using 10, 20, 30 instead of 1, 2, 3 means a new step between existing ones can be inserted without touching any other row (e.g. `adjust` at 25, between `rename` at 20 and `dispatch` at 30).

**`task_type_registry` as single source of truth**
UI, validation, and documentation all read from the same table. Adding a new handler means adding a row here; removing one disables it without deleting workflow history.

**`scan_queue` as a scheduled task (not inline queue scan)**
The old Manager ran `scanFilesInQueue()` inline before every queue pass. In Crucible, `scan_queue` is a first-class cron task (one row per processor, `* * * * *`) that participates in the same lock/retry/log machinery as any other task. This makes it observable, retryable, and auditable.

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
| Inline queue folder scan per run | `scan_queue` cron task — observable, retryable, logged |
| Absolute filesystem paths in task.file | Vault URIs (`queue://`, `temp://`) resolved at execution time |
| No human gate steps | `is_manual` step flag — parks task at `waiting` for admin input |

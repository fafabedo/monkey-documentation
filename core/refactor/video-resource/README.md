# Video Resource Refactor — Option B

**Goal:** Eliminate the denormalized `metadata` JSONB copy on `video_resource`, make `video_detail` the single source of truth for source-file metadata, and drop `video_detail.synopsis` (unused).

---

## Background

The previous structure stored video resources as URLs inside a `public` JSONB column on `video_detail` (legacy). The `video_resource` table was introduced to give each deliverable URL its own row. During the backfill migration, `video_detail_id` (FK) and a `metadata` JSONB copy were added to `video_resource` to link each resource back to its source file and carry rich metadata.

The copy is the problem. `video_resource.metadata` is a snapshot of `video_detail.metadata` at link time — it can drift, and it duplicates ~1–2 KB per resource row unnecessarily. Since `video_detail_id` already exists as a FK, the metadata is reachable via JOIN at zero schema cost.

---

## Target State

```
video
  └─ video_detail  (source file record — one per ingestion)
       └─ video_resource  (one row per deliverable URL)
```

| Table | Role |
|---|---|
| `video` | Identity, catalog, counters |
| `video_detail` | Source file path + rich file metadata (fps, bitrate, score, etc.) |
| `video_resource` | Each deliverable URL (mp4, hls, iframe) + per-resource specs |

`video_resource.metadata` → **dropped**
`video_detail.synopsis` → **dropped** (data never populated, column unused)

---

## What Changes

### Database (see [`db/`](./db/))

| Migration | Action |
|---|---|
| `001_drop_video_resource_metadata.sql` | Drop `video_resource.metadata` |
| `002_drop_video_detail_synopsis.sql` | Drop `video_detail.synopsis` |

### ORM — `library/ORM/Video.js`

**`retrieveVideoResourcesByVideoId` (line 252)**

Current — bare select, no JOIN:
```js
.from("video_resource")
.select()
.eq("video_id", videoId);
```

Updated — JOIN video_detail for metadata:
```js
.from("video_resource")
.select(`
  *,
  video_detail!video_detail_id (
    metadata
  )
`)
.eq("video_id", videoId);
```

Supabase PostgREST returns the joined row as a nested object:
```js
{
  id: 1,
  mime: "video/mp4",
  height: 1080,
  // ... other video_resource columns
  video_detail: {
    metadata: { fps: 23.976, bitrate: 2171175, ... }
  }
}
```

### API Layer — `library/API/Video/Load.js`

**`retrieveVideoResources` (line 102)**

Current — maps basic fields only, no metadata:
```js
return _resources.map(_resource => ({
    resource: _resource.resource,
    mime: _resource.mime,
    height: _resource.height,
    // ... no fps, bitrate, frame_count, quality_score
}));
```

Updated — spread metadata fields from the JOIN:
```js
return _resources.map(_resource => {
    const meta = _resource.video_detail?.metadata ?? {};
    return {
        resource: _resource.resource,
        resource_raw: _resource.resource_raw,
        mime: _resource.mime,
        resource_type: _resource.resource_type,
        aspect: _resource.aspect,
        vertical: _resource.vertical,
        width: _resource.width,
        height: _resource.height,
        bytes: _resource.bytes,
        human_size: _resource.human_size,
        duration: _resource.duration,
        seconds: _resource.seconds,
        codec: _resource.codec,
        // Rich metadata from video_detail JOIN
        fps: meta.fps ?? null,
        file_size: meta.size ?? null,        // bytes
        bitrate: meta.bitrate ?? null,       // bps
        frame_count: meta.frame_count ?? null,
        quality_score: meta.score ?? null,
        token: this.generateJwtPayload({ user_id: userid, video_id: _resource.uuid, key: _resource.resource_type }),
    };
});
```

---

## Resource Resolution Priority (unchanged)

```
1. video_resource rows  (preferred — new style)
   └─ JOIN video_detail ON video_detail_id to get metadata
   └─ If video_detail_id IS NULL → iframe/embed, skip metadata fields

2. Fallback: video_detail.public JSONB  (legacy — no video_resource rows)
   └─ _buildResourcesFromPublic() in Load.js handles this path
   └─ metadata comes from video_detail.metadata directly

3. Neither → video has no playable resource
```

The fallback path (`_buildResourcesFromPublic`, `_buildResourcesFromDetails`) is untouched by this refactor.

---

## Frontend — Resource Payload Shape

Each object in the `resources` array returned by `/api/video/load`:

```js
{
  // Delivery
  mime: 'video/mp4' | 'application/x-mpegURL' | 'iframe' | 'video/webm',
  resource_type: 'full' | 'preview',
  resource: '<cdn-url or null>',
  resource_raw: '<origin-url or null>',
  token: '<jwt>',

  // Per-resource specs (always present for mp4/hls; may be null for iframes)
  height: 1080,
  width: 1920,
  aspect: '16:9',
  codec: 'hevc',
  vertical: false,
  duration: '00:34:51',
  seconds: 2091.391,
  bytes: 567597167,
  human_size: '541.3 MB',

  // Rich source-file metadata (null for iframes — no video_detail_id)
  fps: 23.976,
  file_size: 567597167,     // bytes — prefer over legacy size_mb
  bitrate: 2171175,         // bps
  frame_count: 50143,
  quality_score: 6753222720000,
}
```

**Display rules:**
- `fps` → round to 2 decimal places, strip trailing zeros (`23.976` → `23.98`)
- `file_size` → human-readable bytes (`567597167` → `541.3 MB`)
- `bitrate` → Mbps if ≥ 1,000,000 bps, else kbps (`2171175` → `2.2 Mbps`)
- `frame_count` → locale integer (`50143` → `50,143`)
- `quality_score` → `score / 1e12`, 2 decimals; **do not display if result < 0.01**
- `height` → append `p` (`1080` → `1080p`)

---

## New Video Entry — Creation Flow

When a new video file is ingested by the pipeline:

```
1. Create video row
   INSERT INTO video (title, slug, studio, space_id, status, ...)

2. Create video_detail row  ← source file record
   INSERT INTO video_detail (
     video,            -- FK to video.id
     file,             -- server path to source file
     mime, codec, width, height, duration, duration_seconds,
     size, size_mb, aspect, vertical,
     metadata,         -- full JSONB from ingestion pipeline
     type, source
     -- NO synopsis (column is dropped)
   )

3. For each deliverable URL, create a video_resource row
   INSERT INTO video_resource (
     video_id,                -- FK to video.id
     video_detail_id,         -- FK to video_detail.id  ← required
     resource,                -- CDN URL
     resource_raw,            -- origin URL
     mime,                    -- video/mp4 | application/x-mpegURL | iframe
     resource_type,           -- 'full' | 'preview'
     height, width, aspect, vertical, codec,
     seconds, duration, bytes, human_size
     -- NO metadata column (dropped)
   )

4. For iframe/embed resources (no physical file):
   INSERT INTO video_resource (
     video_id,
     video_detail_id,  -- NULL (correct and expected)
     mime,             -- 'iframe'
     resource,
     resource_raw
   )
```

**Rules:**
- `video_detail_id` must be set for all non-iframe resources.
- Do NOT copy `metadata` onto `video_resource` — the column no longer exists.
- Do NOT write resource URLs into `video_detail.public` — that column is legacy and will be removed.
- One `video_detail` row per ingestion event. If a file is replaced, create a new `video_detail` row and update `video_resource.video_detail_id` to point to the new one.

---

---

## video_detail.file — Vault URI Support

### Background

`video_detail.file` currently stores a plain filesystem path written by the ingestion pipeline (e.g. `/Users/e043280/Temporary/Venux/Queue/video.mp4`). This path is processor-specific and brittle — it only means something on the machine that wrote it.

`monkey_vault` introduces a URI scheme abstraction over storage backends. A processor-local file is referenced as `queue://video.mp4` instead of an absolute path. The vault resolves that URI to the correct path at runtime by querying `monkey_vault.storage_processor_mounts` for the active processor.

The goal is to allow `video_detail.file` to store either format — a legacy plain path or a vault URI — and resolve it correctly.

---

### URI Format

```
<mount_type>://<relative_path>
```

| Example value in `video_detail.file` | Type | Resolves to |
|---|---|---|
| `/Users/e043280/Venux/Queue/video.mp4` | Legacy plain path | Used as-is |
| `queue://studio-1/scene.mp4` | Processor-local vault URI | `local_path + /studio-1/scene.mp4` |
| `temp://exports/video.mp4` | Processor-local vault URI | `local_path + /exports/video.mp4` |
| `s3://my-bucket/path/file.mp4` | Cloud vault URI | Routed to S3 via bucket credentials |

Cloud schemes (`s3://`, `drop://`, `drive://`, `fs://`) are routed through `monkey_vault.storage_buckets` and their encrypted credentials. Processor-local schemes (anything else: `temp://`, `queue://`, `trash://`, or any custom name) are resolved through `storage_processor_mounts`.

---

### Resolution Logic

Any service that reads `video_detail.file` must run it through a resolver before using the path.

**Step 1 — Detect URI type**

```js
const CLOUD_SCHEMES = ['s3', 'drop', 'drive', 'fs'];

function parseVaultUri(file) {
  const match = String(file).match(/^([a-zA-Z][a-zA-Z0-9_-]*):\/{2}(.+)$/);
  if (!match) return { isVaultUri: false };
  return {
    isVaultUri: true,
    scheme: match[1],
    relativePath: match[2],
    isCloud: CLOUD_SCHEMES.includes(match[1]),
  };
}
```

**Step 2 — Resolve**

```js
async function resolveVideoDetailFile(file) {
  const parsed = parseVaultUri(file);

  // Legacy: plain path — use as-is
  if (!parsed.isVaultUri) {
    return { type: 'legacy', path: file };
  }

  // Cloud URI — path lives in vault, look up the storage_files record for provider_ref
  if (parsed.isCloud) {
    return { type: 'cloud', uri: file };
  }

  // Processor-local mount — query storage_files by URI to get the absolute path
  // storage_files.provider_ref holds the absolute path written at upload time
  const { data: fileRecord, error } = await supabase
    .schema('monkey_vault')
    .from('storage_files')
    .select('provider_ref, processor_id')
    .eq('uri', file)
    .eq('upload_status', 'verified')
    .maybeSingle();

  if (!fileRecord) {
    // Fallback: resolve mount directly if storage_files record is missing
    const { data: mount } = await supabase
      .schema('monkey_vault')
      .from('storage_processor_mounts')
      .select('local_path, processor_id')
      .eq('mount_type', parsed.scheme)
      .eq('is_active', true)
      .maybeSingle();

    if (!mount) throw new Error(`Vault mount not found for scheme: ${parsed.scheme}://`);

    return {
      type: 'processor_mount',
      path: `${mount.local_path}/${parsed.relativePath}`,
      processor_id: mount.processor_id,
    };
  }

  return {
    type: 'processor_mount',
    path: fileRecord.provider_ref,   // absolute path stored at upload time
    processor_id: fileRecord.processor_id,
  };
}
```

**Why use `storage_files.provider_ref` as the primary lookup:**
`provider_ref` is the absolute path written to disk at upload time and verified by the vault. It's the most reliable source — it doesn't depend on the current processor's mount table state and survives mount reconfiguration.

---

### What changes in video_detail

No schema change is needed — `video_detail.file` is already a `text` column and accepts any string. The only change is convention:

| Before | After |
|---|---|
| Pipeline writes `/absolute/path/video.mp4` | Pipeline writes `queue://studio-1/video.mp4` |
| Consumers use `video_detail.file` directly | Consumers call `resolveVideoDetailFile(video_detail.file)` |

---

### Where to implement the resolver

The resolver belongs in a shared utility, not in every caller. Suggested location:

```
library/Utils/Vault/FileResolver.js
```

Callers that use `video_detail.file` today:
- `library/Utils/Video/Helper.js` — copies `file` into task metadata for encode, HLS, preview tasks
- `library/API/Video/Load.js` — exposes `_detail` (includes `file`) on the admin response

Both should pass `video_detail.file` through `resolveVideoDetailFile()` before forwarding it to the pipeline or returning it in a response.

---

### New video entry — updated creation flow

Step 2 from the creation flow in the section above is now:

```
2. Create video_detail row
   INSERT INTO video_detail (
     video,
     file,             -- vault URI: "queue://studio-name/video.mp4"
                       --   OR legacy plain path for backward compatibility
     mime, codec, width, height, duration, duration_seconds,
     size, size_mb, aspect, vertical,
     metadata,
     type, source
   )
```

When the ingestion pipeline uploads the source file to vault, the vault returns the URI (`queue://studio-name/video.mp4`). That URI is what gets written to `video_detail.file`. The absolute path is stored in `monkey_vault.storage_files.provider_ref` and is recoverable at any time via `resolveVideoDetailFile()`.

---

---

## Code Audit — library/API/Video

### Dead Code (safe to delete)

| File | Symbol | Reason |
|---|---|---|
| `library/API/Video/Admin/Update.js` | Entire file | `ApiVideoAdminUpdate` is never imported by any route in `src/pages/api/`. All admin operations go through `Update.js` and `Load.js`. Duplicates logic with drift. |
| `library/API/Video/Load.js:179` | `generateResourcesFromVideoDetails()` | Not called by any route or any other code. Was a transition helper. |
| `library/API/Video/Load.js:126` | `_buildResourcesFromDetails()` | Only called by the dead `generateResourcesFromVideoDetails()`. |
| `library/ORM/Video.js:243` | `retrieveVideoDetailToResourcesByVideoId()` | Only called by dead `generateResourcesFromVideoDetails()`. |

### Active Code That Needs Changes

| File | Line | What | Change Required |
|---|---|---|---|
| `library/ORM/Video.js` | 252 | `retrieveVideoResourcesByVideoId()` | Add JOIN: `.select('*, video_detail!video_detail_id(metadata)')` |
| `library/API/Video/Load.js` | 102 | `retrieveVideoResources()` | Spread `fps`, `file_size`, `bitrate`, `frame_count`, `quality_score` from `_resource.video_detail?.metadata` |
| `library/API/Video/Update.js` | 513 | `saveVideoResources()` | Set `video_detail_id` when creating/updating resource rows |
| `library/API/Video/Update.js` | 487 | `saveVideoDetail()` | Remove `if (data.public) dataRow.public = data.public` — stop writing to the legacy column |
| `library/API/Video/Segments.js` | 43 | `requestVideoSegments()` | `_videoDetail?.public?.download` reads from legacy `video_detail.public`; replace with a query to `video_resource` |

### Conflicts and Breaking Changes

| Severity | Location | Issue |
|---|---|---|
| **Bug (existing)** | `Update.js:343` | `QUICK_UPDATE_FIELDS` includes `'synopsis'`. `handleFieldUpdate` would call `upsertTable("video", { synopsis: value })` but `video` table has no `synopsis` column — would silently no-op or error. Remove `'synopsis'` from this list. |
| **Breaking when `public` deprecated** | `Load.js:345–348` | `handleAdminLoadVideo` reads `player_type`, `source_type`, `embed_link` from `video.public`. Must be replaced with a `video_resource` lookup before `video_detail.public` is dropped. |
| **Breaking when `public` deprecated** | `Segments.js:43` | `_videoDetail?.public?.download` is used to dispatch segment/preview pipeline tasks. Must resolve the download URL from `video_resource WHERE mime = 'video/mp4' AND resource_type = 'full'`. |
| **Stale filter** | `Fetch.js:103` | `TOGGLE_FIELDS` includes `'synopsis'` as a toggle filter on the listing query. Synopsis lives in `video_metadata` (a separate table), not on `video`. Audit whether this filter is actually used and producing correct results. |
| **Dead admin class** | `Admin/Update.js:81` | `prepareVideoDetailPayload` still includes `synopsis` and writes to `video_detail.public`. Moot if the class is deleted, but confirms the file is out of date. |

---

## Pending Work

Run in this order — code first, DB column drops last.

### Phase 1 — Pre-flight (do now, no production risk)

- [ ] **Audit** — Run `db/000_preflight_audit.sql` and review output before any migration
- [ ] **Dead code** — Delete `library/API/Video/Admin/Update.js`
- [ ] **Dead code** — Delete `generateResourcesFromVideoDetails()` and `_buildResourcesFromDetails()` from `library/API/Video/Load.js:126–181`
- [ ] **Dead code** — Delete `retrieveVideoDetailToResourcesByVideoId()` from `library/ORM/Video.js:243–251`
- [ ] **Bug fix** — Remove `'synopsis'` from `QUICK_UPDATE_FIELDS` in `library/API/Video/Update.js:343`

### Phase 2 — ORM + API (deploy before DB migrations)

- [ ] **ORM** — Update `retrieveVideoResourcesByVideoId` to JOIN `video_detail!video_detail_id(metadata)` (`library/ORM/Video.js:252`)
- [ ] **API** — Update `retrieveVideoResources` to spread metadata fields from JOIN result (`library/API/Video/Load.js:102`)
- [ ] **Update** — Set `video_detail_id` in `saveVideoResources()` (`library/API/Video/Update.js:513`)
- [ ] **Update** — Remove `data.public` write from `saveVideoDetail()` (`library/API/Video/Update.js:493`)
- [ ] **Segments** — Replace `_videoDetail?.public?.download` with `video_resource` query (`library/API/Video/Segments.js:43`)

### Phase 3 — DB column drops (deploy after Phase 2 is live and stable)

- [ ] **DB** — Run `db/003_fix_existing_entries.sql` — verify + repair any unlinked resources
- [ ] **DB** — Run `db/001_drop_video_resource_metadata.sql`
- [ ] **DB** — Run `db/002_drop_video_detail_synopsis.sql`

### Phase 4 — Vault file support

- [ ] **Ingestion pipeline** — Write vault URI into `video_detail.file` instead of absolute path
- [ ] **Utility** — Implement `library/Utils/Vault/FileResolver.js` with `resolveVideoDetailFile()`
- [ ] **Helper** — Update `library/Utils/Video/Helper.js` to resolve `video_detail.file` via `FileResolver` before passing to task metadata

### Phase 5 — Legacy deprecation (future, after all consumers confirmed)

- [ ] **DB** — Drop `video_detail.public` once all videos have `video_resource` rows and `Segments.js` / `handleAdminLoadVideo` are updated
- [ ] **API** — Update `handleAdminLoadVideo` to derive `player_type`, `source_type`, `embed_link` from `video_resource` rows instead of `video.public`

---

## What Does NOT Change

- `_buildResourcesFromPublic()` in `Load.js` — legacy fallback for videos with no `video_resource` rows; stays until Phase 5
- `video_resource` per-resource columns (`height`, `width`, `codec`, `aspect`, `vertical`, `bytes`, etc.) — legitimate per-resource values for transcoded variants
- `video_detail.metadata` structure — unchanged, remains the authoritative source
- The 27 iframe rows with `video_detail_id IS NULL` — correct and expected, no action needed

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

## Pending Work

- [ ] **DB** — Run `001_drop_video_resource_metadata.sql`
- [ ] **DB** — Run `002_drop_video_detail_synopsis.sql`
- [ ] **ORM** — Update `retrieveVideoResourcesByVideoId` to JOIN `video_detail!video_detail_id(metadata)` (`library/ORM/Video.js:252`)
- [ ] **API** — Update `retrieveVideoResources` to spread metadata fields onto each resource object (`library/API/Video/Load.js:102`)
- [ ] **Ingestion pipeline** — Remove any step that writes `video_resource.metadata`
- [ ] **Ingestion pipeline** — Ensure `video_detail_id` is always set on new `video_resource` rows
- [ ] **Deprecate** — Stop writing to `video_detail.public`; add future migration to drop the column once all consumers confirm `video_resource` rows exist

---

## What Does NOT Change

- `_buildResourcesFromPublic` and `_buildResourcesFromDetails` in `Load.js` — legacy fallback paths are untouched
- `video_resource` per-resource columns (`height`, `width`, `codec`, `aspect`, `vertical`, `bytes`, etc.) — these are legitimate per-resource values for transcoded variants and stay
- `video_detail.metadata` structure — unchanged, remains the authoritative source
- The 27 iframe rows with `video_detail_id IS NULL` — correct and expected, no action needed

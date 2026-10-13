# Video Resource Refactor — DB Structure & Approach

## Context

This document describes the current database structure for video resources after a refactor from a single-table approach (`video_detail`) to a dual-table approach (`video_detail` + `video_resource`). It is intended as a reference for any app or service that reads or writes video resource data.

---

## The Problem (Legacy)

Originally, all video data — both the resource URLs and the rich file metadata — lived in a single `video_detail` row per video. Resource URLs (mp4 download link, HLS stream, embed link) were bundled inside a `public` JSONB column. This made it impossible to represent multiple distinct resource entries per video cleanly.

The new `video_resource` table fixes this by storing **one row per resource URL**, but it was created without a link back to `video_detail` and without the rich metadata fields (fps, bitrate, frame count, score, etc.).

---

## Current Table Structure

### `video`
The root video record. Holds title, studio, slug, space, status, and counters.

```sql
id, uuid, title, slug, studio, space_id, status,
released_at, created_at, updated_at,
media, media_id, collection, episode,
like_counter, view_counter
```

---

### `video_detail`
The **original** resource + metadata table. One row per video (or per quality variant in older data). Contains the full file metadata from the ingestion pipeline.

```sql
id, uuid, video (FK → video.id),
file, mime, duration, duration_seconds,
width, height, codec, size, size_mb,
aspect, vertical, type, source,
public JSONB,       -- legacy resource URLs: { download, streaming, embed_link }
metadata JSONB,     -- rich file metadata (see below)
"default", synopsis,
created_at, updated_at
```

**`metadata` JSONB structure** (populated by the ingestion pipeline):
```json
{
  "fps": 23.976,
  "size": 567597167,
  "codec": "hevc",
  "width": 1920,
  "height": 1080,
  "bitrate": 2171175,
  "duration": "00:34:51",
  "seconds": 2091.391,
  "frame_count": 50143,
  "aspect_ratio": "16:9",
  "score": 6753222720000,
  "file": "Video Title (2026-09-10).mp4",
  "mime": "video/mp4",
  "human_size": "541.30 Mb",
  "container": "mov,mp4,m4a,3gp,3g2,mj2",
  "extension": "mp4",
  "audio_codec": "aac",
  "audio_bitrate": 132865,
  "audio_channels": 2,
  "codec_long_name": "H.265 / HEVC (High Efficiency Video Coding)",
  "pix_fmt": "yuv420p",
  "profile": "Main",
  "vertical": false
}
```

---

### `video_resource`
The **new** per-resource table. One row per streamable/downloadable URL. After the refactor, each row is now linked back to its source `video_detail` and carries a copy of the rich metadata.

```sql
id, uuid, video_id (FK → video.id),
resource, resource_raw,             -- the URL
storage_reference,
mime,                               -- video/mp4 | application/x-mpegURL | iframe | video/webm
resource_type,                      -- 'full' | 'preview' | etc.
seconds, duration,
aspect, height, width,
bytes, human_size,
vertical, codec,

-- Added in refactor:
video_detail_id (FK → video_detail.id, nullable),
metadata JSONB,                     -- copied from video_detail.metadata at link time

created_at, updated_at
```

---

## Refactor Migration Summary

| Step | Action | Result |
|---|---|---|
| Schema | Added `video_detail_id` + `metadata` to `video_resource` | Non-breaking, nullable |
| Phase 1 match | Joined on `video_id + codec + height + mime` | 11,231 linked |
| Phase 2 match | Relaxed to `video_id + height` only (fixed mp4 vs mkv mime drift) | +1,524 linked |
| Phase 3 match | Height-closest tiebreaker for multi-detail videos | Remainder linked |
| Unmatched (27) | Confirmed as iframe/embed resources — no file, no detail | Intentionally NULL |
| null_codec fix | Backfilled `codec` from `metadata->>'codec'` | 1,038 rows cleaned |
| **Total matched** | | **12,766 / 12,793** |

### Why 27 rows have `video_detail_id = NULL`
These are iframe/embed resources (external players — e.g. a third-party embed link). They have no physical file and therefore no `video_detail` entry. `video_detail_id IS NULL` on an iframe row is **correct and expected**.

---

## Field Mapping: `metadata` → Display

| `metadata` key | `video_resource` field | Display format | Example |
|---|---|---|---|
| `fps` | `fps` | `23.98` (2 decimals, trailing zeros stripped) | `23.976` → `23.98` |
| `size` (bytes) | `file_size` | Human-readable bytes | `567597167` → `541.3 MB` |
| `bitrate` (bps) | `bitrate` | Mbps / kbps | `2171175` → `2.2 Mbps` |
| `frame_count` | `frame_count` | Locale-formatted integer | `50143` → `50,143` |
| `score` | `quality_score` | Divided by 1e12, 2 decimals | `6753222720000` → `6.75` |
| `height` | `height` | Resolution label | `1080` → `1080p` |
| `aspect_ratio` | `aspect` | Raw string | `16:9` |
| `codec` | `codec` | Raw string | `hevc` |

> **Score display rule:** if `score / 1e12 < 0.01`, do not display.

---

## Resource Resolution Logic (API Layer)

When building the resource list for a video, use this priority order:

```
1. video_resource rows (new style)
   └─ JOIN video_detail ON video_detail_id to get metadata
   └─ If video_detail_id IS NULL → iframe, render as embed, skip metadata chips

2. Fallback: video_detail.public JSONB (old style, no video_resource rows exist)
   └─ _buildResourcesFromPublic() handles this
   └─ metadata comes from video_detail.metadata directly

3. If neither → video has no playable resource
```

---

## How to Build a Resource Object

All resource objects returned to the client should conform to this shape:

```js
{
  // Resource identity
  mime: 'video/mp4' | 'application/x-mpegURL' | 'iframe' | 'video/webm',
  resource_type: 'full' | 'preview',
  resource: '<url or null>',
  resource_raw: '<url or null>',
  token: '<jwt>',

  // Basic specs (always try to populate)
  height: 1080,
  width: 1920,
  aspect: '16:9',
  codec: 'hevc',
  vertical: false,
  duration: '00:34:51',
  seconds: 2091.391,

  // Rich metadata (optional — null for iframes and unlinked resources)
  fps: 23.976,
  file_size: 567597167,   // bytes — use this for size display, not size_mb
  bitrate: 2171175,       // bps
  frame_count: 50143,
  quality_score: 6753222720000,
}
```

> **Note on `size` vs `file_size`:** The legacy `size_mb` column on `video_detail` is in megabytes (text). The `metadata.size` field is in **bytes** and is stored as `file_size` on the resource object. Always use `file_size` for display; fall back to `size` only if `file_size` is absent.

---

## Rules for New Uploads

When a new video file is ingested:

1. Create a `video_detail` row with the full `metadata` JSONB from the pipeline.
2. For each resource URL (mp4, hls, etc.), create a `video_resource` row.
3. Set `video_resource.video_detail_id` to the new `video_detail.id`.
4. Copy `video_detail.metadata` into `video_resource.metadata`.
5. For iframe/embed resources, create a `video_resource` row with `mime = 'iframe'` and leave `video_detail_id = NULL`.

Do **not** put new resource URLs into `video_detail.public` — that column is legacy and will be deprecated.

---

## Pending Work

- [ ] `VideoOrm.retrieveVideoResourcesByVideoId` — update SELECT to return `metadata`, `fps`, `file_size`, `bitrate`, `frame_count`, `quality_score` (currently returns only basic columns)
- [ ] `retrieveVideoResources` in `Load.js` — spread metadata fields onto each resource object after the ORM query
- [ ] Move Resolution chip into `--resource-select` dropdown label (UI, deferred)
- [ ] Deprecate `video_detail.public` JSONB once all consumers use `video_resource`

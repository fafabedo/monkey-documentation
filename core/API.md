# Venux MS API Core — API Reference

> Auto-generated from `controller/routes.json` — do not edit by hand.
> Regenerate with `node scripts/generate-api-docs.js`, or browse live at `GET /doc`.

_Generated: 2026-10-10T21:50:18.632Z_

## Authentication

All endpoints require a JWT bearer token unless marked **public**:

```
Authorization: Bearer <jwt>
```

Unauthorized requests receive `403 { "status": "Forbidden" }`.

## Endpoints

| Method | Path | Description | Auth |
|---|---|---|---|
| GET | [`/`](#get) | Check health of service | public |
| GET | [`/health`](#get-health) | Check health of service (verifies DB connectivity) | public |
| GET | [`/doc`](#get-doc) | API documentation generated live from routes.json. HTML by default; ?format=md for markdown, ?format=json for machine-readable | public |
| GET | [`/api/doc`](#get-api-doc) | Alias of /doc | public |
| GET | [`/title/parse`](#get-title-parse) | Title: Return title formatted transform into object | bearer |
| GET | [`/title/parse_raw`](#get-title-parse-raw) | Title: Return raw title transform into formatted title (Rename) | bearer |
| GET | [`/title/generate_title`](#get-title-generate-title) | Title: Return generated title by video | bearer |
| POST | [`/title/generate_parts`](#post-title-generate-parts) | Title: Return title passing parts | bearer |
| POST | [`/performer/thumbnail/save`](#post-performer-thumbnail-save) | Performer: Save Photo using image URL | bearer |
| POST | [`/studio/thumbnail/gen`](#post-studio-thumbnail-gen) | Studio: Save Logo using image URL | bearer |
| POST | [`/studio/thumbnail/save`](#post-studio-thumbnail-save) | Studio: Save Logo using image URL | bearer |
| POST | [`/studio/delete/:id`](#post-studio-delete-id) | Studio: Delete studio by id | bearer |
| POST | [`/video/file/update`](#post-video-file-update) | Video: Update all file information about Video file, size, extension, codec, bitrate, ratio, frame rate and mime type. Runs ffprobe locally when the file is on this processor, or over SSH when it lives on another processor (resolved via video_detail.processor_id). | bearer |
| POST | [`/video/file/metadata`](#post-video-file-metadata) | Video: retrieve metadata from video file. Returns cached video_detail.metadata unless raw=true forces a fresh ffprobe. | bearer |
| POST | [`/video/file/delete/:id`](#post-video-file-delete-id) | Video: delete video file from disk (DB record is kept) | bearer |
| POST | [`/video/refresh`](#post-video-refresh) | Video: Refresh video, video detail, video_key, metadata | bearer |
| POST | [`/video/validate`](#post-video-validate) | Video: Validate Plex Media exists | bearer |
| GET | [`/video/thumbnail/plex`](#get-video-thumbnail-plex) | Video: Retrieve Video Thumbnail from Media Plex | bearer |
| POST | [`/video/thumbnail/save`](#post-video-thumbnail-save) | Video: Save Video Thumbnail using an image URL | bearer |
| POST | [`/tagging`](#post-tagging) | Tagging: Re-run auto-tagging. Pass exactly one of video_id, studio_id or performer_id — studio_id and performer_id process all their videos. | bearer |
| POST | [`/s3/delete`](#post-s3-delete) | S3: Remove a resource. A trailing slash on resource deletes recursively; wildcard limits matches (e.g. *.ts). | bearer |

---

### <a id="get"></a>`GET /`

Check health of service

**Auth:** public — no token required

**Example response:**
```json
"Adult Core API"
```

---

### <a id="get-health"></a>`GET /health`

Check health of service (verifies DB connectivity)

**Auth:** public — no token required

**Example response:**
```json
[
  {
    "id": 1,
    "name": "..."
  }
]
```

---

### <a id="get-doc"></a>`GET /doc`

API documentation generated live from routes.json. HTML by default; ?format=md for markdown, ?format=json for machine-readable

**Auth:** public — no token required

**Example request:**
```
GET /doc?format=json
```

**Example response:**
```json
{
  "service": "Venux MS API Core",
  "endpoints": [
    "..."
  ]
}
```

---

### <a id="get-api-doc"></a>`GET /api/doc`

Alias of /doc

**Auth:** public — no token required

---

### <a id="get-title-parse"></a>`GET /title/parse`

Title: Return title formatted transform into object

**Params:** `title`

**Example request:**
```
GET /title/parse?title=Studio%20-%20Performer%20A%2C%20Performer%20B%20-%20Scene%20Name%20(2026-02-10)
```

**Example response:**
```json
{
  "success": true,
  "title": "Studio - Performer A, Performer B - Scene Name (2026-02-10)",
  "processed": {
    "studio": "Studio",
    "performers": [
      "Performer A",
      "Performer B"
    ],
    "title": "Scene Name",
    "release_date": "2026-02-10"
  }
}
```

---

### <a id="get-title-parse-raw"></a>`GET /title/parse_raw`

Title: Return raw title transform into formatted title (Rename)

**Params:** `title (obj)`

**Example request:**
```
GET /title/parse_raw?title=studio.26.02.10.performer.scene.name.1080p
```

**Example response:**
```json
{
  "success": true,
  "title": "studio.26.02.10.performer.scene.name.1080p",
  "parsed": {
    "studio": "Studio",
    "release_date": "2026-02-10",
    "title": "Scene Name"
  }
}
```

---

### <a id="get-title-generate-title"></a>`GET /title/generate_title`

Title: Return generated title by video

**Params:** `id (int)`

**Example request:**
```
GET /title/generate_title?id=33886
```

**Example response:**
```json
{
  "success": true,
  "generatedTitle": "Studio - Performer - Scene Name (2026-02-10)"
}
```

---

### <a id="post-title-generate-parts"></a>`POST /title/generate_parts`

Title: Return title passing parts

**Params:** `parts (array)`

**Example payload:**
```json
{
  "parts": {
    "title": "Scene Name",
    "studio": "Studio",
    "release_date": "2026-02-10",
    "performers": [
      "Performer A"
    ]
  }
}
```

**Example response:**
```json
{
  "success": true,
  "generatedTitle": "Studio - Performer A - Scene Name (2026-02-10)"
}
```

---

### <a id="post-performer-thumbnail-save"></a>`POST /performer/thumbnail/save`

Performer: Save Photo using image URL

**Params:** `id, thumbnail`

**Example payload:**
```json
{
  "id": 123,
  "thumbnail": "https://cdn.example.com/photo.jpg"
}
```

**Example response:**
```json
{
  "success": true,
  "media": {
    "thumbnail": "..."
  }
}
```

---

### <a id="post-studio-thumbnail-gen"></a>`POST /studio/thumbnail/gen`

Studio: Save Logo using image URL

**Params:** `id, thumbnail`

**Example payload:**
```json
{
  "id": 45,
  "thumbnail": "https://cdn.example.com/logo.png"
}
```

**Example response:**
```json
{
  "success": true,
  "studio": {
    "id": 45
  }
}
```

---

### <a id="post-studio-thumbnail-save"></a>`POST /studio/thumbnail/save`

Studio: Save Logo using image URL

**Params:** `id, thumbnail`

**Example payload:**
```json
{
  "id": 45,
  "thumbnail": "https://cdn.example.com/logo.png"
}
```

**Example response:**
```json
{
  "success": true,
  "studio": {
    "id": 45
  }
}
```

---

### <a id="post-studio-delete-id"></a>`POST /studio/delete/:id`

Studio: Delete studio by id

**Params:** `id`

**Example response:**
```json
{
  "status": "delete",
  "id": 45
}
```

---

### <a id="post-video-file-update"></a>`POST /video/file/update`

Video: Update all file information about Video file, size, extension, codec, bitrate, ratio, frame rate and mime type. Runs ffprobe locally when the file is on this processor, or over SSH when it lives on another processor (resolved via video_detail.processor_id).

**Params:** `id`

**Example payload:**
```json
{
  "id": 33886
}
```

**Example response:**
```json
{
  "video_detail": {
    "id": 28780,
    "video": 33886,
    "file": "/mnt/storage/.../video.mp4",
    "mime": "video/mp4",
    "codec": "hevc",
    "width": 1920,
    "height": 1080,
    "duration": "00:30:11",
    "duration_seconds": 1811.22,
    "size": 350582889,
    "processor_id": 3,
    "metadata": {
      "fps": 23.976,
      "bitrate": 1548493,
      "score": 4816432627200
    }
  },
  "video_resource": {
    "id": 16218,
    "video_id": 33886,
    "video_detail_id": 28780,
    "resource_type": "full",
    "resource": "https://video-stream.example.com/video/download/<video-uuid>/<detail-uuid>",
    "mime": "video/mp4",
    "height": 1080,
    "width": 1920,
    "codec": "hevc"
  }
}
```

---

### <a id="post-video-file-metadata"></a>`POST /video/file/metadata`

Video: retrieve metadata from video file. Returns cached video_detail.metadata unless raw=true forces a fresh ffprobe.

**Params:** `id, raw (optional)`

**Example payload:**
```json
{
  "id": 33886,
  "raw": false
}
```

**Example response:**
```json
{
  "mime": "video/mp4",
  "codec": "hevc",
  "width": 1920,
  "height": 1080,
  "fps": 23.976,
  "bitrate": 1548493,
  "seconds": 1811.22,
  "duration": "00:30:11",
  "size": 350582889,
  "human_size": "334.34 Mb",
  "aspect_ratio": "16:9",
  "score": 4816432627200
}
```

---

### <a id="post-video-file-delete-id"></a>`POST /video/file/delete/:id`

Video: delete video file from disk (DB record is kept)

**Params:** `id`

**Example response:**
```json
{
  "status": "success"
}
```

---

### <a id="post-video-refresh"></a>`POST /video/refresh`

Video: Refresh video, video detail, video_key, metadata

**Params:** `id, options`

**Example payload:**
```json
{
  "id": 33886,
  "options": {
    "download": false,
    "embed": true,
    "video_key": false
  }
}
```

**Example response:**
```json
{
  "id": 33886,
  "title": "...",
  "detail": {
    "id": 28780,
    "public": {
      "download": "https://..."
    }
  }
}
```

---

### <a id="post-video-validate"></a>`POST /video/validate`

Video: Validate Plex Media exists

**Params:** `id`

**Example payload:**
```json
{
  "id": 33886
}
```

**Example response:**
```json
{
  "valid": true
}
```

---

### <a id="get-video-thumbnail-plex"></a>`GET /video/thumbnail/plex`

Video: Retrieve Video Thumbnail from Media Plex

**Params:** `media_id`

**Example request:**
```
GET /video/thumbnail/plex?media_id=98765
```

**Example response:**
```json
{
  "thumbnail": "https://plex.example.com/library/metadata/98765/thumb"
}
```

---

### <a id="post-video-thumbnail-save"></a>`POST /video/thumbnail/save`

Video: Save Video Thumbnail using an image URL

**Params:** `id, thumbnail`

**Example payload:**
```json
{
  "id": 33886,
  "thumbnail": "https://cdn.example.com/capture.jpg"
}
```

**Example response:**
```json
{
  "success": true
}
```

---

### <a id="post-tagging"></a>`POST /tagging`

Tagging: Re-run auto-tagging. Pass exactly one of video_id, studio_id or performer_id — studio_id and performer_id process all their videos.

**Params:** `video_id | studio_id | performer_id`

**Example payload:**
```json
{
  "video_id": 33886
}
```

**Example response:**
```json
{
  "processed": 1,
  "tags": [
    "tag-a",
    "tag-b"
  ]
}
```

---

### <a id="post-s3-delete"></a>`POST /s3/delete`

S3: Remove a resource. A trailing slash on resource deletes recursively; wildcard limits matches (e.g. *.ts).

**Params:** `resource, wildcard (optional)`

**Example payload:**
```json
{
  "resource": "videos/33886/",
  "wildcard": "*.ts"
}
```

**Example response:**
```json
{
  "message": "Resource removed",
  "status": true
}
```

---

## Disabled endpoints

Declared in `routes.json` but not currently mounted:

| Method | Path | Description |
|---|---|---|
| POST | `/performer/switch` | Performer: Switch performer from [x] to [y] |
| POST | `/performer/delete/:id` | Performer: Delete performer |
| POST | `/video/update` | Video: Update video and validate data |
| POST | `/video/delete/:id` | Video: Delete video |
| POST | `/video/sorting` | Video: Sort video in correct folder |
| POST | `/indexing/:type/index` | Indexing: Index content by type and id |
| POST | `/indexing/:type/bulk_index` | Indexing: Index content by type and id |

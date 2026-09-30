# monkey-rust-vault — Architecture & Implementation Prompt

Use this document to port, replicate, or integrate the monkey-rust-vault system into another application or language. It is self-contained and describes the full design rationale, database schema, resolution logic, and key decisions made during implementation.

---

## What this system does

`monkey-rust-vault` is a **unified file upload service** that abstracts multiple storage backends behind a single API endpoint. Callers specify a destination using a URI scheme (e.g. `s3://`, `temp://`), and the service routes the upload to the correct backend, encrypts credentials at rest, verifies the upload, and records a full audit trail in PostgreSQL.

The system runs as a standalone HTTP microservice. Other applications call it over HTTP — they never talk to S3, Dropbox, or the local filesystem directly.

---

## Storage backends supported

| URI scheme | Backend |
|---|---|
| `s3://` | AWS S3 |
| `drop://` | Dropbox |
| `drive://` | Google Drive |
| `fs://` | Local filesystem (fixed path, bucket-scoped) |
| `temp://` `queue://` `trash://` or any custom name | Local filesystem (processor-scoped mount) |

The first four are **cloud or fixed-path** — credentials and paths are stored in the database per bucket. The last group are **processor-local mounts** — the physical path is resolved at runtime based on which processor instance is handling the request.

---

## Database schema

All vault tables live in the `monkey_vault` PostgreSQL schema. The processor identity table lives in `public` (shared across applications).

### Schema overview

```
public.processor  (existing, shared)
    └── monkey_vault.storage_processor_mounts  (many)
    └── monkey_vault.storage_files.processor_id  (nullable FK)

monkey_vault.storage_providers  (1)
    └── monkey_vault.storage_provider_credentials  (1)
    └── monkey_vault.storage_buckets  (many)
            └── monkey_vault.storage_files  (many)
```

---

### `public.processor`

Pre-existing table. Extended with a `slug` column for vault use.

```sql
ALTER TABLE public.processor ADD COLUMN slug TEXT UNIQUE;
```

The `slug` is the value each running vault instance sets as `PROCESSOR_ID` in its `.env`. Example slugs: `mac-fabricio`, `athens-server`, `studio-workstation-1`.

---

### `monkey_vault.storage_provider_type` (enum)

```sql
CREATE TYPE monkey_vault.storage_provider_type AS ENUM ('s3', 'dropbox', 'google_drive', 'local');
```

---

### `monkey_vault.storage_providers`

Defines available storage backends.

```sql
CREATE TABLE monkey_vault.storage_providers (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL UNIQUE,
  type       monkey_vault.storage_provider_type NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

---

### `monkey_vault.storage_provider_credentials`

Stores AES-256-GCM encrypted credentials. One row per provider. Sensitive fields are encrypted before insert and decrypted only at upload time.

```sql
CREATE TABLE monkey_vault.storage_provider_credentials (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id              UUID NOT NULL REFERENCES monkey_vault.storage_providers(id) ON DELETE CASCADE,
  -- AWS S3
  aws_profile              TEXT,
  aws_access_key_enc       TEXT,   -- AES-256-GCM encrypted, base64(nonce || ciphertext)
  aws_secret_key_enc       TEXT,
  aws_region               TEXT,
  -- Dropbox
  dropbox_access_token_enc TEXT,
  -- Google Drive
  google_sa_json_enc       TEXT,   -- encrypted service account JSON blob
  -- Local FS
  local_base_path          TEXT,   -- absolute path on server, e.g. /mnt/vault
  local_server_ip          TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(provider_id)
);
```

---

### `monkey_vault.storage_buckets`

One row per logical bucket. The `slug` is the identifier used in URIs.

```sql
CREATE TABLE monkey_vault.storage_buckets (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug              TEXT NOT NULL UNIQUE,  -- used in URI: "my-bucket-01"
  display_name      TEXT NOT NULL,
  provider_id       UUID NOT NULL REFERENCES monkey_vault.storage_providers(id),
  s3_bucket_name    TEXT,
  dropbox_root_path TEXT,
  drive_folder_id   TEXT,
  local_sub_path    TEXT,
  instance_id       UUID,
  space_id          UUID,
  is_active         BOOLEAN NOT NULL DEFAULT true,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

---

### `monkey_vault.storage_files`

Full upload history. Every upload — cloud or local — gets a row here.

```sql
CREATE TABLE monkey_vault.storage_files (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id       UUID REFERENCES monkey_vault.storage_buckets(id),  -- NULL for processor mounts
  processor_id    BIGINT REFERENCES public.processor(id),             -- NULL for cloud uploads
  relative_path   TEXT NOT NULL,
  uri             TEXT NOT NULL,
  file_name       TEXT NOT NULL,
  file_size       BIGINT,
  mime_type       TEXT,
  checksum_sha256 TEXT,
  upload_status   TEXT NOT NULL DEFAULT 'pending',  -- pending | verified | failed
  uploaded_by     UUID,
  instance_id     UUID,
  space_id        UUID,
  provider_ref    TEXT,   -- S3 ETag, Drive file ID, Dropbox path, local absolute path
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(bucket_id, relative_path)
);
```

**`processor_id` rule:**
- Cloud uploads (`s3://`, `drop://`, `drive://`): `processor_id = NULL`
- Processor-local uploads (`temp://`, `queue://`, custom): `processor_id = <current processor>`

---

### `monkey_vault.storage_processor_mounts`

Maps a named mount type to a local filesystem path on a specific processor. This is what makes `temp://`, `queue://`, and any custom scheme work.

```sql
CREATE TABLE monkey_vault.storage_processor_mounts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  processor_id BIGINT NOT NULL REFERENCES public.processor(id) ON DELETE CASCADE,
  mount_type   TEXT NOT NULL,   -- "temp", "queue", "trash", "xxx_studio_1", etc.
  local_path   TEXT NOT NULL,   -- absolute path on that processor's machine
  description  TEXT,
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(processor_id, mount_type)
);
```

**Example rows:**

```sql
-- Processor 10 (mac-fabricio): temp:// → /Users/e043280/Temporary/Venux/Temp
INSERT INTO monkey_vault.storage_processor_mounts (processor_id, mount_type, local_path)
VALUES (10, 'temp', '/Users/e043280/Temporary/Venux/Temp');

-- Processor 10: queue:// → /Users/e043280/Temporary/Venux/Queue
INSERT INTO monkey_vault.storage_processor_mounts (processor_id, mount_type, local_path)
VALUES (10, 'queue', '/Users/e043280/Temporary/Venux/Queue');

-- Processor 10: custom scheme xxx_studio_1:// → /Users/e043280/studio/workspace-1
INSERT INTO monkey_vault.storage_processor_mounts (processor_id, mount_type, local_path)
VALUES (10, 'xxx_studio_1', '/Users/e043280/studio/workspace-1');
```

`mount_type` is free-form text — any string becomes a valid URI scheme for that processor. Note: URI schemes with underscores (`_`) are technically outside RFC 3986; use dashes (`-`) if strict client compatibility matters.

---

## Environment variables

```bash
BIND_ADDR=127.0.0.1:4200

# Supabase (PostgREST)
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_KEY=your-service-role-key

# AES-256-GCM encryption key — exactly 32 bytes, hex-encoded (64 chars)
# Generate: openssl rand -hex 32
VAULT_ENCRYPTION_KEY=your-64-char-hex-key

# AWS fallback region
AWS_DEFAULT_REGION=us-east-1

# Processor identity — must match a slug in public.processor
# Leave empty or omit if this instance will not handle processor-local uploads
PROCESSOR_ID=mac-fabricio

RUST_LOG=monkey_vault=info,tower_http=info
```

---

## API

### `POST /upload`

**Content-Type:** `multipart/form-data`

| Field | Type | Required | Description |
|---|---|---|---|
| `uri` | text | Yes | Destination URI, e.g. `s3://my-bucket/path/file.csv` or `temp://folder/file.mp4` |
| `file` | binary | Yes | File data |
| `instance_id` | UUID | No | Caller's instance identifier |
| `space_id` | UUID | No | Caller's space identifier |

**Response (200):**
```json
{ "success": true, "uri": "s3://my-bucket/path/file.csv", "file_id": "<uuid>" }
```

### `GET /health`

Returns `200 ok`.

---

## URI resolution logic

This is the core routing logic. Implement it as follows:

```
1. Parse URI → extract scheme and relative path
   "s3://my-bucket/reports/jan.csv"   → scheme="s3",    path="reports/jan.csv",  bucket_slug="my-bucket"
   "temp://folder1/folder2/file.mp4"  → scheme="temp",  path="folder1/folder2/file.mp4"
   "xxx_studio_1://project/scene.obj" → scheme="xxx_studio_1", path="project/scene.obj"

2. Is scheme a known cloud scheme? (s3, drop, drive, fs)
   YES → look up storage_buckets by slug, fetch provider + encrypted credentials,
         route to cloud driver (S3, Dropbox, Drive, or fixed-path local)
         processor_id in storage_files = NULL

   NO  → treat scheme as a processor mount type
         look up storage_processor_mounts WHERE processor_id = <current PROCESSOR_ID>
           AND mount_type = scheme AND is_active = true
         resolve full path = local_path + "/" + relative_path
         create parent directories recursively if they don't exist
         write file using local filesystem driver
         processor_id in storage_files = <current processor's DB id>
```

---

## Upload flow (full)

```
Client POST /upload
  │
  ├─ Parse multipart form (uri, file, instance_id?, space_id?)
  ├─ Parse URI → scheme + path
  │
  ├─ Cloud scheme?
  │     YES → fetch bucket row (by slug) + provider credentials from DB
  │           decrypt credentials (AES-256-GCM)
  │           check path collisions → append _1, _2 if needed
  │           insert storage_files row (status=pending, processor_id=NULL)
  │           upload to provider
  │           verify upload exists on provider
  │           update storage_files (status=verified, checksum, provider_ref)
  │
  └─ Processor mount scheme?
        YES → fetch storage_processor_mounts (processor_id + mount_type)
              resolve absolute path = local_path + "/" + relative_path
              check path collisions in storage_files
              insert storage_files row (status=pending, bucket_id=NULL, processor_id=<id>)
              create parent dirs recursively (os.makedirs / fs::create_dir_all)
              write file bytes to disk
              compute SHA-256 checksum
              verify file exists at path
              update storage_files (status=verified, checksum, provider_ref=absolute_path)

  → return { success, uri, file_id }
```

---

## Credential encryption

- **Algorithm:** AES-256-GCM (authenticated encryption)
- **Key:** 32 bytes, stored as 64-char hex in `VAULT_ENCRYPTION_KEY`
- **Wire format stored in DB:** `base64(nonce || ciphertext)` where nonce is 12 bytes (96-bit), randomly generated per encryption
- **Decrypt at runtime only** — never store plaintext credentials
- Provide a CLI utility (`encrypt_secret`) that takes a plaintext value and prints the encrypted base64 string for seeding the DB

---

## Path deduplication

Before writing, check if `(bucket_id, relative_path)` or `(processor_id, relative_path)` already exists in `storage_files` with a non-failed status. If so, append `_1`, `_2`, etc. to the filename stem before the extension until a free path is found.

```
reports/jan.csv  →  reports/jan_1.csv  →  reports/jan_2.csv
```

---

## Local filesystem behaviour

- Parent directories are created recursively before writing (equivalent of `mkdir -p`)
- `temp://folder1/folder2/file.mp4` automatically creates `folder1/` and `folder1/folder2/` on the target processor
- `provider_ref` in `storage_files` stores the absolute path on disk for cross-app lookups

---

## Cross-app file discovery

Other applications can query `storage_files` to locate files without going through the vault API:

```sql
-- All files on a specific processor
SELECT * FROM monkey_vault.storage_files
WHERE processor_id = (SELECT id FROM public.processor WHERE slug = 'mac-fabricio');

-- All files queued on any processor
SELECT f.*, p.slug AS processor_slug, p.ip_address
FROM monkey_vault.storage_files f
JOIN public.processor p ON p.id = f.processor_id
WHERE f.uri LIKE 'queue://%' AND f.upload_status = 'verified';

-- All cloud files (no machine dependency)
SELECT * FROM monkey_vault.storage_files WHERE processor_id IS NULL;

-- Find a specific file by URI across all processors
SELECT * FROM monkey_vault.storage_files WHERE uri = 'temp://exports/report.csv';
```

---

## Supabase PostgREST setup

All requests to PostgREST must include schema profile headers:
- `GET` / `HEAD` requests: `Accept-Profile: monkey_vault`
- `POST` / `PATCH` / `PUT` requests: `Content-Profile: monkey_vault`

Required one-time setup in Supabase dashboard:
1. **API → Exposed schemas** — add `monkey_vault`
2. Run grants so PostgREST roles can access the schema:

```sql
GRANT USAGE ON SCHEMA monkey_vault TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES    IN SCHEMA monkey_vault TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA monkey_vault TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA monkey_vault TO anon, authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA monkey_vault
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA monkey_vault
  GRANT SELECT ON TABLES TO anon, authenticated;
```

---

## Key design decisions

| Decision | Rationale |
|---|---|
| Separate `monkey_vault` schema | Avoids table name collisions with other apps in `public` |
| AES-256-GCM for credentials | Authenticated encryption — detects tampering, no plaintext at rest |
| `mount_type` as free-form text | Any string becomes a valid URI scheme — no code changes needed to add new mounts |
| `processor_id = NULL` for cloud | Cloud files have no machine affinity — simplifies cross-processor queries |
| Cross-schema FK to `public.processor` | Reuses existing processor identity rather than duplicating it |
| `create_dir_all` before write | Callers never need to pre-create directories — `temp://a/b/c/file` always works |
| Path deduplication via DB | Avoids silent overwrites; collision history is auditable |
| Single `/upload` endpoint | Callers don't need to know the backend — URI scheme carries all routing info |

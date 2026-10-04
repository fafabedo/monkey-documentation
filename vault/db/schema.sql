-- =============================================================================
-- monkey-vault — complete schema (monkey_vault)
-- =============================================================================
-- Fresh install: run schema.sql → grants.sql → public_extensions.sql
-- Existing install: run migrations 001–011 instead.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS monkey_vault;

-- ---------------------------------------------------------------------------
-- Enum
-- ---------------------------------------------------------------------------

CREATE TYPE monkey_vault.storage_provider_type AS ENUM (
  's3',
  'dropbox',
  'google_drive',
  'local'
);

-- ---------------------------------------------------------------------------
-- storage_provider
-- Defines available storage backends and whether they are active.
-- ---------------------------------------------------------------------------

CREATE TABLE monkey_vault.storage_provider (
  id         UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT    NOT NULL UNIQUE,
  type       monkey_vault.storage_provider_type NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- storage_provider_credential
-- Encrypted credentials for each provider (one row per provider).
-- All *_enc fields are AES-256-GCM encrypted, stored as base64(nonce || ciphertext).
-- Decrypt at runtime only — never store plaintext.
-- ---------------------------------------------------------------------------

CREATE TABLE monkey_vault.storage_provider_credential (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id              UUID NOT NULL REFERENCES monkey_vault.storage_provider(id) ON DELETE CASCADE,

  -- AWS S3
  aws_profile              TEXT,
  aws_access_key_enc       TEXT,
  aws_secret_key_enc       TEXT,
  aws_region               TEXT,

  -- Dropbox
  dropbox_access_token_enc TEXT,

  -- Google Drive (service account JSON blob, encrypted)
  google_sa_json_enc       TEXT,

  -- Local filesystem
  local_base_path          TEXT,   -- absolute path on the server, e.g. /mnt/vault
  local_server_ip          TEXT,   -- informational only

  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE(provider_id)
);

-- ---------------------------------------------------------------------------
-- storage_bucket
-- One row per logical bucket. The slug is used in cloud URIs: s3://slug/path
-- ---------------------------------------------------------------------------

CREATE TABLE monkey_vault.storage_bucket (
  id                UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  slug              TEXT    NOT NULL UNIQUE,  -- URI identifier, e.g. "monkeylibrary-csv-imports"
  display_name      TEXT    NOT NULL,
  provider_id       UUID    NOT NULL REFERENCES monkey_vault.storage_provider(id),

  -- Provider-specific config (only the relevant column is populated)
  s3_bucket_name    TEXT,
  dropbox_root_path TEXT,
  drive_folder_id   TEXT,
  local_sub_path    TEXT,

  -- Multi-tenant tracking
  instance_id       UUID,
  space_id          UUID,

  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_storage_bucket_slug ON monkey_vault.storage_bucket(slug);

-- ---------------------------------------------------------------------------
-- storage_processor_mount
-- Maps named URI schemes (temp, queue, trash, custom) to local paths on a
-- specific processor. References public.processor for processor identity.
--
-- URI scheme resolution:
--   temp://folder/file.mp4  →  mount_type='temp'  →  local_path + /folder/file.mp4
--
-- mount_type is free-form text — any value becomes a valid URI scheme.
-- Processor isolation is physical: paths only exist on the registered machine.
-- ---------------------------------------------------------------------------

CREATE TABLE monkey_vault.storage_processor_mount (
  id           UUID   PRIMARY KEY DEFAULT gen_random_uuid(),
  processor_id BIGINT NOT NULL REFERENCES public.processor(id) ON DELETE CASCADE,
  mount_type   TEXT   NOT NULL,   -- "temp", "queue", "trash", or any custom name
  local_path   TEXT   NOT NULL,   -- absolute path on that processor's filesystem
  description  TEXT,
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE(processor_id, mount_type)
);

CREATE INDEX idx_processor_mount_processor ON monkey_vault.storage_processor_mount(processor_id);

-- ---------------------------------------------------------------------------
-- storage_file
-- Full audit trail for every upload — cloud and processor-local.
--
-- bucket_id    — set for cloud/fixed-path uploads (s3, dropbox, drive, fs)
--              — NULL for processor-local uploads (temp, queue, custom schemes)
-- processor_id — set for processor-local uploads
--              — NULL for cloud uploads (file has no machine affinity)
--
-- upload_status lifecycle: pending → verified | failed
-- provider_ref: S3 ETag, Drive file ID, Dropbox path_display, or local absolute path
-- ---------------------------------------------------------------------------

CREATE TABLE monkey_vault.storage_file (
  id              UUID   PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id       UUID   REFERENCES monkey_vault.storage_bucket(id),    -- nullable for processor mounts
  processor_id    BIGINT REFERENCES public.processor(id),                -- nullable for cloud uploads
  relative_path   TEXT   NOT NULL,
  uri             TEXT   NOT NULL,
  file_name       TEXT   NOT NULL,
  file_size       BIGINT,
  mime_type       TEXT,
  checksum_sha256 TEXT,
  upload_status   TEXT   NOT NULL DEFAULT 'pending',  -- pending | verified | failed
  uploaded_by     UUID,
  instance_id     UUID,
  space_id        UUID,
  provider_ref    TEXT,
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE(bucket_id, relative_path)
);

CREATE INDEX idx_storage_file_uri       ON monkey_vault.storage_file(uri);
CREATE INDEX idx_storage_file_bucket    ON monkey_vault.storage_file(bucket_id);
CREATE INDEX idx_storage_file_processor ON monkey_vault.storage_file(processor_id);

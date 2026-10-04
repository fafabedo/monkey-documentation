-- =============================================================================
-- monkey-vault — example seed data
-- =============================================================================
-- Illustrates how to configure providers, buckets, and processor mounts.
-- Adjust slugs, paths, and IDs to match your environment.
-- Encrypt all *_enc values with: VAULT_ENCRYPTION_KEY=<key> cargo run --bin encrypt_secret -- "value"
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Providers
-- ---------------------------------------------------------------------------

INSERT INTO monkey_vault.storage_provider (name, type, is_active) VALUES
  ('AWS S3 Main',    's3',          true),
  ('Dropbox Shared', 'dropbox',     false),
  ('Google Drive',   'google_drive', false),
  ('Local Server',   'local',       true);

-- ---------------------------------------------------------------------------
-- Credentials (use encrypt_secret to generate *_enc values)
-- ---------------------------------------------------------------------------

-- S3
INSERT INTO monkey_vault.storage_provider_credential (provider_id, aws_access_key_enc, aws_secret_key_enc, aws_region)
VALUES (
  (SELECT id FROM monkey_vault.storage_provider WHERE name = 'AWS S3 Main'),
  '<encrypted-access-key>',
  '<encrypted-secret-key>',
  'us-east-1'
);

-- Local
INSERT INTO monkey_vault.storage_provider_credential (provider_id, local_base_path)
VALUES (
  (SELECT id FROM monkey_vault.storage_provider WHERE name = 'Local Server'),
  '/mnt/vault'
);

-- ---------------------------------------------------------------------------
-- Buckets
-- ---------------------------------------------------------------------------

-- S3 bucket — accessible as s3://monkeylibrary-csv-imports/path/file.csv
INSERT INTO monkey_vault.storage_bucket (slug, display_name, provider_id, s3_bucket_name) VALUES (
  'monkeylibrary-csv-imports',
  'Monkey CSV Imports',
  (SELECT id FROM monkey_vault.storage_provider WHERE name = 'AWS S3 Main'),
  'monkeylibrary-csv-imports'
);

-- ---------------------------------------------------------------------------
-- Processor slugs (set the matching PROCESSOR_ID in each instance's .env)
-- ---------------------------------------------------------------------------

-- UPDATE public.processor SET slug = 'mac-fabricio'    WHERE id = 10;
-- UPDATE public.processor SET slug = 'athens-server'   WHERE id = 5;

-- ---------------------------------------------------------------------------
-- Processor mounts
-- ---------------------------------------------------------------------------

-- Processor 10 (mac-fabricio)
--   temp://folder/file  →  /Users/e043280/Temporary/Venux/Temp/folder/file
--   queue://file        →  /Users/e043280/Temporary/Venux/Queue/file
--   trash://file        →  /Users/e043280/Temporary/Venux/Trash/file

INSERT INTO monkey_vault.storage_processor_mount (processor_id, mount_type, local_path, description) VALUES
  (10, 'temp',  '/Users/e043280/Temporary/Venux/Temp',  'Temporary staging area'),
  (10, 'queue', '/Users/e043280/Temporary/Venux/Queue', 'Processing queue'),
  (10, 'trash', '/Users/e043280/Temporary/Venux/Trash', 'Soft delete holding area');

-- Custom scheme example: xxx_studio_1://project/scene.obj
-- INSERT INTO monkey_vault.storage_processor_mount (processor_id, mount_type, local_path)
-- VALUES (10, 'xxx_studio_1', '/Users/e043280/studio/workspace-1');

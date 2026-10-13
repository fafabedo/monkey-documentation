--- EXPORT ---
SELECT
    'CREATE OR REPLACE FUNCTION ' || p.proname || E'\n' ||
    pg_get_functiondef(p.oid) || E';\n'
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
ORDER BY p.proname;


--- REMOVE ---
DROP FUNCTION IF EXISTS public.update_like_counter_after_delete() CASCADE;
DROP FUNCTION IF EXISTS public.update_like_counter_after_insert() CASCADE;

DROP FUNCTION IF EXISTS public.update_performer_tags_after_delete() CASCADE;
DROP FUNCTION IF EXISTS public.update_performer_tags_after_insert() CASCADE;

DROP FUNCTION IF EXISTS public.update_studio_counter_after_insert() CASCADE;
DROP FUNCTION IF EXISTS public.update_studio_counter_after_video_delete() CASCADE;

DROP FUNCTION IF EXISTS public.update_studio_tag_json_after_studio_tag_delete() CASCADE;
DROP FUNCTION IF EXISTS public.update_studio_tag_json_after_studio_tag_update() CASCADE;

DROP FUNCTION IF EXISTS public.update_studio_tag_keys_after_delete() CASCADE;
DROP FUNCTION IF EXISTS public.update_studio_tag_keys_after_insert() CASCADE;

DROP FUNCTION IF EXISTS public.update_video_performer_keys_after_delete() CASCADE;
DROP FUNCTION IF EXISTS public.update_video_performer_keys_after_insert() CASCADE;

DROP FUNCTION IF EXISTS public.update_video_tag_keys_and_tags_after_delete() CASCADE;
DROP FUNCTION IF EXISTS public.update_video_tag_keys_and_tags_after_insert_or_update() CASCADE;

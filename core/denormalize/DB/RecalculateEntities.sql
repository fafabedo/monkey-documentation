-- ============================================================
-- recalculate_video(p_video_id bigint)
--
-- Updates ALL denormalized fields on the video row and cascades
-- to performer.counter (all performers on the video) and
-- studio.counter (direct studio + parent studio if any).
--
-- Supabase RPC: supabase.rpc('recalculate_video', { p_video_id: 123 })
-- ============================================================

CREATE OR REPLACE FUNCTION recalculate_video(p_video_id bigint)
RETURNS void AS $$
DECLARE
    v_like_counter    bigint;
    v_view_counter    bigint;
    v_metadata        json;
    v_studio_id       bigint;
    v_studio_parent   bigint;
    v_best_height     bigint;
    v_best_duration   text;
BEGIN
    SELECT like_counter, view_counter, metadata, studio
    INTO   v_like_counter, v_view_counter, v_metadata, v_studio_id
    FROM   video
    WHERE  id = p_video_id;

    -- Best resource = highest-resolution full resource
    SELECT height, duration
    INTO   v_best_height, v_best_duration
    FROM   video_resource
    WHERE  video_id = p_video_id
      AND  resource_type = 'full'
    ORDER  BY height DESC NULLS LAST
    LIMIT  1;

    UPDATE video
    SET
        performer_keys = COALESCE(
            (SELECT concat('|', string_agg(vp.performer::text, '|'), '|')
             FROM   video_performer vp
             WHERE  vp.video = p_video_id),
            ''
        ),
        tag_keys = COALESCE(
            (SELECT concat('|', string_agg(vt.tag::text, '|'), '|')
             FROM   video_tag vt
             WHERE  vt.video = p_video_id),
            ''
        ),
        performers = COALESCE(
            (SELECT json_agg(json_build_object(
                        'id',   p.id,
                        'name', p.name,
                        'uuid', p.uuid,
                        'slug', p.slug))
             FROM   video_performer vp
             JOIN   performer p ON vp.performer = p.id
             WHERE  vp.video = p_video_id),
            '[]'::json
        ),
        tags = COALESCE(
            (SELECT json_agg(json_build_object(
                        'id',   t.id,
                        'name', t.name,
                        'uuid', t.uuid,
                        'slug', t.slug))
             FROM   video_tag vt
             JOIN   tag t ON vt.tag = t.id
             WHERE  vt.video = p_video_id),
            '[]'::json
        ),
        -- Merge computed fields into existing metadata to preserve other keys
        metadata = (
            COALESCE(v_metadata::jsonb, '{}'::jsonb) || jsonb_build_object(
                'likes',          v_like_counter,
                'views',          v_view_counter,
                'visits',         v_view_counter,  -- no separate visit interaction yet; mirrors views
                'plays',          v_view_counter,  -- no separate play interaction yet; mirrors views
                'video_height',   v_best_height,
                'video_duration', v_best_duration
            )
        )::json
    WHERE id = p_video_id;

    -- Cascade: recount video uses per tag for every tag on this video
    UPDATE tag t
    SET    counter = (SELECT count(*) FROM video_tag vt WHERE vt.tag = t.id)
    WHERE  t.id IN (SELECT tag FROM video_tag WHERE video = p_video_id);

    -- Cascade: recount videos per performer for every performer on this video
    UPDATE performer p
    SET    counter = (
               SELECT count(*)
               FROM   video_performer vp2
               WHERE  vp2.performer = p.id
           ),
           last_upload_at = GREATEST(
               p.last_upload_at,
               (SELECT MAX(v.created_at)
                FROM   video_performer vp2
                JOIN   video v ON vp2.video = v.id
                WHERE  vp2.performer = p.id)
           )
    WHERE  p.id IN (
               SELECT vp.performer FROM video_performer vp WHERE vp.video = p_video_id
           );

    -- Cascade: recount videos per studio (direct + parent)
    IF v_studio_id IS NOT NULL THEN
        UPDATE studio
        SET    counter = (SELECT count(*) FROM video WHERE studio = v_studio_id),
               last_upload_at = GREATEST(
                   last_upload_at,
                   (SELECT MAX(created_at) FROM video WHERE studio = v_studio_id)
               )
        WHERE  id = v_studio_id;

        SELECT parent INTO v_studio_parent FROM studio WHERE id = v_studio_id;

        IF v_studio_parent IS NOT NULL THEN
            UPDATE studio
            SET    counter = (SELECT count(*) FROM video WHERE studio = v_studio_parent),
                   last_upload_at = GREATEST(
                       last_upload_at,
                       (SELECT MAX(created_at) FROM video WHERE studio = v_studio_parent)
                   )
            WHERE  id = v_studio_parent;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- recalculate_performer(p_performer_id bigint)
--
-- Updates ALL denormalized fields on the performer row.
-- visited = sum of view_counter across all videos the performer appears in.
--
-- Supabase RPC: supabase.rpc('recalculate_performer', { p_performer_id: 123 })
-- ============================================================

CREATE OR REPLACE FUNCTION recalculate_performer(p_performer_id bigint)
RETURNS void AS $$
DECLARE
    v_like_counter bigint;
    v_metadata     jsonb;
    v_visited      bigint;
BEGIN
    SELECT like_counter, metadata
    INTO   v_like_counter, v_metadata
    FROM   performer
    WHERE  id = p_performer_id;

    -- visited = total view_counter of all videos this performer appears in
    SELECT COALESCE(SUM(v.view_counter), 0)
    INTO   v_visited
    FROM   video_performer vp
    JOIN   video v ON vp.video = v.id
    WHERE  vp.performer = p_performer_id;

    UPDATE performer
    SET
        tag_keys = COALESCE(
            (SELECT concat('|', string_agg(pt.tag::text, '|'), '|')
             FROM   performer_tag pt
             WHERE  pt.performer = p_performer_id),
            ''
        ),
        tags = COALESCE(
            (SELECT jsonb_agg(jsonb_build_object(
                        'id',   t.id,
                        'name', t.name,
                        'uuid', t.uuid,
                        'slug', t.slug))
             FROM   performer_tag pt
             JOIN   tag t ON pt.tag = t.id
             WHERE  pt.performer = p_performer_id),
            '[]'::jsonb
        ),
        counter = (
            SELECT count(*) FROM video_performer vp WHERE vp.performer = p_performer_id
        ),
        last_upload_at = GREATEST(
            last_upload_at,
            (SELECT MAX(v.created_at)
             FROM   video_performer vp
             JOIN   video v ON vp.video = v.id
             WHERE  vp.performer = p_performer_id)
        ),
        metadata = COALESCE(v_metadata, '{}'::jsonb) || jsonb_build_object(
            'likes',   v_like_counter,
            'visited', v_visited
        )
    WHERE id = p_performer_id;

    -- Recount video uses per tag for every tag on this performer
    UPDATE tag t
    SET    counter = (SELECT count(*) FROM video_tag vt WHERE vt.tag = t.id)
    WHERE  t.id IN (SELECT tag FROM performer_tag WHERE performer = p_performer_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- recalculate_studio(p_studio_id bigint)
--
-- Updates ALL denormalized fields on the studio row.
-- visited   = sum of view_counter across all direct videos for this studio.
-- children  = count of child studios (studio.parent = p_studio_id).
--
-- Supabase RPC: supabase.rpc('recalculate_studio', { p_studio_id: 123 })
-- ============================================================

CREATE OR REPLACE FUNCTION recalculate_studio(p_studio_id bigint)
RETURNS void AS $$
DECLARE
    v_like_counter   bigint;
    v_metadata       jsonb;
    v_visited        bigint;
    v_children_count bigint;
    v_children_data  jsonb;
BEGIN
    SELECT like_counter, metadata
    INTO   v_like_counter, v_metadata
    FROM   studio
    WHERE  id = p_studio_id;

    -- visited = total view_counter of all videos directly under this studio
    SELECT COALESCE(SUM(v.view_counter), 0)
    INTO   v_visited
    FROM   video v
    WHERE  v.studio = p_studio_id;

    -- children count + array of child studio objects
    SELECT
        count(*),
        COALESCE(
            jsonb_agg(jsonb_build_object(
                'id',   s.id,
                'uuid', s.uuid,
                'slug', s.slug,
                'name', s.name
            )),
            '[]'::jsonb
        )
    INTO v_children_count, v_children_data
    FROM studio s
    WHERE s.parent = p_studio_id;

    UPDATE studio
    SET
        tag_keys = COALESCE(
            (SELECT concat('|', string_agg(st.tag::text, '|'), '|')
             FROM   studio_tag st
             WHERE  st.studio = p_studio_id),
            ''
        ),
        tags = COALESCE(
            (SELECT jsonb_agg(jsonb_build_object(
                        'id',   t.id,
                        'name', t.name,
                        'uuid', t.uuid,
                        'slug', t.slug))
             FROM   studio_tag st
             JOIN   tag t ON st.tag = t.id
             WHERE  st.studio = p_studio_id),
            '[]'::jsonb
        ),
        counter  = (SELECT count(*) FROM video WHERE studio = p_studio_id),
        last_upload_at = GREATEST(
            last_upload_at,
            (SELECT MAX(created_at) FROM video WHERE studio = p_studio_id)
        ),
        children = v_children_count,
        metadata = COALESCE(v_metadata, '{}'::jsonb) || jsonb_build_object(
            'likes',        v_like_counter,
            'visited',      v_visited,
            'nro_children', v_children_count,
            'children',     v_children_data
        )
    WHERE id = p_studio_id;

    -- Recount video uses per tag for every tag on this studio
    UPDATE tag t
    SET    counter = (SELECT count(*) FROM video_tag vt WHERE vt.tag = t.id)
    WHERE  t.id IN (SELECT tag FROM studio_tag WHERE studio = p_studio_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

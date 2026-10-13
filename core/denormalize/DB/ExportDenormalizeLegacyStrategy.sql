
CREATE OR REPLACE FUNCTION update_like_counter_after_delete
CREATE OR REPLACE FUNCTION public.update_like_counter_after_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- interaction_id = 1 (user_video_like) → update video.like_counter
    IF OLD.interaction_id = 1 THEN
        UPDATE video
        SET like_counter = (
            SELECT count(*)
            FROM user_interaction
            WHERE interaction_id = 1 AND entity_id = OLD.entity_id
        )
        WHERE video.id = OLD.entity_id;

    -- interaction_id = 4 (user_performer_like) → update performer.like_counter
    ELSIF OLD.interaction_id = 4 THEN
        UPDATE performer
        SET like_counter = (
            SELECT count(*)
            FROM user_interaction
            WHERE interaction_id = 4 AND entity_id = OLD.entity_id
        )
        WHERE performer.id = OLD.entity_id;

    -- interaction_id = 5 (user_studio_like) → update studio.like_counter
    ELSIF OLD.interaction_id = 5 THEN
        UPDATE studio
        SET like_counter = (
            SELECT count(*)
            FROM user_interaction
            WHERE interaction_id = 5 AND entity_id = OLD.entity_id
        )
        WHERE studio.id = OLD.entity_id;
    END IF;

    RETURN OLD;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_like_counter_after_insert
CREATE OR REPLACE FUNCTION public.update_like_counter_after_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- interaction_id = 1 (user_video_like) → update video.like_counter
    IF NEW.interaction_id = 1 THEN
        UPDATE video
        SET like_counter = (
            SELECT count(*)
            FROM user_interaction
            WHERE interaction_id = 1 AND entity_id = NEW.entity_id
        )
        WHERE video.id = NEW.entity_id;

    -- interaction_id = 4 (user_performer_like) → update performer.like_counter
    ELSIF NEW.interaction_id = 4 THEN
        UPDATE performer
        SET like_counter = (
            SELECT count(*)
            FROM user_interaction
            WHERE interaction_id = 4 AND entity_id = NEW.entity_id
        )
        WHERE performer.id = NEW.entity_id;

    -- interaction_id = 5 (user_studio_like) → update studio.like_counter
    ELSIF NEW.interaction_id = 5 THEN
        UPDATE studio
        SET like_counter = (
            SELECT count(*)
            FROM user_interaction
            WHERE interaction_id = 5 AND entity_id = NEW.entity_id
        )
        WHERE studio.id = NEW.entity_id;
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_performer_tags_after_delete
CREATE OR REPLACE FUNCTION public.update_performer_tags_after_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Update the 'tag_keys' field in 'performer'
    UPDATE performer
    SET tag_keys = COALESCE(
        (SELECT concat('|', string_agg(pt.tag::text, '|'::text), '|')
        FROM performer_tag pt
        WHERE pt.performer = OLD.performer),
        ''
    )
    WHERE performer.id = OLD.performer;  -- Perform the update based on the performer id

    RETURN OLD;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_performer_tags_after_insert
CREATE OR REPLACE FUNCTION public.update_performer_tags_after_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Update the 'tag_keys' field in 'performer'
    UPDATE performer
    SET tag_keys = COALESCE(
        (SELECT concat('|', string_agg(pt.tag::text, '|'::text), '|')
        FROM performer_tag pt
        WHERE pt.performer = NEW.performer),
        ''
    )
    WHERE performer.id = NEW.performer;  -- Perform the update based on the performer id

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_studio_counter_after_insert
CREATE OR REPLACE FUNCTION public.update_studio_counter_after_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE studio
    SET counter = (
        SELECT count(v.id)  
        FROM video v INNER JOIN studio s ON v.studio = s.id
        WHERE v.studio = NEW.studio OR s.parent = NEW.studio
    )
    WHERE studio.id = NEW.studio; 

    /* Update last_upload_at in table [studio] */
    UPDATE studio
    SET last_upload_at = now()
    WHERE studio.id = NEW.studio;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_studio_counter_after_video_delete
CREATE OR REPLACE FUNCTION public.update_studio_counter_after_video_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE studio
    SET counter = (
        SELECT count(v.id)  
        FROM video v INNER JOIN studio s ON v.studio = s.id
        WHERE v.studio = OLD.studio OR s.parent = OLD.studio
    )
    WHERE studio.id = OLD.studio; 

    RETURN OLD;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_studio_tag_json_after_studio_tag_delete
CREATE OR REPLACE FUNCTION public.update_studio_tag_json_after_studio_tag_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE studio
    SET tags = COALESCE(
        (
            SELECT json_agg(json_build_object('id', tag.id, 'name', tag.name, 'uuid', tag.uuid))
            FROM studio_tag
            INNER JOIN tag ON studio_tag.tag = tag.id
            WHERE studio_tag.studio = COALESCE(NEW.studio, OLD.studio)
        ),
        '[]'::json
    )
    WHERE studio.id = OLD.studio; 

    RETURN OLD;
END;
$function$
;
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| CREATE OR REPLACE FUNCTION update_studio_tag_json_after_studio_tag_update
CREATE OR REPLACE FUNCTION public.update_studio_tag_json_after_studio_tag_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE studio
    SET tags = COALESCE(
        (
            SELECT json_agg(json_build_object('id', tag.id, 'name', tag.name, 'uuid', tag.uuid))
            FROM studio_tag
            INNER JOIN tag ON studio_tag.tag = tag.id
            WHERE studio_tag.studio = COALESCE(NEW.studio, OLD.studio)
        ),
        '[]'::json
    )
    WHERE studio.id = NEW.studio;  

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_studio_tag_keys_after_delete
CREATE OR REPLACE FUNCTION public.update_studio_tag_keys_after_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Update the 'tag_ids' field in 'studio'
    UPDATE studio
    SET tag_keys = (
        SELECT concat('|',string_agg(st.tag::text, '|'::text), '|')  -- Aggregate tags into an array
        FROM studio_tag st
        WHERE st.studio = OLD.studio  -- Match the studio id
    )
    WHERE studio.id = OLD.studio;  -- Perform the update based on the studio id

    RETURN OLD;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_studio_tag_keys_after_insert
CREATE OR REPLACE FUNCTION public.update_studio_tag_keys_after_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Update the 'tag_ids' field in 'performer'
    UPDATE studio
    SET tag_keys = (
        SELECT concat('|',string_agg(st.tag::text, '|'::text), '|')  -- Aggregate tags into an array
        FROM studio_tag st
        WHERE st.studio = NEW.studio  -- Match the performer id
    )
    WHERE studio.id = NEW.studio;  -- Perform the update based on the performer id

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_video_performer_keys_after_delete
CREATE OR REPLACE FUNCTION public.update_video_performer_keys_after_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Update the 'performer_keys' and 'performers' field in 'video'
    UPDATE video
    SET 
        performer_keys = (
            SELECT concat('|',string_agg(vp.performer::text, '|'::text), '|')
            FROM video_performer vp
            WHERE vp.video = OLD.video  -- Match the performer id
        ),
        performers = COALESCE(
            (SELECT json_agg(json_build_object('id', p.id, 'name', p.name, 'uuid', p.uuid, 'slug', p.slug))
            FROM video_performer vp INNER JOIN performer p ON vp.performer = p.id
            WHERE vp.video = OLD.video),
            '[]'::json
        )
    WHERE video.id = OLD.video;  -- Perform the update based on the performer id

    -- Update the 'counter' field in 'performer'
    UPDATE performer
    SET 
        counter = (
            SELECT count(id)  -- Aggregate tags into an array
            FROM video_performer vp
            WHERE vp.performer = OLD.performer  -- Match the performer id
        )
    WHERE performer.id = OLD.performer; 

    RETURN OLD;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_video_performer_keys_after_insert
CREATE OR REPLACE FUNCTION public.update_video_performer_keys_after_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Update the 'performer_keys' and 'performers' field in 'video'
    UPDATE video
    SET 
        performer_keys = COALESCE(
            (SELECT concat('|', string_agg(vp.performer::text, '|'::text), '|')
            FROM video_performer vp
            WHERE vp.video = NEW.video),
            ''
        ),
        performers = COALESCE(
            (SELECT json_agg(json_build_object('id', p.id, 'name', p.name, 'uuid', p.uuid, 'slug', p.slug))
            FROM video_performer vp INNER JOIN performer p ON vp.performer = p.id
            WHERE vp.video = NEW.video),
            '[]'::json
        )
    WHERE video.id = NEW.video;

    -- Update the 'counter' field in 'performer'
    UPDATE performer
    SET 
        counter = (
            SELECT count(id)  -- Aggregate tags into an array
            FROM video_performer vp
            WHERE vp.performer = NEW.performer  -- Match the performer id
        )
    WHERE performer.id = NEW.performer; 

    -- Update 'last_upload_at' in table 'performer'
    UPDATE performer
    SET last_upload_at = now()
    WHERE performer.id = NEW.performer;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION update_video_tag_keys_and_tags_after_delete
CREATE OR REPLACE FUNCTION public.update_video_tag_keys_and_tags_after_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Update 'tag_keys' and 'tags' fields in 'video'
    UPDATE video
    SET
        tag_keys = COALESCE(
            (SELECT concat('|', string_agg(vt.tag::text, '|'::text), '|')
            FROM video_tag vt
            WHERE vt.video = OLD.video),
            ''
        ),
        tags = COALESCE(
            (SELECT json_agg(json_build_object('id', t.id, 'name', t.name, 'uuid', t.uuid, 'slug', t.slug))
            FROM video_tag vt INNER JOIN tag t ON vt.tag = t.id
            WHERE vt.video = OLD.video),
            '[]'::json
        )
    WHERE video.id = OLD.video;

    -- Update 'counter' field in 'tag'
    UPDATE tag
    SET counter = (
        SELECT count(id)
        FROM video_tag vt
        WHERE vt.tag = OLD.tag
    )
    WHERE tag.id = OLD.tag;

    RETURN OLD;
END;
$function$
;
                                                                                                                                                                                                                                                                                                                                          |
CREATE OR REPLACE FUNCTION update_video_tag_keys_and_tags_after_insert_or_update
CREATE OR REPLACE FUNCTION public.update_video_tag_keys_and_tags_after_insert_or_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE video
    SET
        tag_keys = COALESCE(
            (SELECT concat('|', string_agg(vt.tag::text, '|'::text), '|')
            FROM video_tag vt
            WHERE vt.video = NEW.video),
            ''
        ),
        tags = COALESCE(
            (SELECT json_agg(json_build_object('id', t.id, 'name', t.name, 'uuid', t.uuid, 'slug', t.slug))
            FROM video_tag vt INNER JOIN tag t ON vt.tag = t.id
            WHERE vt.video = NEW.video),
            '[]'::json
        )
    WHERE video.id = NEW.video;

    UPDATE tag
    SET counter = (
        SELECT count(id)
        FROM video_tag vt
        WHERE vt.tag = NEW.tag
    )
    WHERE tag.id = NEW.tag;

    RETURN NEW;
END;
$function$
;
                                                                                                                                                                                                                                                                                                                                                                                                                   |
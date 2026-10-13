-- SQL INSERT / UPDATE

CREATE OR REPLACE FUNCTION update_video_performer_keys_after_insert()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER after_video_performer_performers_key_insert
AFTER INSERT ON video_performer
FOR EACH ROW
EXECUTE FUNCTION update_video_performer_keys_after_insert();

CREATE OR REPLACE TRIGGER after_video_performer_performers_key_update
AFTER UPDATE ON video_performer
FOR EACH ROW
EXECUTE FUNCTION update_video_performer_keys_after_insert();

-- SQL DELETE

CREATE OR REPLACE FUNCTION update_video_performer_keys_after_delete()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER after_video_performer_performers_key_delete
AFTER DELETE ON video_performer
FOR EACH ROW
EXECUTE FUNCTION update_video_performer_keys_after_delete();


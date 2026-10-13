CREATE OR REPLACE FUNCTION update_video_tag_keys_and_tags_after_insert_or_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Update 'tag_keys' and 'tags' fields in 'video'
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

    -- Update 'counter' field in 'tag'
    UPDATE tag
    SET counter = (
        SELECT count(id)
        FROM video_tag vt
        WHERE vt.tag = NEW.tag
    )
    WHERE tag.id = NEW.tag;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER after_video_tag_insert
AFTER INSERT ON video_tag
FOR EACH ROW
EXECUTE FUNCTION update_video_tag_keys_and_tags_after_insert_or_update();

CREATE OR REPLACE TRIGGER after_video_tag_update
AFTER UPDATE ON video_tag
FOR EACH ROW
EXECUTE FUNCTION update_video_tag_keys_and_tags_after_insert_or_update();


CREATE OR REPLACE FUNCTION update_video_tag_keys_and_tags_after_delete()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER after_video_tag_delete
AFTER DELETE ON video_tag
FOR EACH ROW
EXECUTE FUNCTION update_video_tag_keys_and_tags_after_delete();

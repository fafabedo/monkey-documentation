CREATE OR REPLACE FUNCTION update_performer_tags_after_insert()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER after_performer_tag_insert
AFTER INSERT ON performer_tag
FOR EACH ROW
EXECUTE FUNCTION update_performer_tags_after_insert();

CREATE OR REPLACE TRIGGER after_performer_tag_update
AFTER UPDATE ON performer_tag
FOR EACH ROW
EXECUTE FUNCTION update_performer_tags_after_insert();



CREATE OR REPLACE FUNCTION update_performer_tags_after_delete()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER after_performer_tag_delete
AFTER DELETE ON performer_tag
FOR EACH ROW
EXECUTE FUNCTION update_performer_tags_after_delete();
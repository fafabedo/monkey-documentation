-- Trigger function: fires on INSERT into user_interaction
-- Updates like_counter on video, performer, or studio based on interaction_id

CREATE OR REPLACE FUNCTION update_like_counter_after_insert()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;


-- Trigger function: fires on DELETE from user_interaction
-- Recounts like_counter on video, performer, or studio based on interaction_id

CREATE OR REPLACE FUNCTION update_like_counter_after_delete()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER after_user_interaction_like_insert
AFTER INSERT ON user_interaction
FOR EACH ROW
EXECUTE FUNCTION update_like_counter_after_insert();

CREATE OR REPLACE TRIGGER after_user_interaction_like_delete
AFTER DELETE ON user_interaction
FOR EACH ROW
EXECUTE FUNCTION update_like_counter_after_delete();

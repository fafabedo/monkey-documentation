-- Update video.tag_keys and video.tags for all records
UPDATE video
SET
    tag_keys = COALESCE(
        (SELECT concat('|', string_agg(vt.tag::text, '|'::text), '|')
        FROM video_tag vt
        WHERE vt.video = video.id),
        ''
    ),
    tags = COALESCE(
        (SELECT json_agg(json_build_object('id', t.id, 'name', t.name, 'uuid', t.uuid, 'slug', t.slug))
        FROM video_tag vt INNER JOIN tag t ON vt.tag = t.id
        WHERE vt.video = video.id),
        '[]'::json
    );

-- Update tag.counter for all records
UPDATE tag
SET counter = (
    SELECT count(id)
    FROM video_tag vt
    WHERE vt.tag = tag.id
);

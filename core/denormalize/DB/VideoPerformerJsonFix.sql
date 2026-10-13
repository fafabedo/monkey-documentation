
UPDATE video
SET 
    performers = COALESCE(
        (SELECT json_agg(json_build_object('id', p.id, 'name', p.name, 'uuid', p.uuid, 'slug', p.slug))
        FROM video_performer vp INNER JOIN performer p ON vp.performer = p.id
        WHERE vp.video = video.id),
        '[]'::json
    )
WHERE video.id > 0;



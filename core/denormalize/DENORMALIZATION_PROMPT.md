# Denormalization Strategy — Shared DB Context

This document describes the pre-computed / cached-aggregate field strategy used across all apps
sharing this database. Implement these patterns in any Node.js or React (server-side) app that
writes to the same Supabase instance.

---

## Why this exists

Several tables carry **denormalized fields** — values that could be derived from related tables
but are stored directly to avoid expensive JOIN queries on every read. These fields must be kept
in sync whenever their source data changes.

The strategy uses **three PostgreSQL functions** that can be called manually (via Supabase RPC)
instead of relying solely on row-level triggers (which suffer from race conditions when multiple
rows are inserted concurrently).

---

## Entities and their denormalized fields

### `video`
| Field | Type | Source |
|---|---|---|
| `performer_keys` | text | `\|id1\|id2\|id3\|` — pipe-wrapped IDs from `video_performer` |
| `tag_keys` | text | `\|id1\|id2\|id3\|` — pipe-wrapped IDs from `video_tag` |
| `performers` | jsonb | `[{id, name, uuid, slug}]` from `video_performer → performer` |
| `tags` | jsonb | `[{id, name, uuid, slug}]` from `video_tag → tag` |
| `metadata.likes` | int | `video.like_counter` |
| `metadata.views` | int | `video.view_counter` |
| `metadata.visits` | int | mirrors `view_counter` (no separate interaction yet) |
| `metadata.plays` | int | mirrors `view_counter` (no separate interaction yet) |
| `metadata.video_height` | int | best `video_resource.height` where `resource_type = 'full'` |
| `metadata.video_duration` | text | best `video_resource.duration` where `resource_type = 'full'` |

### `performer`
| Field | Type | Source |
|---|---|---|
| `tag_keys` | text | `\|id1\|id2\|id3\|` from `performer_tag` |
| `tags` | jsonb | `[{id, name, uuid, slug}]` from `performer_tag → tag` |
| `counter` | bigint | count of `video_performer` rows for this performer |
| `last_upload_at` | timestamp | MAX of `video.created_at` across the performer's videos (monotonic — never regresses) |
| `metadata.likes` | int | `performer.like_counter` |
| `metadata.visited` | int | SUM of `video.view_counter` for all videos this performer appears in |

### `studio`
| Field | Type | Source |
|---|---|---|
| `tag_keys` | text | `\|id1\|id2\|id3\|` from `studio_tag` |
| `tags` | jsonb | `[{id, name, uuid, slug}]` from `studio_tag → tag` |
| `counter` | bigint | count of `video` rows where `studio = studio.id` |
| `last_upload_at` | timestamp | MAX of `video.created_at` for direct videos (monotonic — never regresses; backfill also rolls child-studio uploads up to parents) |
| `children` | bigint | count of `studio` rows where `parent = studio.id` |
| `metadata.likes` | int | `studio.like_counter` |
| `metadata.visited` | int | SUM of `video.view_counter` for all direct videos in this studio |
| `metadata.nro_children` | int | same value as `studio.children` |
| `metadata.children` | jsonb | `[{id, uuid, slug, name}]` of child studios |

### `tag`
| Field | Type | Source |
|---|---|---|
| `counter` | bigint | count of `video_tag` rows for this tag |

---

## Interaction types (table: `interaction`)

| id | label_id | description |
|---|---|---|
| 1 | `user_video_like` | User liked a video |
| 2 | `user_video_view` | User viewed a video |
| 3 | `user_video_watch_list` | User added video to watchlist |
| 4 | `user_performer_like` | User liked a performer |
| 5 | `user_studio_like` | User liked a studio |

Interactions are stored in `user_interaction (user, interaction_id, entity_id)`.
Like counters (`like_counter`) are maintained by DB triggers on `user_interaction`.
View counters (`view_counter`) are maintained by application code.

---

## The three recalculate functions (PostgreSQL)

Deploy these to Supabase via the SQL editor or `psql`. They are idempotent — safe to run
multiple times.

```sql
-- ============================================================
-- recalculate_video(p_video_id bigint)
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
    FROM   video WHERE id = p_video_id;

    SELECT height, duration
    INTO   v_best_height, v_best_duration
    FROM   video_resource
    WHERE  video_id = p_video_id AND resource_type = 'full'
    ORDER  BY height DESC NULLS LAST LIMIT 1;

    UPDATE video SET
        performer_keys = COALESCE(
            (SELECT concat('|', string_agg(vp.performer::text, '|'), '|')
             FROM video_performer vp WHERE vp.video = p_video_id), ''
        ),
        tag_keys = COALESCE(
            (SELECT concat('|', string_agg(vt.tag::text, '|'), '|')
             FROM video_tag vt WHERE vt.video = p_video_id), ''
        ),
        performers = COALESCE(
            (SELECT json_agg(json_build_object('id', p.id, 'name', p.name, 'uuid', p.uuid, 'slug', p.slug))
             FROM video_performer vp JOIN performer p ON vp.performer = p.id
             WHERE vp.video = p_video_id), '[]'::json
        ),
        tags = COALESCE(
            (SELECT json_agg(json_build_object('id', t.id, 'name', t.name, 'uuid', t.uuid, 'slug', t.slug))
             FROM video_tag vt JOIN tag t ON vt.tag = t.id
             WHERE vt.video = p_video_id), '[]'::json
        ),
        metadata = (
            COALESCE(v_metadata::jsonb, '{}'::jsonb) || jsonb_build_object(
                'likes', v_like_counter, 'views', v_view_counter,
                'visits', v_view_counter, 'plays', v_view_counter,
                'video_height', v_best_height, 'video_duration', v_best_duration
            )
        )::json
    WHERE id = p_video_id;

    -- tag.counter for all tags on this video
    UPDATE tag t SET counter = (SELECT count(*) FROM video_tag vt WHERE vt.tag = t.id)
    WHERE t.id IN (SELECT tag FROM video_tag WHERE video = p_video_id);

    -- performer.counter for all performers on this video
    UPDATE performer p
    SET counter = (SELECT count(*) FROM video_performer vp2 WHERE vp2.performer = p.id)
    WHERE p.id IN (SELECT vp.performer FROM video_performer vp WHERE vp.video = p_video_id);

    -- studio.counter (direct + parent)
    IF v_studio_id IS NOT NULL THEN
        UPDATE studio SET counter = (SELECT count(*) FROM video WHERE studio = v_studio_id)
        WHERE id = v_studio_id;
        SELECT parent INTO v_studio_parent FROM studio WHERE id = v_studio_id;
        IF v_studio_parent IS NOT NULL THEN
            UPDATE studio SET counter = (SELECT count(*) FROM video WHERE studio = v_studio_parent)
            WHERE id = v_studio_parent;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- recalculate_performer(p_performer_id bigint)
-- ============================================================
CREATE OR REPLACE FUNCTION recalculate_performer(p_performer_id bigint)
RETURNS void AS $$
DECLARE
    v_like_counter bigint;
    v_metadata     jsonb;
    v_visited      bigint;
BEGIN
    SELECT like_counter, metadata INTO v_like_counter, v_metadata
    FROM performer WHERE id = p_performer_id;

    SELECT COALESCE(SUM(v.view_counter), 0) INTO v_visited
    FROM video_performer vp JOIN video v ON vp.video = v.id
    WHERE vp.performer = p_performer_id;

    UPDATE performer SET
        tag_keys = COALESCE(
            (SELECT concat('|', string_agg(pt.tag::text, '|'), '|')
             FROM performer_tag pt WHERE pt.performer = p_performer_id), ''
        ),
        tags = COALESCE(
            (SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'uuid', t.uuid, 'slug', t.slug))
             FROM performer_tag pt JOIN tag t ON pt.tag = t.id
             WHERE pt.performer = p_performer_id), '[]'::jsonb
        ),
        counter = (SELECT count(*) FROM video_performer vp WHERE vp.performer = p_performer_id),
        metadata = COALESCE(v_metadata, '{}'::jsonb) || jsonb_build_object(
            'likes', v_like_counter, 'visited', v_visited
        )
    WHERE id = p_performer_id;

    -- tag.counter for all tags on this performer
    UPDATE tag t SET counter = (SELECT count(*) FROM video_tag vt WHERE vt.tag = t.id)
    WHERE t.id IN (SELECT tag FROM performer_tag WHERE performer = p_performer_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- recalculate_studio(p_studio_id bigint)
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
    SELECT like_counter, metadata INTO v_like_counter, v_metadata
    FROM studio WHERE id = p_studio_id;

    SELECT COALESCE(SUM(v.view_counter), 0) INTO v_visited
    FROM video v WHERE v.studio = p_studio_id;

    SELECT count(*),
        COALESCE(jsonb_agg(jsonb_build_object('id', s.id, 'uuid', s.uuid, 'slug', s.slug, 'name', s.name)), '[]'::jsonb)
    INTO v_children_count, v_children_data
    FROM studio s WHERE s.parent = p_studio_id;

    UPDATE studio SET
        tag_keys = COALESCE(
            (SELECT concat('|', string_agg(st.tag::text, '|'), '|')
             FROM studio_tag st WHERE st.studio = p_studio_id), ''
        ),
        tags = COALESCE(
            (SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'uuid', t.uuid, 'slug', t.slug))
             FROM studio_tag st JOIN tag t ON st.tag = t.id
             WHERE st.studio = p_studio_id), '[]'::jsonb
        ),
        counter  = (SELECT count(*) FROM video WHERE studio = p_studio_id),
        children = v_children_count,
        metadata = COALESCE(v_metadata, '{}'::jsonb) || jsonb_build_object(
            'likes', v_like_counter, 'visited', v_visited,
            'nro_children', v_children_count, 'children', v_children_data
        )
    WHERE id = p_studio_id;

    -- tag.counter for all tags on this studio
    UPDATE tag t SET counter = (SELECT count(*) FROM video_tag vt WHERE vt.tag = t.id)
    WHERE t.id IN (SELECT tag FROM studio_tag WHERE studio = p_studio_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Calling the functions from JavaScript (Supabase RPC)

All three functions are exposed as Supabase RPC endpoints. Use the **service role client** —
these functions write to multiple tables and must bypass RLS.

```js
// Supabase client with service role key
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

// Recalculate a video and all its related entities (performers, studio, tags)
await supabase.rpc('recalculate_video', { p_video_id: 123 });

// Recalculate a performer (tags, counter, metadata)
await supabase.rpc('recalculate_performer', { p_performer_id: 456 });

// Recalculate a studio (tags, counter, children, metadata)
await supabase.rpc('recalculate_studio', { p_studio_id: 789 });
```

Always pass integer IDs (not UUIDs). If your app stores UUIDs, resolve to the integer PK first.

---

## When to call each function

Use **fire-and-forget** (non-blocking) so the user-facing response is not slowed down.
Log errors to the console so failures are visible in server logs.

```js
supabase.rpc('recalculate_video', { p_video_id: id }).catch(console.error);
```

### Video events
| Event | Call |
|---|---|
| Video created or updated (any field) | `recalculate_video` + `recalculate_studio` (video's studio) + `recalculate_performer` for each performer |
| User views a video (first view only) | `recalculate_video` |
| User likes / unlikes a video | `recalculate_video` |

### Performer events
| Event | Call |
|---|---|
| Performer created or updated | `recalculate_performer` |
| Performer deleted | `recalculate_video` for every video the performer appeared in |
| User likes / unlikes a performer | `recalculate_performer` |

### Studio events
| Event | Call |
|---|---|
| Studio created or updated | `recalculate_studio` |
| User likes / unlikes a studio | `recalculate_studio` |

---

## Node.js pattern (plain `pg` or `postgres` client)

```js
// Using the `postgres` (sql template tag) or `pg` library directly
await sql`SELECT recalculate_video(${videoId})`;
await sql`SELECT recalculate_performer(${performerId})`;
await sql`SELECT recalculate_studio(${studioId})`;
```

Or wrap in a reusable helper:

```js
async function recalculate(entity, id) {
    const fn = {
        video:     'recalculate_video',
        performer: 'recalculate_performer',
        studio:    'recalculate_studio',
    }[entity];
    if (!fn) throw new Error(`Unknown entity: ${entity}`);
    const param = { video: 'p_video_id', performer: 'p_performer_id', studio: 'p_studio_id' }[entity];
    await supabase.rpc(fn, { [param]: Number(id) });
}

// Usage
recalculate('video', videoId).catch(console.error);
recalculate('performer', performerId).catch(console.error);
recalculate('studio', studioId).catch(console.error);
```

---

## Important notes

1. **`recalculate_video` already cascades** — it updates `performer.counter`, `studio.counter`,
   and `tag.counter` for all entities touched by the video. You do NOT need to separately call
   `recalculate_performer` and `recalculate_studio` after a video save unless you also want to
   refresh their `tags`, `tag_keys`, and `metadata` (recommended on full saves).

2. **Metadata is merged, not replaced** — the functions use `||` (jsonb merge) so any existing
   metadata keys not managed by recalculate are preserved.

3. **`tag.counter` counts `video_tag` rows only** — it reflects how many videos use a tag,
   not performer or studio tag usage.

4. **`visits` and `plays` on `video.metadata`** currently mirror `view_counter`. When separate
   interaction types are added for plays and visits, update the function accordingly.

5. **Existing triggers** handle `like_counter` updates on `user_interaction` insert/delete.
   The recalculate functions read the already-updated `like_counter` value — do not call them
   before the trigger has committed.

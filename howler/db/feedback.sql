-- Feedback submissions
-- Inserts happen only from the Next.js API route using the service-role key,
-- so RLS is enabled with no public policies (anon/authenticated roles can't touch it).
--
-- Run once before deploying. Safe to re-run (all statements use IF NOT EXISTS).

CREATE TABLE IF NOT EXISTS public.feedback (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at   timestamptz NOT NULL DEFAULT now(),

    type         text        NOT NULL
                     CHECK (type IN ('question', 'issue', 'idea', 'other')),
    message      text        NOT NULL
                     CHECK (char_length(message) BETWEEN 10 AND 4000),
    status       text        NOT NULL DEFAULT 'new'
                     CHECK (status IN ('new', 'in_progress', 'answered', 'closed')),

    -- who sent it
    user_id      text,           -- NextAuth user id when logged in, null for visitors
    email        text        NOT NULL,
    is_anonymous boolean     NOT NULL DEFAULT false,

    -- context
    roles        text,           -- e.g. ROLE_SUBSCRIBER, PLAN_EDITOR_MONTHLY
    page_url     text,           -- truncated to 500 chars by the API route
    user_agent   text,           -- truncated to 300 chars by the API route

    -- abuse control — raw IP is never stored
    ip_hash      text            -- salted SHA-256 of client IP
);

-- Indexes
CREATE INDEX IF NOT EXISTS feedback_created_idx
    ON public.feedback (created_at DESC);

CREATE INDEX IF NOT EXISTS feedback_status_idx
    ON public.feedback (status);

-- Covers the hourly rate-limit count query:
--   WHERE ip_hash = $1 AND created_at >= $2
CREATE INDEX IF NOT EXISTS feedback_ratelimit_idx
    ON public.feedback (ip_hash, created_at DESC);

-- RLS: enabled, no policies — only the service-role key can write
ALTER TABLE public.feedback ENABLE ROW LEVEL SECURITY;

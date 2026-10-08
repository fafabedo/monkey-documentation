# Task: Implement a simple feedback / support form in Monkey Library

You are working in the Monkey Library codebase (`monkeylibrary.app`, authenticated app at `my.monkeylibrary.app`). Implement the feature described below. Read the codebase first, then adapt the reference implementation at the end of this document to the project's real conventions. Do not copy it blindly.

## Context

- Product: metadata-only multi-tenant SaaS for media library management, operated by Tech Bedoya Inc. (Quebec, Canada). Quebec Law 25 and PIPEDA apply.
- Stack: Next.js (Pages Router), Supabase (Postgres + auth), NextAuth.js, Brevo (transactional email), Cloudflare Turnstile (bot protection). Deployed with Coolify on a Hetzner VPS.
- Roles: ROLE_GUEST, ROLE_SUBSCRIBER, PLAN_EDITOR_MONTHLY, ROLE_ADMIN, ROLE_SUPER_ADMIN.
- Budget: none for this feature. No paid services, no AI chat, no third-party chat widgets. Use only the stack above.

## Goal

Give users an easy way to send questions, issue reports, and ideas.

- **Logged-in user:** the form shows "Sending as <email>". They only choose a type and write a message. Email, user ID, roles, and page URL are attached automatically and are never editable client-side.
- **Visitor (not logged in):** they also enter an email so we can reply, and must pass Cloudflare Turnstile.
- Every submission is stored in Supabase and emailed to the admin through Brevo, with reply-to set to the sender so replying answers the user directly.

## Functional requirements

1. Message types: `question`, `issue`, `idea`, `other`.
2. Message length: 10 to 4000 characters, validated on both client and server.
3. Server derives identity from the NextAuth session (`getServerSession`). Never trust email, user ID, or roles sent from the client for logged-in users.
4. Visitors: valid email required, Turnstile token verified server-side against `https://challenges.cloudflare.com/turnstile/v0/siteverify`.
5. Abuse control:
   - Hidden honeypot field (`website`). If filled, return `200 { ok: true }` without saving.
   - Rate limit: max 5 submissions per hour per hashed IP. Return 429 with a clear message.
   - Store only a salted SHA-256 hash of the IP, never the raw IP.
6. Persistence: insert into a `public.feedback` table using the Supabase service role key, server-side only. RLS enabled with no public policies.
7. Notification: send an email through the Brevo transactional API (`POST https://api.brevo.com/v3/smtp/email`) to `FEEDBACK_NOTIFY_EMAIL`. HTML-escape all user content. Email failure must NOT fail the request (the row is already saved); log it.
8. Context captured: type, message, email, user_id (nullable), roles (nullable), page_url, user_agent, is_anonymous, ip_hash, status (`new` | `in_progress` | `answered` | `closed`, default `new`).
9. UI states: idle, sending (button disabled, "Sending…"), success (confirmation naming the email we'll reply to), error (inline, `role="alert"`, explains what to fix). On error, reset Turnstile for visitors.
10. Accessibility: labelled fields, visible focus, keyboard usable, honeypot hidden from assistive tech (`aria-hidden`, `tabIndex={-1}`).
11. Copy: plain, sentence case, active voice. Button says "Send message". Errors say what went wrong and how to fix it, with no apologies.

## Non-functional requirements and constraints

- No new dependencies beyond what the project already has (`@supabase/supabase-js`, `next-auth`). Load Turnstile via its script tag with explicit rendering.
- The service role key and Brevo key must never reach the client bundle. Only `NEXT_PUBLIC_TURNSTILE_SITE_KEY` is public.
- Match the project's existing styling approach (Tailwind, CSS modules, etc.). The reference component is intentionally unstyled with hook class names (`feedback-form`, `feedback-from`, `feedback-error`, `feedback-sent`).
- Match the project's existing patterns for API route error handling, logging, TypeScript config, path aliases, and Supabase client setup. Reuse an existing server-side Supabase admin client if one exists instead of creating a new one.
- Law 25: do not store raw IPs, and do not log message bodies or emails to application logs.

## Integration points to find and adapt

- Where `authOptions` is exported (the reference imports from `@/pages/api/auth/[...nextauth]`).
- How the NextAuth session exposes user ID and roles (reference assumes `session.user.id` and `session.user.roles` as a string or string array). Adjust the types, ideally by using the project's existing session type augmentation.
- Where to mount the form: a `/help` (or `/feedback`) page, plus a "Send feedback" link in the app header or footer, and on the public marketing site if the same Next app serves it. A modal is optional.
- Whether the project already has a Brevo helper. If so, reuse it instead of the inline `fetch`.

## Environment variables to add (and document in `.env.example`)

```
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
TURNSTILE_SECRET_KEY=
NEXT_PUBLIC_TURNSTILE_SITE_KEY=
BREVO_API_KEY=
FEEDBACK_FROM_EMAIL=      # must be a verified Brevo sender
FEEDBACK_NOTIFY_EMAIL=    # where new feedback is sent
FEEDBACK_IP_SALT=         # any long random string
```

If the project already defines some of these under different names, reuse the existing names.

## Deliverables

1. SQL migration for the `feedback` table, in the project's migrations location if there is one.
2. API route `POST /api/feedback`.
3. `FeedbackForm` component and the page(s) and link(s) that mount it.
4. `.env.example` updates.
5. A short summary of what you changed, the assumptions you made, and anything I need to do manually (create the Brevo sender, set env vars in Coolify, run the migration).

## Acceptance criteria

- Logged-in submission: no email field shown, row saved with `user_id`, email, and roles from the session, admin email received with working reply-to.
- Visitor submission: email required, Turnstile required, row saved with `is_anonymous = true`.
- Honeypot filled: `200`, nothing saved, nothing emailed.
- Sixth submission within an hour from the same IP returns 429.
- Brevo outage: submission still succeeds and is saved.
- Tampering with the request body (fake email or user ID while logged in) has no effect on stored identity.
- The build passes type-check and lint.

## Out of scope for now (do not build unless asked)

- Screenshot upload (future: private Supabase Storage bucket plus a `screenshot_path` column).
- Admin triage page for `ROLE_ADMIN` (for now, triage in the Supabase dashboard by `status`).
- Public roadmap or voting board, chat, or AI features.

---

# Reference implementation

Treat these as a working starting point. Adapt imports, types, and styling to the project.

## 1. `feedback-schema.sql`

```sql
-- Feedback submissions for Monkey Library
-- Inserts happen only from the Next.js API route using the service role key,
-- so RLS is enabled with no public policies (anon/authenticated can't touch it).

create table if not exists public.feedback (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),

  type          text not null check (type in ('question', 'issue', 'idea', 'other')),
  message       text not null check (char_length(message) between 10 and 4000),
  status        text not null default 'new' check (status in ('new', 'in_progress', 'answered', 'closed')),

  -- who sent it
  user_id       text,            -- NextAuth user id when logged in, null for visitors
  email         text not null,   -- from session when logged in, typed in otherwise
  is_anonymous  boolean not null default false,

  -- context (only filled when logged in, except page_url / user_agent)
  roles         text,            -- e.g. ROLE_SUBSCRIBER, PLAN_EDITOR_MONTHLY
  page_url      text,
  user_agent    text,

  -- abuse control (hashed so we don't store raw IPs)
  ip_hash       text
);

create index if not exists feedback_created_idx on public.feedback (created_at desc);
create index if not exists feedback_status_idx  on public.feedback (status);
create index if not exists feedback_ratelimit_idx on public.feedback (ip_hash, created_at desc);

alter table public.feedback enable row level security;
-- No policies on purpose. Service role bypasses RLS.
```

## 2. `pages/api/feedback.ts`

```ts
import type { NextApiRequest, NextApiResponse } from "next";
import { getServerSession } from "next-auth/next";
import { createClient } from "@supabase/supabase-js";
import crypto from "crypto";
// Adjust this import to wherever your NextAuth options live.
import { authOptions } from "@/pages/api/auth/[...nextauth]";

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { persistSession: false } }
);

const TYPES = ["question", "issue", "idea", "other"] as const;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_PER_HOUR = 5;

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function clientIp(req: NextApiRequest): string {
  const fwd = req.headers["x-forwarded-for"];
  const first = Array.isArray(fwd) ? fwd[0] : fwd?.split(",")[0];
  return (first || req.socket.remoteAddress || "").trim();
}

async function verifyTurnstile(token: string | undefined, ip: string) {
  if (!token) return false;
  const body = new URLSearchParams({
    secret: process.env.TURNSTILE_SECRET_KEY!,
    response: token,
    remoteip: ip,
  });
  const res = await fetch(
    "https://challenges.cloudflare.com/turnstile/v0/siteverify",
    { method: "POST", body }
  );
  const data = await res.json();
  return data.success === true;
}

async function notifyByEmail(row: {
  type: string;
  message: string;
  email: string;
  roles: string | null;
  page_url: string | null;
  is_anonymous: boolean;
}) {
  const res = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: {
      "api-key": process.env.BREVO_API_KEY!,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      sender: { email: process.env.FEEDBACK_FROM_EMAIL! },
      to: [{ email: process.env.FEEDBACK_NOTIFY_EMAIL! }],
      replyTo: { email: row.email },
      subject: `[Monkey Library] ${row.type}: ${row.message.slice(0, 60)}`,
      htmlContent: `
        <p><b>Type:</b> ${esc(row.type)}</p>
        <p><b>From:</b> ${esc(row.email)} ${row.is_anonymous ? "(visitor)" : "(logged in)"}</p>
        ${row.roles ? `<p><b>Roles:</b> ${esc(row.roles)}</p>` : ""}
        ${row.page_url ? `<p><b>Page:</b> ${esc(row.page_url)}</p>` : ""}
        <hr/>
        <p style="white-space:pre-wrap">${esc(row.message)}</p>`,
    }),
  });
  if (!res.ok) console.error("Brevo notify failed", res.status, await res.text());
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed" });
  }

  const { type, message, email, pageUrl, website, turnstileToken } = req.body ?? {};

  if (website) return res.status(200).json({ ok: true });

  if (!TYPES.includes(type)) return res.status(400).json({ error: "Choose a type." });
  const text = typeof message === "string" ? message.trim() : "";
  if (text.length < 10 || text.length > 4000)
    return res.status(400).json({ error: "Message must be 10 to 4000 characters." });

  const ip = clientIp(req);
  const session = await getServerSession(req, res, authOptions);
  const user = session?.user as
    | { id?: string; email?: string | null; roles?: string[] | string }
    | undefined;

  let senderEmail: string;
  let userId: string | null = null;
  let roles: string | null = null;
  const isAnonymous = !user?.email;

  if (user?.email) {
    senderEmail = user.email;
    userId = user.id ?? null;
    roles = Array.isArray(user.roles) ? user.roles.join(", ") : user.roles ?? null;
  } else {
    if (typeof email !== "string" || !EMAIL_RE.test(email.trim()))
      return res.status(400).json({ error: "Enter a valid email so we can reply." });
    senderEmail = email.trim().toLowerCase();
    if (!(await verifyTurnstile(turnstileToken, ip)))
      return res.status(400).json({ error: "Bot check failed. Please try again." });
  }

  const ipHash = crypto
    .createHash("sha256")
    .update(ip + (process.env.FEEDBACK_IP_SALT ?? ""))
    .digest("hex");
  const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count } = await supabase
    .from("feedback")
    .select("id", { count: "exact", head: true })
    .eq("ip_hash", ipHash)
    .gte("created_at", since);
  if ((count ?? 0) >= MAX_PER_HOUR)
    return res.status(429).json({ error: "Too many messages. Try again in an hour." });

  const row = {
    type,
    message: text,
    user_id: userId,
    email: senderEmail,
    is_anonymous: isAnonymous,
    roles,
    page_url: typeof pageUrl === "string" ? pageUrl.slice(0, 500) : null,
    user_agent: (req.headers["user-agent"] ?? "").slice(0, 300),
    ip_hash: ipHash,
  };

  const { error } = await supabase.from("feedback").insert(row);
  if (error) {
    console.error("feedback insert failed", error);
    return res.status(500).json({ error: "Could not save your message. Please try again." });
  }

  notifyByEmail(row).catch((e) => console.error("notify error", e));

  return res.status(200).json({ ok: true });
}
```

## 3. `components/FeedbackForm.tsx`

```tsx
import { useEffect, useRef, useState } from "react";
import { useSession } from "next-auth/react";

declare global {
  interface Window {
    turnstile?: {
      render: (el: HTMLElement, opts: Record<string, unknown>) => string;
      reset: (id?: string) => void;
    };
  }
}

const TYPES = [
  { value: "question", label: "I have a question" },
  { value: "issue", label: "Something isn't working" },
  { value: "idea", label: "I have an idea" },
  { value: "other", label: "Something else" },
];

function loadTurnstile(): Promise<void> {
  return new Promise((resolve) => {
    if (window.turnstile) return resolve();
    const existing = document.getElementById("cf-turnstile-script");
    if (existing) return existing.addEventListener("load", () => resolve());
    const s = document.createElement("script");
    s.id = "cf-turnstile-script";
    s.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
    s.async = true;
    s.onload = () => resolve();
    document.head.appendChild(s);
  });
}

export default function FeedbackForm() {
  const { data: session, status } = useSession();
  const loggedIn = status === "authenticated" && !!session?.user?.email;

  const [type, setType] = useState("question");
  const [message, setMessage] = useState("");
  const [email, setEmail] = useState("");
  const [website, setWebsite] = useState("");
  const [token, setToken] = useState("");
  const [state, setState] = useState<"idle" | "sending" | "sent">("idle");
  const [error, setError] = useState("");

  const tsRef = useRef<HTMLDivElement>(null);
  const tsId = useRef<string>();

  useEffect(() => {
    if (status === "loading" || loggedIn || !tsRef.current) return;
    let cancelled = false;
    loadTurnstile().then(() => {
      if (cancelled || !tsRef.current || !window.turnstile || tsId.current) return;
      tsId.current = window.turnstile.render(tsRef.current, {
        sitekey: process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY,
        callback: (t: string) => setToken(t),
        "expired-callback": () => setToken(""),
      });
    });
    return () => { cancelled = true; };
  }, [status, loggedIn]);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    setState("sending");
    try {
      const res = await fetch("/api/feedback", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          type,
          message,
          email: loggedIn ? undefined : email,
          pageUrl: window.location.href,
          website,
          turnstileToken: token,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || "Something went wrong.");
      setState("sent");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong.");
      setState("idle");
      if (!loggedIn && window.turnstile) {
        window.turnstile.reset(tsId.current);
        setToken("");
      }
    }
  }

  if (state === "sent") {
    return (
      <div role="status" className="feedback-sent">
        <p>Message sent. We'll reply to {loggedIn ? session!.user!.email : email}.</p>
      </div>
    );
  }

  const canSend =
    state !== "sending" &&
    message.trim().length >= 10 &&
    (loggedIn || (email.includes("@") && token));

  return (
    <form onSubmit={onSubmit} className="feedback-form" noValidate>
      <label>
        What's this about?
        <select value={type} onChange={(e) => setType(e.target.value)}>
          {TYPES.map((t) => (
            <option key={t.value} value={t.value}>{t.label}</option>
          ))}
        </select>
      </label>

      {loggedIn ? (
        <p className="feedback-from">
          Sending as <strong>{session!.user!.email}</strong>
        </p>
      ) : (
        <label>
          Your email (so we can reply)
          <input
            type="email"
            required
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>
      )}

      <label>
        Message
        <textarea
          required
          rows={6}
          maxLength={4000}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="Tell us what happened or what you need."
        />
      </label>

      <div aria-hidden="true" style={{ position: "absolute", left: "-9999px" }}>
        <label>
          Website
          <input
            type="text"
            tabIndex={-1}
            autoComplete="off"
            value={website}
            onChange={(e) => setWebsite(e.target.value)}
          />
        </label>
      </div>

      {!loggedIn && <div ref={tsRef} />}

      {error && (
        <p role="alert" className="feedback-error">{error}</p>
      )}

      <button type="submit" disabled={!canSend}>
        {state === "sending" ? "Sending…" : "Send message"}
      </button>
    </form>
  );
}
```

## 4. Mounting example (`pages/help.tsx`)

```tsx
import FeedbackForm from "@/components/FeedbackForm";

export default function HelpPage() {
  return (
    <main>
      <h1>Contact us</h1>
      <p>Questions, problems, or ideas. We read every message and reply by email.</p>
      <FeedbackForm />
    </main>
  );
}
```

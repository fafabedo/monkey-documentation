# Howler — Feedback & Support Form Module

Howler is a self-contained, app-agnostic feedback form system for Next.js + Supabase + NextAuth applications. It provides a React component, a server-side handler factory, a mailer, and supporting utilities. Every piece is injectable so it can be wired into any project without modification.

---

## Capabilities

| Feature | Detail |
|---------|--------|
| Message types | `question`, `issue`, `idea`, `other` (configurable) |
| Auth-aware | Logged-in users skip the email field; identity comes only from the server session |
| Visitor support | Email field + Cloudflare Turnstile bot check |
| Spam protection | Hidden honeypot field; fake submissions silently discard |
| Rate limiting | Max 5 submissions per hour per hashed IP (configurable) |
| Privacy | Raw IP is never stored — salted SHA-256 hash only (Law 25 / PIPEDA) |
| Persistence | Inserts into `public.feedback` via Supabase service-role key (bypasses RLS) |
| Email notification | Nodemailer + Brevo SMTP; reply-to set to sender; failure does NOT fail the request |
| Accessibility | Labelled fields, visible focus, `role="alert"` errors, honeypot hidden from AT |
| Modular | Handler is a factory (`createFeedbackHandler`); inject session, identity, and Supabase client |

---

## File layout

```
howler/
├── API/
│   └── Feedback/
│       ├── Mailer.js       Nodemailer + Brevo SMTP singleton
│       └── Submit.js       createFeedbackHandler() factory
├── Components/
│   └── FeedbackForm.js     React component
├── Misc/
│   ├── constants.js        Shared enums + limits
│   └── turnstile.js        Turnstile script loader + server verifier
└── Styles/
    └── _feedback.scss      BEM-style SCSS (double-dash naming)
```

The app-specific API route lives outside howler:

```
src/pages/api/feedback.js   Adapter that wires howler into this app
```

---

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `NEXT_PUBLIC_SUPABASE_URL` | yes | Supabase project URL (already in project) |
| `SUPABASE_SERVICE_ROLE_KEY` | yes | Service role key — server only (already in project) |
| `BREVO_SMTP_HOST` | yes | Brevo SMTP host (already in project) |
| `BREVO_SMTP_PORT` | yes | Brevo SMTP port (already in project) |
| `BREVO_SMTP_USER` | yes | Brevo SMTP user (already in project) |
| `BREVO_SMTP_PASS` | yes | Brevo SMTP password (already in project) |
| `BREVO_FROM_EMAIL` | yes | Verified Brevo sender email (already in project) |
| `BREVO_FROM_NAME` | yes | Display name in outgoing emails (already in project) |
| `FEEDBACK_NOTIFY_EMAIL` | yes | Admin destination for notification emails |
| `FEEDBACK_IP_SALT` | yes | Long random string used in IP hashing |
| `TURNSTILE_SECRET_KEY` | yes (visitors) | Cloudflare Turnstile secret — server only |
| `NEXT_PUBLIC_TURNSTILE_SITE_KEY` | yes (visitors) | Cloudflare Turnstile site key — client-safe |

Variables already defined by this project are reused verbatim. No new dependencies are introduced beyond what the project already has.

---

## Database setup

Run the migration once, before deploying:

```
docs/howler/db/feedback.sql
```

This creates `public.feedback` with RLS enabled and no public policies (only the service-role key can write to it).

---

## Using FeedbackForm

### Minimal

```jsx
import FeedbackForm from '@vx-howler/Components/FeedbackForm';

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

The component reads `NEXT_PUBLIC_TURNSTILE_SITE_KEY` automatically. It uses `useSession` to detect the auth state.

### Inside a modal

```jsx
<FeedbackForm
    onSuccess={() => setModalOpen(false)}
/>
```

### All props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `apiEndpoint` | string | `'/api/feedback'` | POST route |
| `turnstileSiteKey` | string | `process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY` | Override Turnstile site key |
| `types` | `Array<{value, label}>` | `FEEDBACK_TYPES` | Override message type options |
| `className` | string | `''` | Extra CSS class on the outer element |
| `onSuccess` | function | — | Called after a successful submission |
| `successEmail` | string | session or typed email | Override the email shown in the success message |

### UI states

| State | What the user sees |
|-------|--------------------|
| `idle` | Full form |
| `sending` | Button disabled, shows "Sending…" |
| `sent` | Success panel with `role="status"` |
| error | Inline error with `role="alert"`, form stays visible |

---

## Wiring into a new app

1. **Install the submodule** (or copy the `howler/` directory).

2. **Add the path alias** to `jsconfig.json` (or `tsconfig.json`):
   ```json
   "@vx-howler/*": ["./howler/*"]
   ```

3. **Create the API route adapter** at `src/pages/api/feedback.js`:

   ```js
   import { createClient } from '@supabase/supabase-js';
   import { getServerSession } from 'next-auth/next';
   import { authOptions } from '@/pages/api/auth/[...nextauth]';
   import { createFeedbackHandler } from '@vx-howler/API/Feedback/Submit';
   import FeedbackMailer from '@vx-howler/API/Feedback/Mailer';

   const supabase = createClient(
       process.env.NEXT_PUBLIC_SUPABASE_URL,
       process.env.SUPABASE_SERVICE_ROLE_KEY,
       { auth: { persistSession: false } }
   );

   async function getIdentity(session) {
       if (!session?.user?.email) return null;
       return {
           email:  session.user.email,
           userId: session.user.id ?? null,
           roles:  session.user.roles ?? null,
       };
   }

   export default createFeedbackHandler({
       getSession:  (req, res) => getServerSession(req, res, authOptions),
       getIdentity,
       supabase,
       mailer: FeedbackMailer,
       options: {
           notifyEmail:     process.env.FEEDBACK_NOTIFY_EMAIL,
           ipSalt:          process.env.FEEDBACK_IP_SALT,
           turnstileSecret: process.env.TURNSTILE_SECRET_KEY,
       },
   });
   ```

   The `getIdentity` function is the only app-specific piece. Adapt it to match how the target app's session stores user ID and roles.

4. **Import the SCSS** in your stylesheet entry:
   ```scss
   @import "path/to/howler/Styles/feedback";
   ```

5. **Run the DB migration**: `docs/howler/db/feedback.sql`.

6. **Set env vars** (see table above).

7. **Mount the component** on a help or feedback page.

---

## createFeedbackHandler — factory API

```js
createFeedbackHandler({
    getSession,     // async (req, res) => session | null
    getIdentity,    // async (session) => { email, userId, roles } | null
    supabase,       // Supabase client with service-role key
    mailer,         // object with async notify(row) — pass null to disable email
    options: {
        notifyEmail,      // string — admin destination
        ipSalt,           // string — salt for SHA-256 IP hashing
        turnstileSecret,  // string — Cloudflare secret; omit to skip verification
        maxPerHour,       // number — rate limit ceiling (default 5)
        tableName,        // string — target table (default 'feedback')
    },
})
```

Returns a standard Next.js API route handler (`async (req, res) => void`).

---

## Request body shape (POST /api/feedback)

```json
{
    "type":           "question | issue | idea | other",
    "message":        "string (10–4000 chars)",
    "email":          "visitor only — omit or send undefined when logged in",
    "pageUrl":        "window.location.href",
    "website":        "honeypot — always empty for real users",
    "turnstileToken": "visitor only — from Cloudflare Turnstile callback"
}
```

---

## DB row shape (public.feedback)

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | `gen_random_uuid()` |
| `created_at` | timestamptz | default `now()` |
| `type` | text | one of the four type values |
| `message` | text | 10–4000 chars |
| `status` | text | `new` \| `in_progress` \| `answered` \| `closed` |
| `user_id` | text | null for visitors |
| `email` | text | from session (logged-in) or typed input (visitor) |
| `is_anonymous` | boolean | true for visitors |
| `roles` | text | null for visitors |
| `page_url` | text | truncated to 500 chars |
| `user_agent` | text | truncated to 300 chars |
| `ip_hash` | text | salted SHA-256 of client IP |

Triage in the Supabase dashboard by filtering `status`. The `feedback_ratelimit_idx` index covers `(ip_hash, created_at desc)` for the hourly count query.

---

## Security notes

- The service-role key and all secrets never reach the client bundle. Only `NEXT_PUBLIC_TURNSTILE_SITE_KEY` is public.
- For logged-in users, identity (email, user ID, roles) is always sourced from the server session, never from the request body.
- Raw IPs are never stored or logged. The hash is irreversible without the salt.
- Message bodies and emails are never written to application logs.
- HTML-escaping is applied to all user content before it is sent in email.

---

## Out of scope (not built)

- Screenshot upload (future: private Supabase Storage bucket + `screenshot_path` column)
- Admin triage UI for `ROLE_ADMIN` (use Supabase dashboard for now)
- Public roadmap, voting board, chat, or AI features

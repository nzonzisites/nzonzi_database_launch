# Decisions log

Running record of ambiguities flagged during implementation and how each was resolved.
Ordered by when they came up, grouped by model. Spec references are to `marketplace-spec-v5.md`.

## Project structure (pre-model)

- **Repo scope**: backend/data layer only — no Next.js app, no pages/API routes. A separate
  frontend (or Claude Design export) consumes this later. *(User decision, 2026-09-13.)*
- **Migration workflow**: Supabase CLI SQL migrations in `supabase/migrations/`, not an ORM.
  *(User decision, 2026-09-13.)*
- **StatusChangeEvent isolation**: service-role keys can still bypass RLS via PostgREST, so
  RLS alone doesn't satisfy "not readable from any client-facing API." Plan: put
  `status_change_event` (and any future internal-only tables) in an `internal` Postgres schema
  that is never added to `supabase/config.toml`'s `api.schemas`. PostgREST/GraphQL then have no
  route to it at all, regardless of key. *(Proposed by assistant, pending confirmation when we
  build that table.)*
- **Auth provider**: spec says "delegated to an external auth provider" but doesn't name which
  one(s) (Google, LinkedIn, magic link, etc.). `supabase/config.toml` sets `enable_signup =
  false` to disable Supabase's built-in email/password path, consistent with "no in-house
  password storage" — but the actual external provider(s) to enable are still unspecified.
  **Open — needs your input before Auth config is finalized.**
- **Git identity**: the initial commit landed with an auto-detected local identity, not the
  user's real name/email. Not fixed automatically (git config changes are out of scope for the
  assistant to make unprompted) — flagged for the user to set `user.name`/`user.email` in this
  repo if desired.

## ProspectSignup — approved 2026-09-13

Migration: `supabase/migrations/20260913000001_create_prospect_signup.sql`

- **Email uniqueness / resubscribe**: spec doesn't state whether the same email can sign up
  twice. Assumed one row per email (case-insensitive unique index on `email`); a resubscribe is
  an upsert that clears `unsubscribed_at`, not a new row. **Approved.**
- **RLS**: spec gives no access rules for this table (unlike StatusChangeEvent). Defaulted to:
  anon/authenticated can `INSERT` only (the landing page form); no public `SELECT`/`UPDATE`/
  `DELETE` — reads are internal-tooling only until a PlatformAgent-facing view exists.
  **Approved.**
- **Unsubscribe-link mechanism**: the privacy notice promises an email unsubscribe link, which
  implies a token-based or server-side path to flip `unsubscribed_at` without login. Not
  modeled yet (no `unsubscribe_token` column — not in spec) since it's an API-layer concern for
  whenever the email-sending flow is built, not a schema one now. **Flagged, deferred.**
- `source` modeled as free text, no enum — consistent with how `Application.referral_source` is
  described the same way in the spec.


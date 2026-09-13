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


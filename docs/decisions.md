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

## Application — approved 2026-09-13

Migration: `supabase/migrations/20260913000002_create_application.sql`

- **Ordering conflict**: `reviewed_by` references `PlatformAgent`, which per spec Section 2's own
  ordering doesn't exist yet at this point (it comes after `User`). Added as a plain nullable
  `uuid` column now; the FK constraint gets added via `ALTER TABLE` once `platform_agent` exists.
  **Approved — remember to add that ALTER when building PlatformAgent.**
- **Reapply question (spec Section 6, explicitly open)**: left `email` non-unique on this table
  so multiple Application rows per email are allowed — least-lossy default, doesn't foreclose
  either "reopen same row" or "new row" resolution. **Still genuinely open — user approved the
  schema as a placeholder, not as a final answer to the Section 6 question.**
- **`reference_contact` flattened** into `reference_name`/`reference_relationship`/
  `reference_contact_method`/`reference_contact_value`/`reference_whatsapp_available`/
  `reference_may_contact` columns rather than JSONB — fixed single-object shape, kept queryable.
  **Approved.**
- **`work_samples`** modeled as `jsonb` array of `{type: "file"|"link", ...}` objects (mixed-type
  list). CHECK constraint requires `work_samples_explanation` when the array is empty.
  **Approved.**
- **`intended_category`** enum reconciles slightly different wording between spec Section 1 and
  Section 7 into single slugs (e.g. `cosmetic_chemistry_formulation_science`). CHECK constraint
  requires `intended_category_other` when category is `other`. **Approved.**
- **`decision_reason` required on approve/reject** — enforced via CHECK constraint, beyond a
  literal reading of spec Flow A but consistent with the "reason required on sensitive
  transitions" pattern used for Payment/Payout/Report. **Approved.**
- **Status-transition enforcement** via a `BEFORE UPDATE` trigger rejecting any transition not
  in the spec's allowed list. Unrelated to the StatusChangeEvent "no trigger" rule, which only
  governs that table's audit-log write path. **Approved.**
- **RLS**: anon/authenticated `INSERT` only, no read/update policies yet. PlatformAgent review
  access to be added once `User`/`PlatformAgent` exist. **Approved.**

## User — approved 2026-09-13 ("approved i guess" — revisit if it starts to feel wrong)

Migration: `supabase/migrations/20260913000003_create_user.sql`

- **Four tables instead of one**: `app_user` (core identity) + `buyer_profile` +
  `seller_profile` (public-readable) + `seller_payout_detail` (private). Role membership
  (buyer/seller) is derived from row *presence* in the respective profile table, not a
  separate `role` column — spec's own field list under `User` doesn't list one.
  **User explicitly chose the separate-table split over one wide table, see the payout
  isolation question asked before this migration was written.**
- **Table named `app_user`, not `user`** — `user` is a reserved word in Postgres. Pure naming
  deviation. **Approved.**
- **`id` vs `auth_provider_id` kept separate** rather than making `app_user.id` equal to the
  Supabase Auth uid directly — matches spec listing both as distinct fields, gives an internal
  id stable independent of the auth backend. **Approved.**
- **No cascading delete from `auth.users` to `app_user`** — once Listing/Order/Message
  reference `app_user.id` later, a cascade triggered by an auth-identity deletion could wipe
  marketplace history. Deleting the auth identity while `app_user` still references it fails
  until the app explicitly offboards first. `buyer_profile`/`seller_profile` → `app_user` do
  cascade (true sub-profiles of the core row). **Approved.**
- **`seller_profile.verification_status` and `rating_average` locked against seller
  self-edit** via column-level `REVOKE`/`GRANT` (RLS is row-level, can't do this alone) — a
  seller can update `bio`/`headshot`/`location`/`external_testimonials` on their own row but
  not those two columns. **Approved.**
- **Two pieces deferred to later migrations** (same ordering issue as `Application.reviewed_by`):
  a policy letting PlatformAgents set `verification_status`, and the StatusChangeEvent write-path
  enforcement for that column — neither `PlatformAgent` nor `StatusChangeEvent` exist yet.
  **Flagged, deferred — do not forget when building those tables.**
- **`seller_profile` insert gated on an approved `Application`** matching email (Flow A step
  3-4) — enforceable now since `Application` already exists. **Approved.**
- **Two spec gaps, not filled in**: `buyer_type = 'other'` has no companion free-text field
  (unlike `Application.intended_category_other`) — not added, would be guessing.
  `external_testimonials`/`media_mentions` structure isn't specified — modeled as a flexible
  `jsonb` array. **Approved as placeholders.**
- **`rating_average` is a plain nullable column** — aggregation-from-reviews mechanism can't be
  built until the `Review` model exists later in Section 2. **Approved, deferred.**
- **`payout_details` is a loose `jsonb` blob** — Phase 3/Stripe Connect specifics aren't spec'd
  and payments logic is explicitly out of scope for this build; this just reserves the space.
  **Approved.**

## PlatformAgent — approved 2026-09-13

Migration: `supabase/migrations/20260913000004_create_platform_agent.sql`

- **Buyer/seller separation not hard-enforced**: spec says staff "generally shouldn't"
  transact as buyer/seller on the same identity — soft language, not "never." No CHECK/trigger
  blocks a PlatformAgent's `app_user` from also holding a `buyer_profile`/`seller_profile`; it's
  a convention, not a DB constraint. **Approved as-is.**
- **`verification_status` writes go through a `SECURITY DEFINER` function
  (`set_seller_verification_status`), not a table grant** — a table-level
  `GRANT UPDATE (verification_status) TO authenticated` would leak into the seller's own
  "update own profile" policy from the User migration, since Postgres column grants apply to
  the role, not to a specific policy. The function checks `review_sellers` permission
  internally and updates with its own elevated privilege instead. This is also the pattern
  that will be extended for the StatusChangeEvent write path once that table exists (the
  `TODO` comment in the function marks exactly where). **Approved.**
- **Reusable helpers `is_platform_agent_with(permission)` and `current_platform_agent_id()`**
  added now — not spec-mandated, but Report/Listing review policies will need the same "is
  caller a PlatformAgent with permission X" check later, so introducing it once here avoids
  drift across policies. **Approved.**
- **Backfilled `Application.reviewed_by` FK** to `platform_agent(id)`, deferred from that
  migration due to Section 2's model ordering. **Done.**
- **Backfilled `Application` SELECT/UPDATE policies** for PlatformAgents with `review_sellers`
  — none existed before this migration, so Application rows were previously unreadable via the
  client-facing API even to staff. `WITH CHECK` stamps `reviewed_by` as the acting agent's own
  id on every update, so review actions are always attributable per spec Flow A/E. **Approved.**
- **`platform_agent` itself**: self-read-only RLS, no insert/update/delete for
  anon/authenticated — granting/revoking staff permissions is a service-role/admin action,
  same self-elevation concern as `verification_status`. **Approved.**

## Listing — approved 2026-09-13

Migration: `supabase/migrations/20260913000005_create_listing.sql`

- **Spec inconsistency, resolved in favor of the StatusChangeEvent note**: Section 2's field
  list for `Listing` omits `reviewed_by`/`decision_reason`, but the StatusChangeEvent note in
  that same section claims Listing "already carries" those fields — true only for Application
  and Report as literally listed. Treated as an omission; added both columns to Listing.
  **Approved.**
- **New `review_listings` permission** added to `platform_agent_permission` (via
  `ALTER TYPE ... ADD VALUE`) rather than overloading `review_sellers` for listing review —
  spec's own field list says "permissions: e.g. review_sellers | ...", and that "e.g." signals
  the list isn't exhaustive. **Approved.**
- **`category` reuses `Application`'s enum**, including the `other`/`category_other` pattern —
  handles the edge case where the seller's Application itself was `other`. Assistant's own
  inference, not explicit spec language. **Approved.**
- **`sold_out` has no way back to `active`** in the literal spec transition list — reads like a
  likely spec oversight. Implemented literally rather than unilaterally adding a fix.
  **Flagged, left as-is per user request below.**
- **No transition back to `draft` exists at all** once a listing leaves that state — same kind
  of gap as `sold_out`, confirmed with the user (2026-09-13): the "seller submits → agent
  reviews/edits/approves" loop the user described is the *existing* `pending_re_review` flow,
  not a request for a new draft transition. **Confirmed no schema change needed** — agents'
  listing UPDATE policy already has no column restriction (unlike the seller's column-limited
  grant on `seller_profile`), so an agent can already edit listing content fields (title,
  description, price, etc.) while reviewing/approving. **No new transition added; `sold_out`
  and no-return-to-draft both remain open flags if this becomes a real need later.**
- **Role-gated transitions enforced in the status-transition trigger, not just RLS**: `draft→
  active` and `pending_re_review→{active,paused}` require a `review_listings` PlatformAgent
  (and stamp `reviewed_by` as the acting agent, checked in-trigger); `active↔paused`, `active→
  pending_re_review`, `active→sold_out` require the listing's own seller. RLS alone can't
  express "same UPDATE, different allowed target depending on caller." **Approved.**
- **On `active→pending_re_review`**, the trigger force-clears `reviewed_by`/`decision_reason`
  — a prior approval shouldn't stay attached to edited content. Not explicitly spec'd.
  **Approved.**
- **`currency` defaults to `'USD'`** (spec Section 5: canonical price "likely USD") without a
  hard CHECK restricting it, since "likely" is spec's own hedge. **Approved.**


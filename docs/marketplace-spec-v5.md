# Scholar Directory Marketplace — Spec (V5)

Front End Design: Claude Design - Nzonzi

## 1. Concept Summary

What's being exchanged: Freelance services — scholars offering subject matter expertise. Buyer side: Businesses, event curators, startups, think tanks, other (user-inputtable). Seller side: Scholars, offering subject matter expertise. Seller geography for MVP: Ibadan, Nigeria. Buyer geography for MVP: New York City, NY. Category scope for MVP: 7 categories, ranked by monetization strength and platform fit — (1) Cosmetic Chemists/Formulation Scientists (Skin & Hair), (2) Supply Chain/Procurement & Sourcing, (3) Materials Scientists, (4) Mechanical/Manufacturing Engineers, (5) Industrial Designers, (6) Quantitative & Qualitative Researchers (framed narrowly toward physical-product/field evaluation research, not generic UX/market research), (7) Arts & Cultural Researchers. Service delivery mode: Both remote consulting and travel-required engagements are feasible — flagged per listing, and now also captured as the applicant's own stated modality preference at application time (see `Application.work_modality`). How the platform makes money: Subscription to the database. Not pay-gated at launch — pricing is shown to assess demand and willingness to pay before charging anything. Once demand is validated, and once payments begin to be brokered for specific markets, the platform will begin taking commission.

New in V4: the seller pipeline is now three distinct identities rather than one, reflecting the actual funnel — a wide-net landing page, a reviewed application, and an account created only on approval. See Section 2 and Flow F.

**New in V5:** the audit/history mechanism (previously open — see former Section 6) is resolved. An append-only `StatusChangeEvent` table now covers status transitions on `Order`, `Payment`, `Payout`, and `User` verification status. See Section 2 and Section 6.

## 2. Data Model

Redrafted from V3 to split the seller pipeline into three separate models rather than nesting everything under User, since most of the pipeline happens before any account exists.

### ProspectSignup
Landing page, newsletter, and outreach list. No login, no review — wide-net capture only.
- id
- email
- name (optional)
- affiliation (optional)
- interest: buyer | seller | both | unspecified
- subscribed_at
- unsubscribed_at (nullable)
- source (how they landed here — matches "How did you hear about us" framing, reused at application time too)

### Application
The reviewed seller application. Exists independently of any User, keyed by email, since no account exists yet when someone applies.
- id
- prospect_signup_id (FK → ProspectSignup, nullable — set when a match is found by email at submission time)
- full_name
- email
- phone_or_whatsapp
- city_country
- affiliations (list — "list all that apply")
- external_links (LinkedIn, personal site, or CV)
- intended_category: one of the 7 MVP categories, or other (with intended_category_other free text)
- work_modality: remote_only | travel_flexible | both
- infrastructure_narrative (~150–300 words — the constraint-and-response story)
- expertise_narrative (skills/knowledge held with pride, and the value they bring; applicant specifies whether technical, social-relational, cultural, or other)
- work_samples (list of file uploads or links; if none, work_samples_explanation free text)
- reference_contact:
  - name
  - relationship
  - contact_method: email | phone
  - contact_value
  - whatsapp_available (nullable — only relevant if contact_method is phone)
  - may_contact: boolean
- additional_notes (optional — "anything else you'd like us to know")
- referral_source (optional — "how did you hear about Nzonzi," distinct from ProspectSignup.source even when both exist for the same person)
- status: applied | under_review | approved | rejected
  - Allowed transitions: applied → under_review; under_review → approved | rejected. No other jumps permitted. Reapplication after rejection is an open question — see Section 6.
- reviewed_by (FK → PlatformAgent, nullable until picked up)
- decision_reason
- created_at

Note: Application persists after approval as the permanent historical record of what the applicant submitted and how the decision was reached — it is not deleted or overwritten once a User is created.

### User
Created only at the point an Application is approved. Buyers create a User directly, with no application step.
- id
- email
- auth_provider_id (delegated to an external auth provider — no in-house password storage)
- full_name
- created_at
- updated_at
- buyer (nested, present when role includes buyer):
  - buyer_type: market_entry_gtm_research | product_development_formulation | supply_chain_sourcing | event_speaker_sourcing | academic_or_policy_research | other
- seller (nested, present when role includes seller — populated during onboarding immediately after Application approval):
  - bio
  - headshot
  - location
  - rating_average
  - external_testimonials / media_mentions (third-party validation not originating as a platform review)
  - payout_details (collected now, not activated until Phase 3 and only for supported markets)
  - **verification_status: unverified | verified** (status-change history tracked via `StatusChangeEvent` — see the new subsection below)

Note: reference contacts, category selection, and the narrative fields no longer live on User — they belong to Application, since a rejected applicant never becomes a User at all and shouldn't carry that data into an account model.

### PlatformAgent
- id
- user_id (FK → User) — kept fully separate from Buyer/Seller, since staff generally shouldn't transact as a buyer/seller on the same identity
- permissions: e.g. review_sellers | review_reports | issue_refunds | manage_evidence_review (list/array — an agent may hold several)
- created_at

Note: any action taken on an Application, Listing, Report, or delivery-evidence review should record which PlatformAgent performed it.

### Listing
- id
- seller_id (FK → User)
- title
- description
- category — defaults from Application.intended_category at listing creation, but independently editable afterward (a PlatformAgent may approve someone into a different category than they applied under)
- price_minor_units (integer, e.g. $25.75 stored as 2575) / currency
- delivery_mode: remote | will_travel | both
- status: draft | active | paused | sold_out | pending_re_review
  - Allowed transitions: draft → active (on initial approval); active ↔ paused (seller-toggled); active → pending_re_review (on seller edit); pending_re_review → active (re-approved by a PlatformAgent) or → paused (sent back for revision); active → sold_out (seller-toggled, if applicable).
- created_at

### Order
The business event — what was purchased/accessed and its fulfillment state. Decoupled from money movement, which lives in Payment/Payout below.
- id
- buyer_id (FK → User)
- listing_id or seller_id (FK, nullable depending on model)
- type: access_unlock | subscription | full_transaction
- status: pending | fulfilled | disputed | cancelled *(status-change history tracked via `StatusChangeEvent`)*
- outcome: no_response | in_discussion | engaged_offplatform | not_pursued (self-reported, buyer side)
- seller_outcome: no_contact | discussed | engaged | declined (self-reported, seller side)
- cancellation_initiator: seller | trust_safety_review (cancellations default to seller discretion, escalate to trust & safety if quality wasn't as promised — requires a reason)
- created_at

Note: if the underlying service is paid off-platform, this record tracks the connection/access itself, not a financial transaction — no Payment record exists for it. Payment/Payout records only exist once Phase 3 on-platform payments are live for the relevant market.

### Payment
Buyer → platform. Exists only for on-platform transactions (Phase 3, supported markets).
- id
- order_id (FK → Order)
- amount_minor_units (integer) / currency
- display_amount_minor_units / display_currency (buyer's local currency, if different from canonical)
- status: pending | paid | held_in_escrow | evidence_submitted | released | refunded *(status-change history tracked via `StatusChangeEvent`)*
  - Allowed transitions: pending → paid; paid → held_in_escrow; held_in_escrow → evidence_submitted (on seller submission, if buyer hasn't confirmed) or → released (on buyer confirmation); evidence_submitted → released (on PlatformAgent approval) or → refunded; any status → refunded via trust & safety escalation (requires reason and the approving PlatformAgent's id).
- delivery_evidence (seller-submitted proof of service delivery, used if buyer never confirms receipt)
- created_at

### Payout
Platform → seller. Exists only once a Payment has been released.
- id
- payment_id (FK → Payment)
- seller_id (FK → User)
- amount_minor_units (integer, after platform_fee deduction) / currency
- platform_fee_minor_units (15% commission)
- status: pending | sent | failed *(status-change history tracked via `StatusChangeEvent`)*
- created_at

### Message
- id
- order_id (FK → Order, nullable if pre-purchase inquiry)
- sender_id (FK → User)
- recipient_id (FK → User)
- body (nullable/unused if one-way email relay is chosen — see Flow B note)
- sent_at

### Review
- id
- order_id (FK → Order)
- author_id (FK → User)
- rating: 1–5
- comment
- created_at

### WaitlistEntry
Demand/pricing signal for the future paywalled search feature. Distinct from ProspectSignup — this captures a reaction to a specific price shown to an existing user, not a landing-page lead.
- id
- user_id (FK → User)
- context: search_paywall | new_category | other
- price_shown_minor_units (nullable — only set for a pricing test) / currency
- reaction: interested | too_expensive | joined_waitlist
- created_at

### Report
- id
- reporter_id (FK → User)
- reported_listing_id or reported_user_id (FK)
- reason: false_listing_claims | service_not_delivered_as_described | unprofessional_conduct | other
- description
- status: submitted | under_review | resolved_no_action | resolved_listing_suspended | resolved_user_suspended
  - Allowed transitions: submitted → under_review (on PlatformAgent pickup); under_review → resolved_no_action | resolved_listing_suspended | resolved_user_suspended. Any resolved_* outcome requires a reason and the resolving PlatformAgent's id.
- reviewed_by (FK → PlatformAgent, nullable until picked up)
- created_at

### StatusChangeEvent *(new in V5)*
Append-only audit log for status transitions. Resolves the previously open audit/history decision (former Section 6). Covers `Order`, `Payment`, `Payout`, and `User.seller.verification_status`. Not applied to `Application`, `Listing`, or `Report`, which already carry their own `reviewed_by`/`decision_reason` fields on the record itself; this can be revisited if those need full transition history later.

- id
- entity_type: order | payment | payout | user_verification
- entity_id (FK to the relevant record)
- actor_id (FK → User — the buyer, seller, or PlatformAgent who triggered the change)
- actor_role: buyer | seller | platform_admin
- previous_status
- new_status
- reason (required — satisfies the existing required-reason rule on sensitive transitions across Order, Payment, and Payout)
- metadata (jsonb — entity-specific context, e.g. `refund_initiated`, `reviewer_notes`)
- created_at

**Write path:** every status change writes its `StatusChangeEvent` row in the same database transaction as the status update itself. No separate trigger, hook, or async job. If the transaction fails, neither the status change nor the log entry persists, so the log can never drift out of sync with actual state.

**Access:** internal only. No user-facing API endpoint or UI at MVP or Phase 3. Queried directly (DB-level access) by PlatformAgents or engineering for dispute resolution and trust & safety review.

## 3. Core User Flows

### Flow F: Landing page prospect capture (new)
1. Visitor lands on the site, provides email and optionally name/affiliation, and states interest (buyer, seller, both, or unspecified)
2. A ProspectSignup record is created
3. Prospect receives outreach: application invitations and reminders (if seller-interested), newsletter and launch updates (if opted in)
4. If the prospect later submits an Application, the system matches by email and sets Application.prospect_signup_id, avoiding a fully duplicate ask where fields already overlap (name, affiliation)

### Flow A: Seller application, review, and onboarding
1. Prospective seller completes the application (full form — see Section 7 for page content). An Application record is created; if a matching ProspectSignup exists by email, it's linked.
2. A PlatformAgent (with review_sellers permission) reviews the application: checks the narrative responses and work samples, contacts the reference if may_contact is true, optionally holds a screening call, and records approved or rejected with a decision_reason (Application.status updates per the allowed-transition list in Section 2)
3. On approval, the applicant creates a User account via the external auth provider. This is the first point at which a User record exists for this person.
4. Onboarding (still folded into Flow A rather than given its own name — open question, see Section 6): the new seller submits headshot, bio, and payout details (collected now, not activated until Phase 3), populating User.seller
5. Seller creates a Listing, pre-filled with category from Application.intended_category but editable
6. Listing goes live after a PlatformAgent reviews it for style-guide fit
7. Edits after going live: seller submits changes → listing moves to pending_re_review → a PlatformAgent reviews → re-approved and live, or sent back for revision

### Flow B: Buyer discovers and connects
1. Buyer browses or searches listings, filters by category or location
2. Buyer views listing detail page
3. Buyer messages seller. One-way email relay (buyer's message forwarded to the seller's personal email; conversation continues off-platform) was selected for MVP speed. Trade-off to hold onto: this gives away the "direct contact" step for free now, which Phase 2 plans to paywall later — early users effectively get grandfathered free access to that step. Revisit in favor of platform-native message threads if richer engagement signal becomes a priority before Phase 2.
4. Outcome capture: ~1–2 weeks after first contact, buyer receives a short self-report prompt ("Did you end up working with this scholar?" → sets outcome on the Order record). Seller receives a parallel short prompt (seller_outcome).
5. Both sides can leave a review once an outcome is recorded
6–9. Apply once the platform begins brokering transactions directly, not at MVP: buyer initiates purchase → Payment created, funds held per escrow model → seller notified, fulfills the order/service → buyer confirms receipt, or seller submits delivery_evidence if the buyer doesn't respond, triggering PlatformAgent review → on approval, a Payout record is created and funds released (minus platform fee)

### Flow C: Reports (false listings / service-delivery disputes)
1. Either party (or a buyer who never contacted the seller directly but suspects a listing is inaccurate) submits a report against a listing or user, selecting a reason
2. A PlatformAgent (with review_reports permission) picks up the report — may include reaching out to both parties
3. Resolution: no action, listing/profile temporarily suspended pending correction, or listing/user permanently suspended — any suspension outcome requires a documented reason and the resolving PlatformAgent's id
4. If reinstated after correction, the listing re-enters pending_re_review from Flow A before going live again

### Flow D: Demand/pricing signal capture
1. Buyer (or prospective buyer) encounters the future paywalled search feature, shown with an example price
2. Buyer reacts: expresses interest, flags it as too expensive, or joins the waitlist
3. Reaction logged to WaitlistEntry, used later to validate pricing before anything is charged

### Flow E: Platform agent review queue
1. PlatformAgents log in to a queue view, scoped to their permissions (applications, reports, or evidence review)
2. For an application: reviews narratives/work samples/reference, optionally initiates a screening call, records approve/reject with a reason
3. For a report: reviews the flagged listing/user and any prior history, reaches out to parties if needed, records resolution with a reason
4. For evidence review (Phase 3): reviews seller-submitted delivery_evidence against the order, approves release or escalates to refund
5. All actions record the acting PlatformAgent's id and, for sensitive transitions, a required reason

**Flow G: Status change logging (new)**
Runs invisibly alongside Flows A–E wherever a covered entity's status changes:
1. An actor (buyer, seller, or PlatformAgent) triggers a status transition on an Order, Payment, Payout, or User verification status
2. In the same transaction as the status update, a StatusChangeEvent row is written recording the actor, role, previous/new status, required reason, and any relevant metadata
3. No user-facing surface exposes this log; it exists solely for internal PlatformAgent/engineering query during dispute resolution or trust & safety review

## 4. Feature List (MVP-first prioritization)

**Must-have (MVP)**
- Landing page + ProspectSignup capture (Flow F)
- Landing page privacy notice
- Application form + Application record creation, with ProspectSignup email-match (Flow A step 1)
- Application privacy notice
- Auth via external provider (no in-house password management) — triggered at application approval, not before
- PlatformAgent application review workflow (Flow A step 2)
- Seller onboarding (headshot, bio, payout details) + User.seller creation (Flow A steps 3–4)
- Listing creation, pre-filled from Application.intended_category
- Listing edit → re-review workflow
- Buyer browse/search with category and location filters
- Listing detail page
- One-way email relay for buyer→seller first contact
- Self-report outcome capture (buyer and seller side)
- Reporting/flagging workflow for false listings or service issues (Flow C)
- Demand/pricing signal capture (waitlist + price reaction)
- PlatformAgent review queue UI (Flow E) — applications and reports, scoped by permission
- **StatusChangeEvent logging for Order, Payment, Payout, and User verification status (Flow G)**

**Should-have (post-MVP)**
- Ratings and reviews
- Saved/favorited listings
- Platform-native messaging (if email relay signal quality proves insufficient)
- Search relevance improvements
- Email/SMS notifications
- Seller analytics dashboard

**Nice-to-have (later, Phase 2+)**
- Paywalled structured search/filtering
- Saved searches, side-by-side comparison
- Automated fraud detection

**Phase 3 (facilitated payments — not current priority)**
- Stripe Connect payout activation (supported markets only)
- Escrow/hold model for Payment records
- Payout creation and disbursement workflow
- PlatformAgent evidence-review UI (Flow E step 4)
- Full refund/cancellation escalation workflow

## 5. Resolved Decisions (Phase 3 — Facilitated Payments)

Unchanged from V3.
- Escrow model: Funds held in escrow until fulfillment is confirmed, for payments processed on-platform.
- Seller verification: Handled by PlatformAgents (with review_sellers permission) via the Flow A review process.
- No buyer confirmation (auto-release fallback): Seller must submit evidence of service delivery if the buyer never confirms; disbursement proceeds from that evidence rather than buyer action alone, reviewed by a PlatformAgent. Timeout window before evidence-based review kicks in still needs a number.
- Cancellation/refunds: At the seller's discretion by default; escalates to the trust & safety team for re-evaluation if service quality wasn't as promised.
- Take rate: 15% commission on payments processed on-platform.
- Cross-border pricing display: Prices shown in the buyer's local currency, requiring a canonical price (likely USD) on each listing plus an FX conversion layer for display.
- Cross-border payouts: On-platform payment processing (Phase 3) is limited to markets where Stripe Connect payout support actually exists at the time of launch. Nigeria is not currently one of them. Interim approach: Ibadan-based sellers stay on the off-platform payment model regardless of Phase 3 rollout elsewhere; on-platform payments expand to Nigeria only once Stripe Connect payout support is confirmed live.
- Shipping/logistics: Handled by sellers directly; not applicable in most cases since this is a services marketplace.
- Cross-border trust-building: Verification (Flow A), reviews/testimonials, media mentions, and non-user client/collaborator recommendations. Data model implication: User.seller.external_testimonials/media_mentions holds third-party validation that didn't originate as a platform review.

**Resolved in V5:**
- Audit/history mechanism for status changes: an append-only `StatusChangeEvent` table, covering Order, Payment, Payout, and User verification status. Written in the same transaction as the status update it records. Internal read/access only — no user-facing exposure. See Section 2.

## 6. Open Decisions Still Outstanding

- Which specific markets are "supported" for on-platform payments at Phase 3 launch, and how that list is maintained as Stripe Connect's own country support changes over time
- Evidence-review timeout window before evidence-based review kicks in (e.g. 14 days) still needs a number
- Whether one-way email relay is acceptable long-term given the future paywall on "direct contact," or whether platform-native messaging is worth the extra build cost now
- Exact cadence/wording for the outcome self-report prompts
- What triggers moving from Phase 1 to Phase 2 pricing
- Whether WaitlistEntry needs to split into a separate pricing-experiment table once real A/B price testing starts
- Does seller onboarding (headshot, bio, payout details) get its own named flow ("Flow A2"), or stay folded into Flow A as later steps?
- Can a rejected applicant reapply? If so, does that reopen the same Application row (matched by email) or create a new one?
- Concrete retention period for Application data belonging to rejected applicants — currently undefined in the privacy notice draft (Section 8) and needs a real number before that page ships
- Which specific third-party tools process Application data (beyond MailerLite, which is confirmed for the landing/newsletter side) — needed to name them accurately in the application privacy notice

## 7. Application Page Content

Copy as drafted, collected into Application per Section 2.

We're building a curated directory of scholar-practitioners whose expertise was forged, not despite resource constraints, but through them — people who've turned an infrastructure gap (power, funding, supply chains, data, institutional access, connectivity) into a method, a fix, or an innovation a business can now hire for directly. This isn't a general call for researchers. We're looking for people who can point to a specific moment where working in a resource-lacking environment produced expertise that's now provably useful outside it. Applications are reviewed by our team; approval isn't guaranteed, and review may include a short screening call.

**Basic Information**
1. Full name
2. Email address
3. Phone or WhatsApp
4. City & country you currently work from
5. Current institutional or professional affiliation (list all that apply)
6. LinkedIn, personal site, or CV link
7. Which category best fits your expertise? (Cosmetic Chemistry/Formulation Science, Supply Chain & Procurement, Materials Science, Mechanical/Manufacturing Engineering, Industrial Design, Applied Quant/Qual Research, Arts & Cultural Research, Other — with a specify field)
8. What work modalities are you comfortable with while working with a client? (Remote only / Travel flexible / Both)

**Where Infrastructure Fails, Innovation Thrives**
1. Describe one specific infrastructure constraint you've worked within or around (power, funding, institutional access, supply chains, data, connectivity, or otherwise). What did you have to build, adapt, or figure out because of it? (~150–300 words)
2. What specific skill sets or knowledge bases do you hold with pride? What value does it bring to yourself or to others? Please specify if you're referring to technical, social-relational, or cultural knowledge, or something else entirely.
3. Share 1–3 work samples that speak to this (paper, dataset, product, case study, press mention, report) — file upload or link. If you don't have any work samples available, please explain.

**Reference Contact**
- Reference's name
- Their relationship to you
- Their email or phone number (if phone number, please include their country code and confirm WhatsApp calling is available)
- May we contact them as part of your application review? (yes/no)

**Optional**
- Is there anything else you would like for us to know?
- How did you hear about Nzonzi?

## 8. Privacy Notices

Two separate notices, matched to two separate models (Section 2) and two separate intents: casting a wide net (landing page) versus reviewing a specific person (application).

### 8a. Landing Page Privacy Notice — governs ProspectSignup

nzonzi privacy notice
Last updated: [date]

This notice explains what happens when you register your interest in Nzonzi through our landing page.

**What we collect** When you register, we collect your email address, your stated interest (buyer, seller, or both), and any additional details you provide, such as your name and affiliation.

**Why we collect it** We use this information to: — Confirm your registration and follow up if you've expressed interest in applying as a seller — Send you the application, along with reminders if it's incomplete — Send occasional updates about Nzonzi's launch, if you've opted in — Understand user demographics and preferences to improve our offerings

**Who we share it with** We use third-party platforms to store and send communications, including MailerLite and potentially other email or data processing tools as Nzonzi grows. These providers process your data on our behalf and under their own security and privacy commitments. We don't sell your data or share it with unrelated third parties.

**How long we keep it** We retain your information for as long as you remain registered with us, or until you ask us to delete it.

**Your choices** You can unsubscribe from any email at any time using the link in that email. To request a copy of your data, ask a question, or request deletion, contact us at hello@nzonzi.net.

**Changes to this notice** If this notice changes in a meaningful way, we'll update the date above and, where appropriate, let registered users know.

### 8b. Application Privacy Notice — governs Application

nzonzi seller application privacy notice
Last updated: [date]

This notice explains what happens to your information when you apply to be listed as a scholar on Nzonzi. It's separate from, and more detailed than, our general landing page notice, because the application collects more information and that information is reviewed by our team.

**What we collect** When you apply, we collect: your full name, email, phone or WhatsApp number, city and country, professional affiliations, links (LinkedIn, personal site, or CV), your category and work modality selections, your written responses about infrastructure constraints and your expertise, any work samples you share (files or links), and how you heard about us. We also collect the name, relationship, and contact details of one reference you provide, along with your confirmation of whether we may contact them.

**Reference contact information** The reference you name did not submit their own information to us — you provided it on their behalf. We use it solely to verify your application, only if you've indicated we may contact them, and only for that purpose. We don't add your reference to any mailing list or use their contact information for anything beyond this verification step.

**Why we collect it** We use this information to review your application, verify your background and references, contact you about the status of your application, and, if approved, help you set up your seller listing.

**Who we share it with** Your application is reviewed by our internal team. We use third-party platforms to store application data and communications [names to be finalized — see Section 6]. These providers process your data on our behalf and under their own security and privacy commitments. We don't sell your data or share it with unrelated third parties.

**How long we keep it** If your application is approved, we retain it as part of your ongoing seller record. If your application is not approved, we retain it for [retention period to be finalized — see Section 6], after which it's deleted unless you've asked us to keep it or reapply.

**Your choices** To request a copy of your application data, ask a question, or request deletion, contact us at hello@nzonzi.net.

**Changes to this notice** If this notice changes in a meaningful way, we'll update the date above and let applicants and sellers know, where appropriate.

# Nzonzi — data layer

Supabase schema, migrations, and typed DB access for the Nzonzi marketplace. This repo is
data-layer only: no frontend, no API routes. See [`docs/marketplace-spec-v5.md`](docs/marketplace-spec-v5.md)
for the product spec and [`docs/decisions.md`](docs/decisions.md) for the running log of
implementation decisions and open questions.

## Stack

- **Database/Auth/Storage**: Supabase (Postgres)
- **Migrations**: Supabase CLI, plain SQL in `supabase/migrations/`
- **Version control**: GitHub
- **Hosting** (of whatever eventually consumes this): Vercel

## Requirements

- [Supabase CLI](https://supabase.com/docs/guides/cli) installed locally
- Node.js (for `@supabase/supabase-js` and type generation)

## Setup

```bash
npm install
supabase start        # local Postgres + Studio via Docker
npm run db:push        # apply migrations
npm run db:types       # regenerate db/types/database.types.ts
```

Copy `.env.example` to `.env` and fill in your project's URL and keys.

## Structure

```
supabase/migrations/   one file per model, applied in order
db/client.ts            typed Supabase clients (anon + service-role)
db/types/                generated TS types, regenerate after every migration
docs/                    product spec + decisions log
```

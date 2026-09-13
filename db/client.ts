import { createClient } from "@supabase/supabase-js";
import type { Database } from "./types/database.types";

const url = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !anonKey) {
  throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY must be set");
}

// RLS-bound. Safe for anything acting as a specific buyer/seller/PlatformAgent.
export const supabase = createClient<Database>(url, anonKey);

// Bypasses RLS. Server-side/internal tooling only — never expose this key to a browser.
// Note: bypassing RLS is not why status_change_event stays hidden from the client-facing
// API — the `internal` schema is simply never listed in supabase/config.toml's
// api.schemas, so PostgREST/GraphQL have no route to it regardless of which key is used.
// This client exists for direct-DB access to that schema (dispute resolution tooling, etc.).
export function getServiceRoleClient() {
  if (!serviceRoleKey) {
    throw new Error("SUPABASE_SERVICE_ROLE_KEY must be set to use the service-role client");
  }
  return createClient<Database>(url, serviceRoleKey);
}

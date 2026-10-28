// Little Events (apps.little.africa) ticket sales for Tuner Fest, for the admin panel.
// Called from the admin panel with no body. Only signed-in admins may call it.
// Secrets (Supabase → Edge Functions → Secrets):
//   LITTLE_EVENTS_API_KEY – from Little Events → Integrations → Generate API key
//   LITTLE_EVENTS_SLUG    – optional, defaults to "tunerfest-2026"
// The key never leaves this function; the browser only sees the sales figures.
import { createClient } from "npm:@supabase/supabase-js@2.58.0";

const API = "https://apps.little.africa/events/integrations/api";
const SALES_FROM = "2025-01-01T00:00:00Z"; // the API defaults to the last 30 days, so ask for everything
const MAX_PAGES = 50;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

class LittleError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

async function little(key: string, path: string, query: Record<string, string | number> = {}) {
  const qs = new URLSearchParams(Object.entries(query).map(([k, v]) => [k, String(v)])).toString();
  const res = await fetch(`${API}${path}${qs ? `?${qs}` : ""}`, {
    headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
  });
  let body: any = null;
  try { body = await res.json(); } catch { /* handled below */ }
  if (!res.ok || !body?.success) throw new LittleError(res.status, body?.message || `HTTP ${res.status}`);
  return body.data;
}

// Walks every page of a paginated endpoint, collecting the list found under `listKey`.
async function allPages(key: string, path: string, query: Record<string, string | number>, listKey: string) {
  const items: unknown[] = [];
  let first: any = null;
  for (let page = 1; page <= MAX_PAGES; page++) {
    const data = await little(key, path, { ...query, Page: page, PageSize: 100 });
    first ??= data;
    const list = data?.[listKey];
    if (Array.isArray(list)) items.push(...list);
    if (page >= (data?.Pagination?.TotalPages ?? 1)) break;
  }
  return { first, items };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = req.headers.get("apikey") || Deno.env.get("SUPABASE_ANON_KEY")!;
  const key = Deno.env.get("LITTLE_EVENTS_API_KEY");
  const slug = Deno.env.get("LITTLE_EVENTS_SLUG") || "tunerfest-2026";

  // Act as the signed-in caller, so the database's own admin rules decide who gets in.
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  const sb = createClient(url, anonKey, { auth: { persistSession: false }, global: { headers: { Authorization: authHeader } } });
  const { data: who } = await sb.auth.getUser(token);
  if (!who?.user) return json(401, { error: "not_signed_in" });
  const { data: isAdmin } = await sb.from("admins").select("user_id").eq("user_id", who.user.id).maybeSingle();
  if (!isAdmin) return json(403, { error: "not_admin" });

  if (!key) return json(503, { error: "not_configured" });

  try {
    const events: any[] = (await little(key, "/events")) || [];
    const event = events.find((e) => e.EventSlug === slug)
      || events.find((e) => /tuner\s*fest/i.test(e.EventName || ""));
    if (!event) {
      return json(404, { error: "event_not_found", slug, events: events.map((e) => ({ slug: e.EventSlug, name: e.EventName })) });
    }
    const range = { StartDate: SALES_FROM, EndDate: new Date().toISOString() };
    const sales = await allPages(key, `/sales/${event.EventID}`, range, "BreakdownByTicketType");
    const payments = await allPages(key, "/payments", { EventID: event.EventID, ...range }, "Payments");
    return json(200, {
      event: { id: event.EventID, slug: event.EventSlug, name: event.EventName },
      totalSales: sales.first?.TotalSales ?? null,
      totalRevenue: sales.first?.TotalRevenue ?? null,
      breakdown: sales.items,
      payments: payments.items,
      fetchedAt: new Date().toISOString(),
    });
  } catch (e) {
    const status = e instanceof LittleError ? e.status : 0;
    console.error("little events request failed", status, (e as Error).message);
    return json(502, { error: status === 401 || status === 403 ? "bad_key" : "little_failed", detail: (e as Error).message.slice(0, 200) });
  }
});

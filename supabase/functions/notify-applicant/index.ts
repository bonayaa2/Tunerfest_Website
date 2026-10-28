// Emails a show car or booth applicant when an admin approves or declines them.
// Called from the admin panel with { id }. Only signed-in admins may call it.
// Secrets (Supabase → Edge Functions → Secrets):
//   RESEND_API_KEY  – from resend.com, after verifying shiftnation.com there
//   FROM_EMAIL      – optional, defaults to "Shift Nation <info@shiftnation.com>"
// Runs as the signed-in admin who calls it; no service key is used.
import { createClient } from "npm:@supabase/supabase-js@2.58.0";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

const EVENT = "Sunday, November 29, 2026 at Galleria Mall, Karen, Nairobi";

type Reg = { id: string; type: "car" | "booth"; status: string; name: string; email: string; car: string | null; business: string | null; booth_size: string | null };

function compose(r: Reg) {
  const first = (r.name || "").trim().split(/\s+/)[0] || "there";
  const what = r.type === "car" ? (r.car || "your car") : (r.business || "your business");
  const approved = r.status === "approved";
  let subject: string, lines: string[];
  if (r.type === "car" && approved) {
    subject = "You're in: your car is on the floor at Tuner Fest 6.0";
    lines = [
      `Great news. ${what} has been approved as a show car at Tuner Fest 6.0, ${EVENT}.`,
      "There are only 70 show car spots, and yours is confirmed.",
      "We'll send your roll-in time and entry details closer to the day. Keep your car insured and show-ready.",
    ];
  } else if (r.type === "car") {
    subject = "Your Tuner Fest 6.0 show car application";
    lines = [
      `Thank you for applying to show ${what} at Tuner Fest 6.0.`,
      "We had far more applications than our 70 show car spots, and we couldn't fit your car in this time.",
      "We'd still love to see you there. Tickets are on sale at shiftnation.org.",
    ];
  } else if (approved) {
    subject = "Your Tuner Fest 6.0 booth request is approved";
    lines = [
      `Good news. Your booth request for ${what} at Tuner Fest 6.0 (${EVENT}) has been approved.`,
      "We'll be in touch shortly with pricing, payment and setup details.",
    ];
  } else {
    subject = "Your Tuner Fest 6.0 booth request";
    lines = [
      `Thank you for your booth request for ${what} at Tuner Fest 6.0.`,
      "We aren't able to offer you a booth this time.",
      "We'd still love to see you at the show. Tickets are on sale at shiftnation.org.",
    ];
  }
  const text = [`Hi ${first},`, "", ...lines, "", "Shift Nation", "info@shiftnation.com · shiftnation.org"].join("\n");
  const html = `<!doctype html><html><body style="margin:0;background:#f4f4f6;font-family:Arial,Helvetica,sans-serif;color:#1a1a1f">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px;overflow:hidden">
<tr><td style="background:#07080c;padding:22px 28px;color:#f5b41f;font-weight:bold;letter-spacing:2px;font-size:13px;text-transform:uppercase">Shift Nation · Tuner Fest 6.0</td></tr>
<tr><td style="padding:28px">
<h1 style="margin:0 0 18px;font-size:22px;line-height:1.3">${esc(subject)}</h1>
<p style="margin:0 0 14px;font-size:15px;line-height:1.6">Hi ${esc(first)},</p>
${lines.map((l) => `<p style="margin:0 0 14px;font-size:15px;line-height:1.6">${esc(l)}</p>`).join("")}
<p style="margin:22px 0 0;font-size:15px;line-height:1.6">Shift Nation<br><a href="mailto:info@shiftnation.com" style="color:#1a1a1f">info@shiftnation.com</a> · <a href="https://shiftnation.org" style="color:#1a1a1f">shiftnation.org</a></p>
</td></tr></table></td></tr></table></body></html>`;
  return { subject, text, html };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const url = Deno.env.get("SUPABASE_URL")!;
  // the site's public (publishable) key, as sent by the browser; falls back to the built-in anon key
  const anonKey = req.headers.get("apikey") || Deno.env.get("SUPABASE_ANON_KEY")!;
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("FROM_EMAIL") || "Shift Nation <info@shiftnation.com>";

  // Act as the signed-in caller, so the database's own admin rules decide what they can read and change.
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  const admin = createClient(url, anonKey, { auth: { persistSession: false }, global: { headers: { Authorization: authHeader } } });
  const { data: who, error: whoErr } = await admin.auth.getUser(token);
  if (!who?.user) { console.error("getUser failed", whoErr?.message); return json(401, { error: "not_signed_in" }); }
  const { data: isAdmin, error: adminErr } = await admin.from("admins").select("user_id").eq("user_id", who.user.id).maybeSingle();
  if (adminErr) console.error("admin check failed", adminErr.message);
  if (!isAdmin) return json(403, { error: "not_admin" });

  let id: string | undefined;
  try { id = (await req.json()).id; } catch { /* handled below */ }
  if (!id || typeof id !== "string") return json(400, { error: "missing_id" });

  const { data: r, error } = await admin.from("registrations")
    .select("id,type,status,name,email,car,business,booth_size").eq("id", id).maybeSingle();
  if (error || !r) { if (error) console.error("load failed", error.message); return json(404, { error: "not_found" }); }
  if (r.status !== "approved" && r.status !== "declined") return json(409, { error: "not_reviewed" });
  if (!resendKey) return json(503, { error: "email_not_configured" });

  const msg = compose(r as Reg);
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [r.email], reply_to: "info@shiftnation.com", subject: msg.subject, html: msg.html, text: msg.text }),
  });
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 400);
    await admin.from("registrations").update({ email_error: `${res.status}: ${detail}` }).eq("id", id);
    return json(502, { error: "send_failed", detail });
  }
  await admin.from("registrations").update({ emailed_status: r.status, emailed_at: new Date().toISOString(), email_error: null }).eq("id", id);
  return json(200, { ok: true, to: r.email, status: r.status });
});

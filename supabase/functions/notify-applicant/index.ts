// Emails a show car or booth applicant when an admin approves or declines them.
// Called from the admin panel with { id }. Only signed-in admins may call it.
// With { id, kind: "pass" } it sends only the driver pass of an approved show car.
// Secrets (Supabase → Edge Functions → Secrets):
//   RESEND_API_KEY  – from resend.com, after verifying shiftnation.org there
//   FROM_EMAIL      – optional, defaults to "Shift Nation <info@shiftnation.org>"
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
const SITE = "https://www.shiftnation.org";

type Reg = { id: string; type: "car" | "booth"; status: string; name: string; email: string; car: string | null; business: string | null; booth_size: string | null };

const shell = (subject: string, inner: string) => `<!doctype html><html><body style="margin:0;background:#f4f4f6;font-family:Arial,Helvetica,sans-serif;color:#1a1a1f">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px;overflow:hidden">
<tr><td style="background:#07080c;padding:22px 28px;color:#f5b41f;font-weight:bold;letter-spacing:2px;font-size:13px;text-transform:uppercase">Shift Nation · Tuner Fest 6.0</td></tr>
<tr><td style="padding:28px">
<h1 style="margin:0 0 18px;font-size:22px;line-height:1.3">${esc(subject)}</h1>
${inner}
<p style="margin:22px 0 0;font-size:15px;line-height:1.6">Shift Nation<br><a href="mailto:info@shiftnation.org" style="color:#1a1a1f">info@shiftnation.org</a> · <a href="https://shiftnation.org" style="color:#1a1a1f">shiftnation.org</a></p>
</td></tr></table></td></tr></table></body></html>`;
const para = (t: string) => `<p style="margin:0 0 14px;font-size:15px;line-height:1.6">${esc(t)}</p>`;
const passButton = (passUrl: string, passCode: string) =>
  `<p style="margin:0 0 18px"><a href="${esc(passUrl)}" style="display:inline-block;background:#f5b41f;color:#07080c;font-weight:bold;text-decoration:none;padding:12px 22px;border-radius:8px;letter-spacing:1px;text-transform:uppercase;font-size:13px">Open your driver pass</a></p>
<p style="margin:0 0 14px;font-size:13px;line-height:1.6;color:#6b6f7c">Pass code ${esc(passCode)} · or open ${esc(passUrl)}</p>`;

// Just the driver pass, for show cars approved before passes existed (or a lost email).
function composePass(r: Reg, passCode: string) {
  const first = (r.name || "").trim().split(/\s+/)[0] || "there";
  const passUrl = `${SITE}/#pass-${passCode}`;
  const subject = "Your Tuner Fest 6.0 driver pass";
  const lines = [
    `Here is the driver pass for ${r.car || "your show car"} at Tuner Fest 6.0, ${EVENT}.`,
    "Show its QR code at the show car entrance. The pass works once and admits the driver.",
    "Take a screenshot so you have it even without signal, and don't share it.",
  ];
  const text = [`Hi ${first},`, "", ...lines, "", `Your pass: ${passUrl}`, `Pass code: ${passCode}`, "", "Shift Nation", "info@shiftnation.org · shiftnation.org"].join("\n");
  const html = shell(subject, para(`Hi ${first},`) + lines.map(para).join("") + passButton(passUrl, passCode));
  return { subject, text, html };
}

function compose(r: Reg, passCode: string | null) {
  const first = (r.name || "").trim().split(/\s+/)[0] || "there";
  const what = r.type === "car" ? (r.car || "your car") : (r.business || "your business");
  const approved = r.status === "approved";
  let subject: string, lines: string[];
  const passUrl = passCode ? `${SITE}/#pass-${passCode}` : null;
  if (r.type === "car" && approved) {
    subject = "You're in: your car is on the floor at Tuner Fest 6.0";
    lines = [
      `Great news. ${what} has been approved as a show car at Tuner Fest 6.0, ${EVENT}.`,
      "There are only 130 show car spots, and yours is confirmed.",
      ...(passUrl ? [`Your driver pass is ready. Open it here and show the QR code at the show car entrance: ${passUrl}`,
        "The pass works once and admits the driver. Take a screenshot so you have it even without signal."] : []),
      "We'll send your roll-in time and entry details closer to the day. Keep your car insured and show-ready.",
    ];
  } else if (r.type === "car") {
    subject = "Your Tuner Fest 6.0 show car application";
    lines = [
      `Thank you for applying to show ${what} at Tuner Fest 6.0.`,
      "We had far more applications than our 130 show car spots, and we couldn't fit your car in this time.",
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
  const text = [`Hi ${first},`, "", ...lines, "", "Shift Nation", "info@shiftnation.org · shiftnation.org"].join("\n");
  const html = shell(subject, para(`Hi ${first},`) + lines.map((l) => passUrl && passCode && l.includes(passUrl)
    ? para("Your driver pass is ready. Show its QR code at the show car entrance.") + passButton(passUrl, passCode)
    : para(l)).join(""));
  return { subject, text, html };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const url = Deno.env.get("SUPABASE_URL")!;
  // the site's public (publishable) key, as sent by the browser; falls back to the built-in anon key
  const anonKey = req.headers.get("apikey") || Deno.env.get("SUPABASE_ANON_KEY")!;
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("FROM_EMAIL") || "Shift Nation <info@shiftnation.org>";

  // Act as the signed-in caller, so the database's own admin rules decide what they can read and change.
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  const admin = createClient(url, anonKey, { auth: { persistSession: false }, global: { headers: { Authorization: authHeader } } });
  const { data: who, error: whoErr } = await admin.auth.getUser(token);
  if (!who?.user) { console.error("getUser failed", whoErr?.message); return json(401, { error: "not_signed_in" }); }
  const { data: isAdmin, error: adminErr } = await admin.from("admins").select("user_id").eq("user_id", who.user.id).maybeSingle();
  if (adminErr) console.error("admin check failed", adminErr.message);
  if (!isAdmin) return json(403, { error: "not_admin" });

  let id: string | undefined, kind: string | undefined;
  try { ({ id, kind } = await req.json()); } catch { /* handled below */ }
  if (!id || typeof id !== "string") return json(400, { error: "missing_id" });

  const { data: r, error } = await admin.from("registrations")
    .select("id,type,status,name,email,car,business,booth_size").eq("id", id).maybeSingle();
  if (error || !r) { if (error) console.error("load failed", error.message); return json(404, { error: "not_found" }); }
  if (r.status !== "approved" && r.status !== "declined") return json(409, { error: "not_reviewed" });
  if (!resendKey) return json(503, { error: "email_not_configured" });

  // approved show cars get their driver pass link (the pass is created by the database when the car is approved)
  let passCode: string | null = null;
  if (r.type === "car" && r.status === "approved") {
    const { data: t } = await admin.from("driver_tickets").select("code").eq("registration_id", id).eq("revoked", false).maybeSingle();
    passCode = t?.code ?? null;
  }
  if (kind === "pass" && !passCode) return json(409, { error: "no_pass" });
  const msg = kind === "pass" ? composePass(r as Reg, passCode!) : compose(r as Reg, passCode);
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [r.email], reply_to: "info@shiftnation.org", subject: msg.subject, html: msg.html, text: msg.text }),
  });
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 400);
    if (kind !== "pass") await admin.from("registrations").update({ email_error: `${res.status}: ${detail}` }).eq("id", id);
    return json(502, { error: "send_failed", detail });
  }
  const now = new Date().toISOString();
  if (passCode) await admin.from("driver_tickets").update({ emailed_at: now }).eq("registration_id", id);
  if (kind === "pass") return json(200, { ok: true, to: r.email, pass: passCode, emailed_at: now });
  await admin.from("registrations").update({ emailed_status: r.status, emailed_at: now, email_error: null }).eq("id", id);
  return json(200, { ok: true, to: r.email, status: r.status });
});

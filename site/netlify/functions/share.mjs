// GET /p/<poll> — a short link for X and Telegram. Crawlers read the live card; people are sent to the poll page.
import { verdict } from "../../lib/verdict.js";
import { getPoll, pollCount } from "./api.mjs";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]).replace(/[\u0000-\u001f‪-‮⁦-⁩]/g, " ");
const STATUS = { gathering: "Gathering votes", leaning: "Leaning", clear_lead: "Clear lead", too_close: "Too close to call", final: "The crowd's answer", tie: "A tie", no_quorum: "No quorum" };

export default async (req) => {
  const url = new URL(req.url);
  const m = /^\/p\/(\d{1,9})\/?$/.exec(url.pathname);
  if (!m) return Response.redirect(url.origin + "/", 302);
  const id = Number(m[1]), target = `${url.origin}/#/poll/${id}`;
  let title = `Poll #${id} · Show of Hands`, desc = "One Agent ID, one voice. Vote on BNB Chain.", image = `${url.origin}/assets/ink-hands.webp`;
  try {
    if (id < (await pollCount())) {
      const p = await getPoll(id), v = verdict(p);
      const lead = v.leading ? `${v.leading.text_UNTRUSTED} (${Math.round(v.leading.share * 100)}%)` : "";
      title = p.question;
      desc = `${STATUS[v.status] || ""}${lead && (v.status === "final" || v.status === "clear_lead" || v.status === "leaning") ? ": " + lead : ""} · ${p.totalVotes} verified ${p.totalVotes === 1 ? "voter" : "voters"}, one per Agent ID. ${v.open ? "Vote with your Agent ID." : "Closed."}`;
      image = `${url.origin}/api/card/${id}.png?v=${p.totalVotes}-${v.status}`;
    }
  } catch {}
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} · Show of Hands</title>
<meta name="description" content="${esc(desc)}">
<meta property="og:type" content="website"><meta property="og:site_name" content="Show of Hands · 举手">
<meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${esc(url.origin + url.pathname)}">
<meta property="og:image" content="${esc(image)}"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(desc)}"><meta name="twitter:image" content="${esc(image)}">
<meta http-equiv="refresh" content="0; url=${esc(target)}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>body{font:16px/1.5 system-ui,sans-serif;background:#f2ebdc;color:#191613;display:grid;place-items:center;min-height:100vh;margin:0}a{color:#c4351e}</style>
</head><body><p>Opening the poll… <a href="${esc(target)}">Continue</a></p>
<script>location.replace(${JSON.stringify(target)})</script></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=30", "netlify-cdn-cache-control": "public, s-maxage=30, stale-while-revalidate=120" } });
};

export const config = { path: "/p/*" };

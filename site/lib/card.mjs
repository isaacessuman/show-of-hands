// Builds the 1200x630 "share card" SVG for one poll, in the Ink & Seal style. Pure function, no network.
// Poll text is untrusted user input: it is escaped and only ever drawn as text.
import { verdict } from "./verdict.js";

const W = 1200, H = 630, PAD = 72;
const C = { paper: "#f2ebdc", paper2: "#e8dfcc", ink: "#191613", muted: "#6f675d", line: "#d8cdb6", seal: "#c4351e", track: "#e2d8c3" };
const isCJK = (ch) => /[⺀-鿿豈-﫿＀-￯　-〿]/.test(ch);
const esc = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const clean = (s) => String(s ?? "").replace(/[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, " ").replace(/\s+/g, " ").trim();

/** The renderer uses one font per text line, so any line with Chinese is drawn in the CJK font (which has Latin too). */
function runs(s, latin) {
  return `<tspan font-family="${[...s].some(isCJK) ? "SOH CJK" : latin}">${esc(s)}</tspan>`;
}
// rough advance widths in em, good enough for wrapping
const width = (s, latinEm) => [...s].reduce((w, ch) => w + (isCJK(ch) ? 1.02 : ch === " " ? 0.26 : /[mwMW]/.test(ch) ? 0.78 : /[A-Z]/.test(ch) ? 0.62 : /[iljtf.,'!:;|]/.test(ch) ? 0.3 : latinEm), 0);

function wrap(text, size, maxW, maxLines) {
  const tokens = text.match(/[⺀-鿿豈-﫿＀-￯　-〿]|[^\s⺀-鿿豈-﫿＀-￯　-〿]+|\s+/g) || [];
  const lines = []; let line = "";
  for (const t of tokens) {
    const next = line + t;
    if (width(next, [...next].some(isCJK) ? 0.58 : 0.5) * size <= maxW * 0.97 || !line.trim()) line = next;
    else { lines.push(line.trim()); line = t.trimStart(); }
  }
  if (line.trim()) lines.push(line.trim());
  if (lines.length > maxLines) {
    const kept = lines.slice(0, maxLines);
    let last = kept[maxLines - 1];
    while (last.length && width(last + "…", 0.5) * size > maxW) last = [...last].slice(0, -1).join("");
    kept[maxLines - 1] = last.trimEnd() + "…";
    return kept;
  }
  return lines;
}

const L = {
  en: { brand: "ONE AGENT ID · ONE VOICE", live: "LIVE", closed: "CLOSED", voters: (n) => `${n} verified ${n === 1 ? "voter" : "voters"} · one per Agent ID`, more: (n) => `+${n} more`,
    status: { gathering: "Gathering votes", leaning: "Leaning", clear_lead: "Clear lead", too_close: "Too close to call", final: "The crowd's answer", tie: "A tie", no_quorum: "No quorum" },
    left: (s) => s > 86400 ? `${Math.ceil(s / 86400)}d left` : s > 3600 ? `${Math.ceil(s / 3600)}h left` : `${Math.max(1, Math.ceil(s / 60))}m left` },
  zh: { brand: "一个 AGENT ID · 一票", live: "进行中", closed: "已结束", voters: (n) => `${n} 位已验证投票者 · 每个 Agent ID 一票`, more: (n) => `另有 ${n} 项`,
    status: { gathering: "正在收集投票", leaning: "暂时领先", clear_lead: "明确领先", too_close: "难分高下", final: "众人的答案", tie: "平局", no_quorum: "人数不足" },
    left: (s) => s > 86400 ? `剩 ${Math.ceil(s / 86400)} 天` : s > 3600 ? `剩 ${Math.ceil(s / 3600)} 小时` : `剩 ${Math.max(1, Math.ceil(s / 60))} 分钟` },
};

export function cardSvg(poll, { host = "showofhands.io", nowSec = Math.floor(Date.now() / 1000), lang } = {}) {
  const q = clean(poll.question) || "Untitled poll";
  const lg = lang || ([...q].some(isCJK) ? "zh" : "en");
  const T = L[lg];
  const v = verdict(poll, { nowSec });
  const n = Number(poll.totalVotes);
  const opts = poll.options.map((o, i) => ({ label: clean(o), votes: Number(poll.tallies[i] || 0), i }));
  const leaderIdx = v.leading ? v.leading.index : (n ? opts.reduce((a, b) => (b.votes > a.votes ? b : a)).i : -1);
  const decided = v.status === "final" || v.status === "clear_lead";
  const winner = decided ? opts[leaderIdx] : null;

  const parts = [];
  // paper, soft ink wash and border
  parts.push(`<rect width="${W}" height="${H}" fill="${C.paper}"/>`);
  parts.push(`<radialGradient id="wash" cx="88%" cy="18%" r="60%"><stop offset="0" stop-color="${C.ink}" stop-opacity=".10"/><stop offset=".6" stop-color="${C.ink}" stop-opacity=".03"/><stop offset="1" stop-color="${C.ink}" stop-opacity="0"/></radialGradient>`);
  parts.push(`<rect width="${W}" height="${H}" fill="url(#wash)"/>`);
  parts.push(`<rect x="22" y="22" width="${W - 44}" height="${H - 44}" fill="none" stroke="${C.line}" stroke-width="2"/>`);
  // seal + brand
  parts.push(`<g transform="translate(${PAD},${PAD - 14})"><rect width="76" height="76" rx="6" fill="${C.seal}"/><text x="38" y="35" text-anchor="middle" font-family="SOH CJK" font-size="30" fill="#fbf3e4">举</text><text x="38" y="67" text-anchor="middle" font-family="SOH CJK" font-size="30" fill="#fbf3e4">手</text></g>`);
  parts.push(`<text x="${PAD + 96}" y="${PAD + 18}" font-family="SOH Serif" font-size="34" fill="${C.ink}">Show of Hands</text>`);
  parts.push(`<text x="${PAD + 97}" y="${PAD + 48}" font-size="15" letter-spacing="3" fill="${C.muted}">${runs(T.brand, "SOH Sans Bold")}</text>`);
  // live / closed pill
  const pill = v.open ? `${T.live} · ${T.left(Number(poll.endsAt) - nowSec)}` : T.closed;
  const pw = Math.round(width(pill, 0.62) * 17 + [...pill].length * 1.5 + 48);
  parts.push(`<g transform="translate(${W - PAD - pw},${PAD - 6})"><rect width="${pw}" height="40" rx="20" fill="none" stroke="${v.open ? C.seal : C.muted}" stroke-width="2"/>${v.open ? `<circle cx="22" cy="20" r="5" fill="${C.seal}"/>` : ""}<text x="${v.open ? 36 : 22}" y="26" font-size="17" letter-spacing="1.5" fill="${v.open ? C.seal : C.muted}">${runs(pill, "SOH Sans Bold")}</text></g>`);

  // question
  const maxQW = W - PAD * 2;
  let fs = 58, lines = wrap(q, fs, maxQW, 2);
  if (lines.length === 2 && lines[1].endsWith("…")) { fs = 46; lines = wrap(q, fs, maxQW, 3); }
  const lh = Math.round(fs * 1.16);
  let y = 214;
  lines.forEach((ln, i) => parts.push(`<text x="${PAD}" y="${y + i * lh}" font-size="${fs}" fill="${C.ink}">${runs(ln, "SOH Serif")}</text>`));
  y += (lines.length - 1) * lh + 58;
  const optTop = y;

  // options as ink bars
  const rowH = 54, maxRows = Math.max(1, Math.floor((540 - y) / rowH));
  const ordered = [...opts].sort((a, b) => b.votes - a.votes || a.i - b.i);
  const shown = ordered.slice(0, maxRows);
  const barW = winner ? 700 : W - PAD * 2;
  for (const o of shown) {
    const pct = n ? Math.round((o.votes / n) * 100) : 0, lead = o.i === leaderIdx && n > 0;
    const label = wrap(o.label || "—", 24, barW - 140, 1)[0];
    parts.push(`<text x="${PAD}" y="${y}" font-size="24" fill="${C.ink}">${runs(label, lead ? "SOH Sans Bold" : "SOH Sans")}</text>`);
    parts.push(`<text x="${PAD + barW}" y="${y}" text-anchor="end" font-size="22" fill="${lead ? C.seal : C.muted}">${runs(`${o.votes} · ${pct}%`, "SOH Sans Bold")}</text>`);
    parts.push(`<rect x="${PAD}" y="${y + 12}" width="${barW}" height="10" rx="5" fill="${C.track}"/>`);
    if (pct) parts.push(`<rect x="${PAD}" y="${y + 12}" width="${Math.max(10, Math.round((barW * pct) / 100))}" height="10" rx="5" fill="${lead ? C.seal : C.ink}" fill-opacity="${lead ? 1 : 0.55}"/>`);
    y += rowH;
  }

  // the chop: the crowd's answer
  if (winner) {
    const ans = wrap(winner.label, 34, 270, 2);
    parts.push(`<g transform="translate(${W - PAD - 170},${optTop + 52}) rotate(-6)">
      <rect x="-160" y="-92" width="320" height="${150 + (ans.length - 1) * 40}" rx="10" fill="none" stroke="${C.seal}" stroke-width="5"/>
      <rect x="-150" y="-82" width="300" height="${130 + (ans.length - 1) * 40}" rx="6" fill="none" stroke="${C.seal}" stroke-width="1.5"/>
      <text x="0" y="-46" text-anchor="middle" font-size="17" letter-spacing="2.5" fill="${C.seal}">${runs((v.status === "final" ? T.status.final : T.status.clear_lead).toUpperCase(), "SOH Sans Bold")}</text>
      ${ans.map((a, i) => `<text x="0" y="${2 + i * 40}" text-anchor="middle" font-size="36" fill="${C.seal}">${runs(a, "SOH Serif")}</text>`).join("")}
    </g>`);
  }

  // footer
  parts.push(`<line x1="${PAD}" y1="556" x2="${W - PAD}" y2="556" stroke="${C.line}" stroke-width="1.5"/>`);
  const st = (winner ? "" : ` · ${T.status[v.status] || ""}`) + (shown.length < ordered.length ? ` · ${T.more(ordered.length - shown.length)}` : "");
  parts.push(`<text x="${PAD}" y="592" font-size="20" fill="${C.muted}">${runs(T.voters(n) + st, "SOH Sans")}</text>`);
  parts.push(`<text x="${W - PAD}" y="592" text-anchor="end" font-size="20" fill="${C.ink}">${runs(`${host}/p/${poll.id}`, "SOH Sans Bold")}</text>`);

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${parts.join("")}</svg>`;
}

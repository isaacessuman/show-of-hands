// Show of Hands · live vote wall.
// Every vote lands as a drop of ink. Reads /api/events, /api/polls and /api/verdict.
// SECURITY: question/option text and handles are untrusted user input. They only ever reach
// the page through textContent (never innerHTML) and are never interpreted.
import qrcode from "./vendor/qrcode.js";

const Q = new URLSearchParams(location.search);
const LANG = Q.get("lang") === "zh" ? "zh" : "en";
const THEME = Q.get("theme") === "light" ? "light" : "dark";
const PIN = /^\d{1,9}$/.test(Q.get("poll") || "") ? Number(Q.get("poll")) : null;
const REDUCED = matchMedia("(prefers-reduced-motion: reduce)").matches;
const SHORT_HOST = "showofhands.io";
const POLL_MS = 4000, MAX_BACKOFF = 60000, REPLAY_MS = 3000, REPLAY_MAX = 200;
let demoOn = Q.get("demo") === "1";

const $ = (id) => document.getElementById(id);
const root = document.documentElement;
root.dataset.theme = THEME;
root.lang = LANG === "zh" ? "zh-CN" : "en";

/* ---------------- strings ---------------- */
const T = {
  en: {
    tagline: "live from BNB Smart Chain", connecting: "connecting…", live: "live", syncing: "syncing…",
    reconnecting: "reconnecting…", block: "block", votes: "votes", ids: "Agent IDs", polls: "polls",
    demoStamp: "DEMO · simulated votes", demoShort: "DEMO", featured: "Featured poll", verified: "verified voters", verified1: "verified voter",
    scan: "Scan to vote", oneId: "One Agent ID, one vote.", back: "← showofhands.io",
    hint: "F fullscreen · D demo · Esc exit", emptyBig: "Waiting for the first hand.",
    emptySub: "Every vote will land here as a drop of ink.", noPoll: "No polls yet.",
    voted: ["", " voted ‘", "’ · "], opened: " opened ", poll: (p) => `poll #${p}`,
    left: (d, h, m, s) => d ? `${d}d ${h}h left` : h ? `${h}h ${pad(m)}m left` : `${m}m ${pad(s)}s left`,
    closed: (st) => st === "no_quorum" ? "closed · no quorum" : st === "decided" ? "closed · decided"
      : st && st !== "closed" ? `closed · ${st.replace(/_/g, " ")}` : "closed",
  },
  zh: {
    tagline: "实时来自 BNB 智能链", connecting: "连接中…", live: "直播中", syncing: "同步中…",
    reconnecting: "重新连接中…", block: "区块", votes: "票数", ids: "Agent ID", polls: "投票",
    demoStamp: "演示 · 模拟投票", demoShort: "演示", featured: "当前投票", verified: "位已验证投票人",
    scan: "扫码投票", oneId: "一个 Agent ID，一票。", back: "← showofhands.io",
    hint: "F 全屏 · D 演示 · Esc 退出", emptyBig: "等待第一只手举起。",
    emptySub: "每一票都会化作一滴墨。", noPoll: "还没有投票。",
    voted: ["", " 投了「", "」· "], opened: " 发起了 ", poll: (p) => `第 ${p} 号投票`,
    left: (d, h, m, s) => d ? `剩余 ${d}天${h}小时` : h ? `剩余 ${h}小时${pad(m)}分` : `剩余 ${m}分${pad(s)}秒`,
    closed: (st) => st === "no_quorum" ? "已结束 · 未达法定人数" : st === "decided" ? "已结束 · 已有结果" : "已结束",
  },
}[LANG];
function pad(n) { return String(n).padStart(2, "0"); }
for (const el of document.querySelectorAll("[data-i18n]")) {
  const v = T[el.dataset.i18n];
  if (typeof v === "string") el.textContent = v;
}
if (LANG === "zh") document.title = "实时投票墙 · 举手 Show of Hands";

/* ---------------- untrusted text helpers ---------------- */
function clip(s, n) {
  // Strip control and bidi-override characters, then cap the length.
  const t = String(s ?? "").replace(/[\u0000-\u001f\u007f‎‏‪-‮⁦-⁩]/g, "").trim();
  return t.length > n ? t.slice(0, n - 1) + "…" : t;
}
function shortAddr(a) {
  const s = String(a || "");
  return /^0x[0-9a-fA-F]{40}$/.test(s) ? `${s.slice(0, 6)}…${s.slice(-4)}` : clip(s, 14) || "someone";
}
const whoOf = (ev) => clip(ev.handle, 32) || clip(ev.who, 32); // the API already shortens addresses
function span(cls, text) { const e = document.createElement("span"); if (cls) e.className = cls; e.textContent = text; return e; }

/* ---------------- textures (paper fibre + seal edge), like the main site ---------------- */
function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
function hash(str) { let h = 2166136261; for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
function mk(w, h) { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; }
function sealTex() {
  const c = mk(220, 220), x = c.getContext("2d"), r = rng(88);
  x.fillStyle = "#000"; x.fillRect(6, 6, 208, 208);
  x.globalCompositeOperation = "destination-out";
  for (let i = 0; i < 900; i++) { x.globalAlpha = r() * 0.55; x.beginPath(); x.arc(r() * 220, r() * 220, r() * 1.8, 0, 7); x.fill(); }
  for (let i = 0; i < 70; i++) {
    const e = Math.floor(r() * 4), p = r() * 220, rr = 1 + r() * 4; x.globalAlpha = 0.7 + r() * 0.3; x.beginPath();
    if (e === 0) x.arc(p, 6, rr, 0, 7); else if (e === 1) x.arc(p, 214, rr, 0, 7); else if (e === 2) x.arc(6, p, rr, 0, 7); else x.arc(214, p, rr, 0, 7);
    x.fill();
  }
  return c.toDataURL();
}
function fibreTex(k) {
  const s = 320, c = mk(s, s), x = c.getContext("2d"), r = rng(3), img = x.createImageData(s, s);
  for (let i = 0; i < img.data.length; i += 4) { const dark = r() < 0.5; img.data[i] = img.data[i + 1] = img.data[i + 2] = dark ? 60 : 255; img.data[i + 3] = r() < 0.5 ? r() * 14 * k : 0; }
  x.putImageData(img, 0, 0);
  for (let f = 0; f < 160; f++) {
    const sx = r() * s, sy = r() * s, len = 10 + r() * 40, ang = r() * Math.PI;
    x.strokeStyle = r() < 0.5 ? `rgba(90,70,40,${0.1 * k})` : `rgba(255,255,255,${0.12 * k})`; x.lineWidth = 0.4 + r() * 0.6;
    x.beginPath(); x.moveTo(sx, sy); x.quadraticCurveTo(sx + Math.cos(ang) * len * 0.5 + (r() - 0.5) * 8, sy + Math.sin(ang) * len * 0.5 + (r() - 0.5) * 8, sx + Math.cos(ang) * len, sy + Math.sin(ang) * len); x.stroke();
  }
  return c.toDataURL();
}
try {
  root.style.setProperty("--sealtex", `url(${sealTex()})`);
  root.style.setProperty("--fibre", `url(${fibreTex(THEME === "dark" ? 0.5 : 1)})`);
} catch { /* textures are decoration only */ }

/* ---------------- ink engine ---------------- */
const css = getComputedStyle(root);
const INK = css.getPropertyValue("--drop").trim() || "#EEE6D6";
const SEAL = css.getPropertyValue("--seal").trim() || "#D8452B";
const DENSITY = THEME === "dark" ? 0.62 : 0.9; // light ink on dark paper reads stronger, so thin it
const SPREAD_MS = 1700, SETTLE_MS = 5200, STAIN_A = 0.6, KEEP = 500;

function shapeFor(seed) {
  const r = rng(seed), N = 44, harm = [];
  for (let k = 2; k <= 6; k++) harm.push({ k, a: (0.16 / k) * (0.4 + r()), p: r() * 7 });
  const pts = [];
  for (let i = 0; i < N; i++) {
    const t = (i / N) * Math.PI * 2;
    let m = 1; for (const h of harm) m += h.a * Math.sin(h.k * t + h.p);
    pts.push(m + (r() - 0.5) * 0.06);
  }
  const splat = [], ns = 4 + Math.floor(r() * 6);
  for (let i = 0; i < ns; i++) splat.push({ ang: r() * 7, dist: 1.25 + r() * 1.3, size: 0.03 + r() * r() * 0.12, tail: r() < 0.35 });
  const sat = [], nsat = 1 + Math.floor(r() * 3);
  for (let i = 0; i < nsat; i++) sat.push({ ang: r() * 7, dist: 0.85 + r() * 0.35, size: 0.16 + r() * 0.2, rot: r() * 7 });
  return { pts, splat, sat, rot: r() * 7, s: 0.8 + r() * 0.45 };
}
function blobPath(x, cx, cy, rad, pts, rot) {
  const N = pts.length, P = (i) => { const j = ((i % N) + N) % N, a = rot + (j / N) * Math.PI * 2; return [cx + Math.cos(a) * rad * pts[j], cy + Math.sin(a) * rad * pts[j]]; };
  x.beginPath();
  let [px, py] = P(0), [qx, qy] = P(1);
  x.moveTo((px + qx) / 2, (py + qy) / 2);
  for (let i = 1; i <= N; i++) { [px, py] = P(i); [qx, qy] = P(i + 1); x.quadraticCurveTo(px, py, (px + qx) / 2, (py + qy) / 2); }
  x.closePath();
}
const HAS_FILTER = "filter" in CanvasRenderingContext2D.prototype;
const easeOut = (t) => 1 - Math.pow(1 - t, 3);

class InkWall {
  constructor(stain, wet) {
    this.cs = stain; this.cw = wet; this.xs = stain.getContext("2d"); this.xw = wet.getContext("2d");
    this.scenes = { real: [], demo: [] }; this.scene = "real"; this.wet = []; this.since = 0; this.raf = 0;
    this.resize();
  }
  resize() {
    const r = this.cs.getBoundingClientRect(), dpr = Math.min(2, window.devicePixelRatio || 1);
    this.W = Math.max(1, r.width); this.H = Math.max(1, r.height);
    for (const c of [this.cs, this.cw]) { c.width = Math.round(this.W * dpr); c.height = Math.round(this.H * dpr); }
    for (const x of [this.xs, this.xw]) x.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.R = Math.max(16, Math.min(84, Math.min(this.W, this.H) * 0.055));
    this.redraw();
  }
  place(list) {
    // Best of a few random candidates: the one farthest from recent drops (keeps the wall evenly inked).
    const recent = list.slice(-40); let best = null, bd = -1;
    for (let i = 0; i < 10; i++) {
      const narrow = this.W < 560, y0 = narrow ? 0.34 : 0.2, y1 = narrow ? 0.62 : 0.7;
      const c = { x: 0.07 + Math.random() * 0.86, y: y0 + Math.random() * (y1 - y0) };
      let d = 9; for (const p of recent) d = Math.min(d, Math.hypot((p.x - c.x) * this.W, (p.y - c.y) * this.H));
      if (d > bd) { bd = d; best = c; }
    }
    return best;
  }
  add(scene, seedStr, isSeal, instant) {
    const list = this.scenes[scene], at = this.place(list);
    const d = { ...at, seal: isSeal, shape: shapeFor(hash(seedStr)) };
    list.push(d); if (list.length > KEEP) list.shift();
    if (scene !== this.scene) return;
    if (instant || REDUCED) { this.draw(this.xs, d, 1, STAIN_A); if (++this.since >= 30) this.redraw(); return; }
    this.wet.push({ d, t0: performance.now() });
    if (!this.raf) this.raf = requestAnimationFrame((t) => this.frame(t));
  }
  setScene(s) { this.scene = s; this.wet = []; this.xw.clearRect(0, 0, this.W, this.H); this.redraw(); }
  redraw() {
    this.since = 0; this.xs.clearRect(0, 0, this.W, this.H);
    const list = this.scenes[this.scene], n = list.length;
    // Older stains fade so the wall never saturates.
    list.forEach((d, i) => this.draw(this.xs, d, 1, STAIN_A * Math.max(0.2, 1 - (n - 1 - i) / 240)));
  }
  frame(now) {
    this.raf = 0; const x = this.xw; x.clearRect(0, 0, this.W, this.H);
    const keep = [];
    for (const w of this.wet) {
      const age = now - w.t0;
      if (age >= SETTLE_MS) { this.draw(this.xs, w.d, 1, STAIN_A); if (++this.since >= 30) this.redraw(); continue; }
      const p = Math.min(1, age / SPREAD_MS), settle = Math.max(0, (age - SPREAD_MS) / (SETTLE_MS - SPREAD_MS));
      const a = 1 - (1 - STAIN_A) * settle; // wet and dark, drying to a stain
      this.draw(x, w.d, p, a);
      if (age < 600) { // impact ring
        const t = age / 600, cx = w.d.x * this.W, cy = w.d.y * this.H;
        x.globalAlpha = (1 - t) * 0.35 * DENSITY; x.strokeStyle = w.d.seal ? SEAL : INK; x.lineWidth = 1.2;
        x.beginPath(); x.arc(cx, cy, this.R * w.d.shape.s * (0.4 + t * 1.6), 0, 7); x.stroke();
      }
      keep.push(w);
    }
    this.wet = keep; x.globalAlpha = 1;
    if (keep.length) this.raf = requestAnimationFrame((t) => this.frame(t));
  }
  draw(x, d, p, alpha) {
    const sh = d.shape, cx = d.x * this.W, cy = d.y * this.H, R = this.R * sh.s, A = alpha * DENSITY;
    const r = R * (0.12 + 0.88 * easeOut(p));
    x.fillStyle = d.seal ? SEAL : INK; x.strokeStyle = x.fillStyle;
    const k = d.seal ? 1.15 : 1;
    // bleed halo
    if (HAS_FILTER) x.filter = `blur(${Math.max(1, R * 0.09).toFixed(1)}px)`;
    x.globalAlpha = A * 0.2 * k; blobPath(x, cx, cy, r * 1.22, sh.pts, sh.rot + 0.3); x.fill();
    if (HAS_FILTER) x.filter = "none";
    // body
    x.globalAlpha = A * 0.5 * k; blobPath(x, cx, cy, r, sh.pts, sh.rot); x.fill();
    // inner pooling, slightly off-centre
    x.globalAlpha = A * 0.22 * k; blobPath(x, cx + R * 0.06, cy - R * 0.05, r * 0.66, sh.pts, sh.rot + 1.1); x.fill();
    // dried rim
    x.globalAlpha = A * 0.2 * k; x.lineWidth = Math.max(0.8, R * 0.03); blobPath(x, cx, cy, r * 0.985, sh.pts, sh.rot); x.stroke();
    // satellite lobes
    for (const s of sh.sat) {
      const sr = r * s.size, sx = cx + Math.cos(s.ang) * r * s.dist, sy = cy + Math.sin(s.ang) * r * s.dist;
      x.globalAlpha = A * 0.48 * k; blobPath(x, sx, sy, sr, sh.pts, s.rot); x.fill();
    }
    // splatter
    if (p > 0.04) {
      const fly = Math.min(1, p * 1.7);
      for (const s of sh.splat) {
        const dist = R * (0.9 + (s.dist - 0.9) * easeOut(fly)), sx = cx + Math.cos(s.ang) * dist, sy = cy + Math.sin(s.ang) * dist;
        const sr = Math.max(0.8, R * s.size);
        x.globalAlpha = A * 0.7 * k; x.beginPath(); x.arc(sx, sy, sr, 0, 7); x.fill();
        if (s.tail) {
          x.globalAlpha = A * 0.35 * k; x.lineWidth = sr * 0.8; x.lineCap = "round"; x.beginPath();
          x.moveTo(sx, sy); x.lineTo(cx + Math.cos(s.ang) * (dist - R * 0.28), cy + Math.sin(s.ang) * (dist - R * 0.28)); x.stroke();
        }
      }
    }
    x.globalAlpha = 1;
  }
}
const ink = new InkWall($("stain"), $("wet"));
let rz = 0;
new ResizeObserver(() => { cancelAnimationFrame(rz); rz = requestAnimationFrame(() => ink.resize()); }).observe($("stain"));

/* ---------------- state ---------------- */
function newState() { return { votes: 0, ids: new Set(), polls: new Set(), pollCount: 0, firstSeen: new Set(), ticker: [] }; }
const real = newState(), demo = newState();
const cur = () => (demoOn ? demo : real);
const shown = {};

function setCounter(id, n) {
  const el = $(id); if (shown[id] === n) return; const bump = shown[id] !== undefined && n > shown[id];
  shown[id] = n; el.textContent = n.toLocaleString(LANG === "zh" ? "zh-CN" : "en-US");
  if (bump && !REDUCED) { el.classList.add("bump"); requestAnimationFrame(() => requestAnimationFrame(() => el.classList.remove("bump"))); }
}
function renderCounters() {
  const s = cur();
  setCounter("cVotes", s.votes); setCounter("cIds", s.ids.size); setCounter("cPolls", Math.max(s.polls.size, s.pollCount));
  $("empty").hidden = !(s.votes === 0 && s.ticker.length === 0 && (demoOn || loaded));
}

/* ---------------- ticker ---------------- */
function tickerItem(t) {
  const li = document.createElement("li");
  if (t.kind === "vote") {
    if (t.first) li.className = "first";
    li.append(span("who", t.who), T.voted[1], span("opt", t.opt), T.voted[2], span("pn", T.poll(t.poll)));
  } else {
    li.className = "sys";
    li.append(span("who", t.who), T.opened, span("pn", T.poll(t.poll)));
  }
  return li;
}
function renderTicker(animateLast) {
  const ol = $("ticker"), items = cur().ticker.slice(-6);
  ol.replaceChildren(...items.map(tickerItem));
  const lis = [...ol.children], n = lis.length;
  lis.forEach((li, i) => { li.style.opacity = String(Math.max(0.14, 1 - (n - 1 - i) * 0.17)); });
  if (animateLast && n && !REDUCED) lis[n - 1].classList.add("write");
}
function pushTicker(st, t) { st.ticker.push(t); if (st.ticker.length > 12) st.ticker.shift(); }

/* ---------------- events -> wall ---------------- */
function applyEvent(st, scene, ev, { instant = false, caption = true } = {}) {
  const visible = (scene === "demo") === demoOn;
  if (ev.type === "poll") {
    st.polls.add(String(ev.poll));
    if (caption) pushTicker(st, { kind: "poll", who: whoOf(ev), poll: ev.poll });
  } else if (ev.type === "vote") {
    st.votes++; st.ids.add(String(ev.who || "").toLowerCase()); st.polls.add(String(ev.poll));
    const first = !st.firstSeen.has(String(ev.poll)); st.firstSeen.add(String(ev.poll));
    ink.add(scene, `${ev.tx}:${ev.who}:${ev.poll}`, first, instant);
    if (caption) pushTicker(st, { kind: "vote", first, who: whoOf(ev), opt: clip(ev.optionText_UNTRUSTED, 48) || `#${ev.option}`, poll: ev.poll });
  } else return;
  if (visible) { renderCounters(); if (caption) renderTicker(!instant); }
}

/* ---------------- status ---------------- */
function setStatus(kind, head) {
  const el = $("status"); el.classList.toggle("live", kind === "live" || kind === "syncing"); el.classList.toggle("down", kind === "down");
  $("statusText").textContent = kind === "live" ? T.live : kind === "syncing" ? T.syncing : kind === "down" ? T.reconnecting : T.connecting;
  if (head) { $("blockWrap").hidden = false; $("block").textContent = Number(head).toLocaleString("en-US"); }
}

/* ---------------- live data ---------------- */
async function getJSON(url) {
  const ctl = new AbortController(), to = setTimeout(() => ctl.abort(), 10000);
  try { const r = await fetch(url, { cache: "no-store", signal: ctl.signal }); if (!r.ok) throw new Error(`HTTP ${r.status}`); return await r.json(); }
  finally { clearTimeout(to); }
}
const seen = new Set();
const keyOf = (e) => `${e.type}:${e.tx}:${e.poll}:${e.who}:${e.block}`;
let since = 0, backoff = POLL_MS, loaded = false;

async function fetchSince(from, pages) {
  const out = []; let s = from, head = 0, syncing = false;
  for (let i = 0; i < pages; i++) {
    const d = await getJSON(`/api/events?since=${s}&limit=200`);
    head = d.head || head; syncing = !!d.syncing;
    const evs = Array.isArray(d.events) ? d.events : [];
    for (const e of evs) { const k = keyOf(e); if (!seen.has(k)) { seen.add(k); out.push(e); } }
    if (evs.length < 200) break;
    const last = Number(evs[evs.length - 1].block) || s;
    s = last - 1 > s ? last - 1 : last; // since is exclusive; step back one block so a split block is not lost (deduped)
  }
  for (const e of out) since = Math.max(since, Number(e.block) || 0);
  return { out, head, syncing };
}

async function boot() {
  try {
    const { out, head, syncing } = await fetchSince(0, 25);
    setStatus(syncing ? "syncing" : "live", head); backoff = POLL_MS;
    replay(out);
  } catch {
    setStatus("down"); backoff = Math.min(MAX_BACKOFF, backoff * 2);
    setTimeout(boot, backoff);
  }
}
function replay(events) {
  const cut = Math.max(0, events.length - REPLAY_MAX);
  // Older history goes straight to the stain layer; the recent tail is replayed, staggered over ~3 s.
  events.slice(0, cut).forEach((e) => applyEvent(real, "real", e, { instant: true, caption: false }));
  const tail = events.slice(cut), step = tail.length ? REPLAY_MS / tail.length : 0;
  tail.forEach((e, i) => setTimeout(() => applyEvent(real, "real", e), REDUCED ? 0 : Math.min(600, step) * i));
  const done = REDUCED ? 0 : Math.min(600, step) * tail.length;
  setTimeout(() => { loaded = true; renderCounters(); setTimeout(tick, POLL_MS); }, done + 50);
}
async function tick() {
  try {
    const { out, head, syncing } = await fetchSince(since, 5);
    setStatus(syncing ? "syncing" : "live", head); backoff = POLL_MS;
    let touch = false;
    for (const e of out) { applyEvent(real, "real", e); if (e.type === "poll" || (featured && String(e.poll) === String(featured.id))) touch = true; }
    if (touch) refreshFeaturedSoon();
  } catch {
    setStatus("down"); backoff = Math.min(MAX_BACKOFF, backoff * 2);
  }
  setTimeout(tick, backoff);
}

/* ---------------- featured poll ---------------- */
let featured = null, ffTimer = 0;
function refreshFeaturedSoon() { clearTimeout(ffTimer); ffTimer = setTimeout(refreshFeatured, 700); }
async function refreshFeatured() {
  try {
    let id = PIN;
    if (id === null || !real.pollCount) {
      const p = await getJSON("/api/polls?limit=20");
      real.pollCount = Number(p.count) || 0; if (!demoOn) renderCounters();
      if (id === null) {
        const list = (Array.isArray(p.polls) ? p.polls : []).filter((x) => Number.isInteger(x.poll));
        const open = list.filter((x) => x.open), pick = (a) => a.reduce((m, x) => (m === null || x.poll > m.poll ? x : m), null);
        const best = pick(open) || pick(list);
        id = best ? best.poll : null;
      }
    }
    if (id === null) { featured = null; if (!demoOn) renderPanel(null); return; }
    const v = await getJSON(`/api/verdict?poll=${id}`);
    featured = {
      id, demo: false, question: v.question_UNTRUSTED,
      options: (Array.isArray(v.options_UNTRUSTED) ? v.options_UNTRUSTED : []).map((o) => ({ text: o.text, votes: Number(o.votes) || 0 })),
      voters: Number(v.verifiedVoters) || 0, open: !!v.open, endsAt: Date.parse(v.endsAt) || 0, status: v.status,
      link: `${SHORT_HOST}/p/${id}`, qr: `https://${SHORT_HOST}/p/${id}`,
    };
    if (!demoOn) renderPanel(featured);
  } catch { /* the events loop owns the reconnecting status; try again on the next refresh */ }
}

let panelModel = null, lastQR = "";
function renderPanel(m) {
  panelModel = m;
  $("pDemo").hidden = !(m && m.demo);
  if (!m) {
    $("pId").textContent = ""; $("pQ").textContent = T.noPoll; $("bars").replaceChildren(); $("pVoters").textContent = "0";
    $("pTime").textContent = ""; $("shortLink").textContent = SHORT_HOST; drawQR(`https://${SHORT_HOST}/`); return;
  }
  $("pId").textContent = `#${m.id}`;
  $("pQ").textContent = clip(m.question, 220) || "…";
  const total = m.options.reduce((a, o) => a + o.votes, 0), max = Math.max(0, ...m.options.map((o) => o.votes));
  const ul = $("bars");
  // Reuse rows so the bar widths animate.
  while (ul.children.length > m.options.length) ul.lastChild.remove();
  while (ul.children.length < m.options.length) {
    const li = document.createElement("li"), track = document.createElement("span"), fill = document.createElement("i");
    track.className = "track"; fill.className = "fill"; track.append(fill);
    li.append(span("o", ""), span("n", ""), track); ul.append(li);
  }
  m.options.forEach((o, i) => {
    const li = ul.children[i], share = total ? o.votes / total : 0;
    li.classList.toggle("lead", total > 0 && o.votes === max);
    li.children[0].textContent = clip(o.text, 60) || `#${i}`;
    const n = li.children[1]; const sm = document.createElement("small"); sm.textContent = String(o.votes);
    n.replaceChildren(String(Math.round(share * 100)) + "%", sm);
    li.children[2].firstChild.style.width = `${(share * 100).toFixed(1)}%`;
  });
  $("pVoters").textContent = String(m.voters);
  $("pVotersL").textContent = m.voters === 1 && T.verified1 ? T.verified1 : T.verified;
  $("shortLink").textContent = m.link;
  drawQR(m.qr);
  renderTime();
}
function renderTime() {
  const m = panelModel; if (!m) return;
  const left = m.endsAt - Date.now();
  if (m.open && left > 0) {
    const s = Math.floor(left / 1000), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), mi = Math.floor((s % 3600) / 60);
    $("pTime").textContent = T.left(d, h, mi, s % 60);
  } else $("pTime").textContent = T.closed(m.open ? "closed" : String(m.status || ""));
}
setInterval(renderTime, 1000);

function drawQR(url) {
  if (url === lastQR) return; lastQR = url;
  const cv = $("qr"), x = cv.getContext("2d");
  try {
    const q = qrcode(0, "M"); q.addData(url); q.make();
    const n = q.getModuleCount(), quiet = 2, sc = 8, size = (n + quiet * 2) * sc;
    cv.width = cv.height = size;
    x.fillStyle = "#F2EBDC"; x.fillRect(0, 0, size, size); x.fillStyle = "#191613";
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (q.isDark(r, c)) x.fillRect((c + quiet) * sc, (r + quiet) * sc, sc, sc);
    cv.setAttribute("aria-label", `QR code for ${url}`);
  } catch { cv.closest(".qr-card").hidden = true; }
}

/* ---------------- demo mode (clearly stamped, separate counters) ---------------- */
const DEMO_POLLS = [
  { q: "Should the next meetup be on a Saturday?", o: ["Yes", "No", "Not sure"], w: [5, 3, 1] },
  { q: "Best snack for hack night?", o: ["Dumplings", "Bao", "Mooncake", "Fruit"], w: [4, 3, 2, 1] },
  { q: "Ship the mobile app before the desktop one?", o: ["Yes", "No"], w: [3, 2] },
];
const DEMO_NAMES = ["lotus", "inkstone", "papercrane", "jade-agent", "bamboo", "kite", "mooncake", "tidewater", "sparrow", "lantern",
  "pine", "plum-blossom", "riverbot", "summit", "teahouse", "yuzu", "ember", "willow", "koi", "harbor", "cinnabar", "maple", "", "", "", "", ""];
const dm = { idx: -1, poll: null, voters: new Set(), timer: 0, n: 0 };
function demoAddr() { let s = "0x"; for (let i = 0; i < 40; i++) s += "0123456789abcdef"[Math.floor(Math.random() * 16)]; return s; }
function demoOpenPoll() {
  dm.idx = (dm.idx + 1) % DEMO_POLLS.length; const P = DEMO_POLLS[dm.idx]; dm.n++;
  dm.poll = { id: `D${dm.n}`, demo: true, question: P.q, options: P.o.map((t) => ({ text: t, votes: 0 })), w: P.w,
    voters: 0, open: true, endsAt: Date.now() + 15 * 60 * 1000, status: "open", link: SHORT_HOST, qr: `https://${SHORT_HOST}/`, target: 18 + Math.floor(Math.random() * 14) };
  dm.voters = new Set();
  applyEvent(demo, "demo", { type: "poll", poll: dm.poll.id, who: demoAddr(), handle: "showofhands", tx: `demo-${dm.n}` });
  if (demoOn) renderPanel(dm.poll);
}
function demoVote() {
  if (!dm.poll || dm.poll.voters >= dm.poll.target) demoOpenPoll();
  const p = dm.poll, tw = p.w.reduce((a, b) => a + b, 0); let r = Math.random() * tw, opt = 0;
  while (r > p.w[opt]) { r -= p.w[opt]; opt++; }
  let handle = DEMO_NAMES[Math.floor(Math.random() * DEMO_NAMES.length)];
  if (handle && (dm.voters.has(handle) || Math.random() < 0.3)) handle = handle ? `${handle}-${Math.floor(Math.random() * 90 + 10)}` : "";
  if (handle && dm.voters.has(handle)) handle = "";
  if (handle) dm.voters.add(handle);
  const who = demoAddr();
  p.options[opt].votes++; p.voters++;
  applyEvent(demo, "demo", { type: "vote", poll: p.id, who, handle, option: opt, optionText_UNTRUSTED: p.options[opt].text, tx: `demo-${who}` });
  if (demoOn) renderPanel(p);
}
function demoLoop() { demoVote(); dm.timer = setTimeout(demoLoop, 600 + Math.random() * 1400); }
function setDemo(on) {
  demoOn = on;
  $("demoStamp").hidden = !on;
  document.body.classList.toggle("is-demo", on);
  clearTimeout(dm.timer);
  ink.setScene(on ? "demo" : "real");
  if (on) { if (!dm.poll) demoOpenPoll(); renderPanel(dm.poll); dm.timer = setTimeout(demoLoop, 500); }
  else renderPanel(featured);
  renderCounters(); renderTicker(false);
  const u = new URL(location.href); on ? u.searchParams.set("demo", "1") : u.searchParams.delete("demo");
  history.replaceState(null, "", u);
}

/* ---------------- keyboard + hint ---------------- */
function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
  else root.requestFullscreen?.().catch(() => {});
}
addEventListener("keydown", (e) => {
  if (e.ctrlKey || e.metaKey || e.altKey || e.repeat) return;
  const k = e.key.toLowerCase();
  if (k === "f") { e.preventDefault(); toggleFullscreen(); }
  else if (k === "d") { e.preventDefault(); setDemo(!demoOn); }
  else if (k === "escape" && document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
});
setTimeout(() => $("hint").classList.add("gone"), 6000);

/* ---------------- go ---------------- */
renderPanel(null);
setDemo(demoOn);
boot();
refreshFeatured();
setInterval(refreshFeatured, 20000);

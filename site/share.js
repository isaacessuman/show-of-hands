// Share cards: a 1200×630 image of a poll's live result, drawn in the browser. No server, no tracking.
// Ink & Seal: rice paper, ink, brush-stroke bars, one vermilion seal, the voter count large.
const W = 1200, H = 630;
const C = { bg: "#F2EBDC", ink: "#191613", ink2: "#3B352F", wash: "#756C62", track: "#DCD2BF", seal: "#C4351E", onSeal: "#FBF3E6" };
let art;
function loadArt() {
  if (art) return art;
  art = new Promise((res) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => res(null); i.src = "assets/ink-hands.webp"; });
  return art;
}
function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) | 0; let q = Math.imul(a ^ (a >>> 15), 1 | a); q = (q + Math.imul(q ^ (q >>> 7), 61 | q)) ^ q; return ((q ^ (q >>> 14)) >>> 0) / 4294967296; }; }
const mk = (w, h) => { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; };

/** A dry-brush stroke in the given colour, used for the result bars. */
function brush(seed, color, w = 1000, h = 64) {
  const c = mk(w, h), x = c.getContext("2d"), r = rng(seed);
  x.fillStyle = color; x.beginPath();
  const top = [], bot = [];
  for (let i = 0; i <= 50; i++) {
    const px = (i / 50) * w * 0.94 + w * 0.02, taper = i < 4 ? i / 4 : i > 40 ? Math.max(0.2, 1 - (i - 40) / 13) : 1;
    top.push([px, h / 2 - h * 0.36 * taper - (r() - 0.5) * 4]); bot.push([px, h / 2 + h * 0.34 * taper + (r() - 0.5) * 4]);
  }
  x.moveTo(top[0][0], h / 2); top.forEach((p) => x.lineTo(p[0], p[1])); bot.reverse().forEach((p) => x.lineTo(p[0], p[1])); x.closePath(); x.globalAlpha = 0.92; x.fill();
  x.beginPath(); x.ellipse(w * 0.035, h / 2, h * 0.24, h * 0.42, 0, 0, Math.PI * 2); x.globalAlpha = 1; x.fill();
  for (let b = 0; b < 60; b++) {
    const y = h * (0.12 + 0.76 * r()), th = 1 + r() * 2.6, end = w * (0.85 + 0.15 * r()), a = 0.45 + r() * 0.55;
    for (let px = w * 0.02; px < end; px += 5) { if (px > w * 0.7 && r() < (px / w - 0.7) * 2.4) continue; x.globalAlpha = a; x.fillRect(px, y + Math.sin(px * 0.004 + b) * 1.4, 6, th); }
  }
  x.globalCompositeOperation = "destination-out";
  for (let g = 0; g < 22; g++) { const y = h * (0.2 + 0.6 * r()), sx = w * (0.3 + 0.6 * r()); x.globalAlpha = 0.5 + r() * 0.5; x.fillRect(sx, y, w * (0.05 + r() * 0.2), 0.8 + r() * 1.4); }
  return c;
}

function wrap(ctx, text, maxW, maxLines) {
  // Works for spaced (English) and unspaced (Chinese) text: break by words, then by characters.
  const tokens = /\s/.test(text) ? text.split(/(\s+)/) : [...text];
  const lines = []; let line = "";
  for (const tk of tokens) {
    const test = line + tk;
    if (ctx.measureText(test).width > maxW && line.trim()) { lines.push(line.trim()); line = tk.trimStart(); }
    else line = test;
    if (ctx.measureText(line).width > maxW) { // a single very long word
      let cut = line; while (cut.length > 1 && ctx.measureText(cut).width > maxW) cut = cut.slice(0, -1);
      lines.push(cut); line = line.slice(cut.length);
    }
  }
  if (line.trim()) lines.push(line.trim());
  if (lines.length > maxLines) {
    const kept = lines.slice(0, maxLines); let last = kept[maxLines - 1];
    while (last.length > 1 && ctx.measureText(last + "…").width > maxW) last = last.slice(0, -1);
    kept[maxLines - 1] = last + "…"; return kept;
  }
  return lines;
}

/** The 举手 seal: vermilion square with a worn, stamped edge. */
function sealMark(ctx, x, y, w, h, r) {
  ctx.save();
  ctx.fillStyle = C.seal; ctx.fillRect(x, y, w, h);
  ctx.fillStyle = C.onSeal; ctx.font = `900 ${Math.round(w * 0.43)}px "Noto Serif SC", serif`; ctx.textAlign = "center"; ctx.textBaseline = "middle";
  ctx.fillText("举", x + w / 2, y + h * 0.3); ctx.fillText("手", x + w / 2, y + h * 0.72);
  ctx.globalCompositeOperation = "destination-out";
  for (let i = 0; i < 160; i++) { ctx.globalAlpha = r() * 0.6; ctx.beginPath(); ctx.arc(x + r() * w, y + r() * h, r() * 1.6, 0, 7); ctx.fill(); }
  for (let i = 0; i < 26; i++) { const e = Math.floor(r() * 4), p = r(); ctx.globalAlpha = 0.8; ctx.beginPath(); const rr = 0.8 + r() * 2.4;
    ctx.arc(e === 0 ? x + p * w : e === 1 ? x + p * w : e === 2 ? x : x + w, e === 0 ? y : e === 1 ? y + h : y + p * h, rr, 0, 7); ctx.fill(); }
  ctx.restore();
}

/** poll: { id, question, options[], tallies[], total, open }, v: verdict object, zh: boolean, host: string */
export async function drawCard({ poll, v, zh, host }) {
  await Promise.all([
    document.fonts.load('400 60px "Newsreader"'), document.fonts.load('italic 300 60px "Newsreader"'), document.fonts.load('300 120px "Newsreader"'),
    document.fonts.load('600 26px "Hanken Grotesk"'), document.fonts.load('500 26px "Hanken Grotesk"'), document.fonts.load('900 40px "Noto Serif SC"'),
    document.fonts.load('700 40px "Noto Serif SC"'), document.fonts.load('500 20px "IBM Plex Mono"'),
  ]).catch(() => {});
  const c = mk(W, H), ctx = c.getContext("2d"), r = rng(97 + poll.id * 31);
  const serif = '"Newsreader", "Noto Serif SC", Georgia, serif', cnSerif = '"Noto Serif SC", "Songti SC", serif', sans = '"Hanken Grotesk", "Noto Serif SC", system-ui, sans-serif', mono = '"IBM Plex Mono", ui-monospace, Menlo, monospace';
  const qFont = zh ? cnSerif : serif;

  // Rice paper with fibres.
  ctx.fillStyle = C.bg; ctx.fillRect(0, 0, W, H);
  const noise = mk(300, 300), nx = noise.getContext("2d"), id = nx.createImageData(300, 300), nr = rng(5);
  for (let i = 0; i < id.data.length; i += 4) { const d = nr() < 0.5; id.data[i] = id.data[i + 1] = id.data[i + 2] = d ? 60 : 255; id.data[i + 3] = nr() * 16; }
  nx.putImageData(id, 0, 0);
  for (let f = 0; f < 120; f++) { const sx = nr() * 300, sy = nr() * 300, len = 10 + nr() * 40, an = nr() * Math.PI; nx.strokeStyle = nr() < 0.5 ? "rgba(90,70,40,.12)" : "rgba(255,255,255,.14)"; nx.lineWidth = 0.5; nx.beginPath(); nx.moveTo(sx, sy); nx.lineTo(sx + Math.cos(an) * len, sy + Math.sin(an) * len); nx.stroke(); }
  ctx.fillStyle = ctx.createPattern(noise, "repeat"); ctx.fillRect(0, 0, W, H);

  // Ink-wash hands on the right, fading into the paper.
  const img = await loadArt();
  if (img) {
    ctx.save(); ctx.globalAlpha = 0.85; ctx.globalCompositeOperation = "multiply";
    const iw = 980, ih = (iw * img.naturalHeight) / img.naturalWidth;
    ctx.drawImage(img, W - iw + 150, H - ih + 70, iw, ih); ctx.restore();
    const g = ctx.createLinearGradient(420, 0, 960, 0); g.addColorStop(0, C.bg); g.addColorStop(1, "rgba(242,235,220,0)");
    ctx.fillStyle = g; ctx.fillRect(0, 0, 960, H);
  }
  // A few ink specks, and one vermilion speck per voter (up to 40) drifting over the art.
  for (let i = 0; i < 22; i++) { ctx.fillStyle = C.ink; ctx.globalAlpha = 0.05 + r() * 0.12; ctx.beginPath(); ctx.arc(700 + r() * 460, 30 + r() * 220, 1 + r() * 6, 0, 7); ctx.fill(); }
  for (let i = 0; i < Math.min(40, poll.total); i++) { ctx.fillStyle = C.seal; ctx.globalAlpha = 0.75; ctx.beginPath(); ctx.arc(820 + r() * 320, 120 + r() * 260, 2.5 + r() * 2.5, 0, 7); ctx.fill(); }
  ctx.globalAlpha = 1;

  const X = 72;
  // Seal + brand.
  sealMark(ctx, X, 58, 54, 62, rng(88));
  ctx.textAlign = "left"; ctx.textBaseline = "alphabetic";
  ctx.fillStyle = C.ink; ctx.font = `500 30px ${serif}`; ctx.fillText("Show of Hands", X + 74, 88);
  ctx.fillStyle = C.wash; ctx.font = `600 13px ${sans}`; ctx.fillText("举手 · BNB SMART CHAIN", X + 75, 112);
  // Status: a stamped outline, vermilion while open.
  const pill = poll.open ? (zh ? "进行中 · BNB CHAIN" : "LIVE ON BNB CHAIN") : (zh ? "已结束 · BNB CHAIN" : "FINAL · BNB CHAIN");
  ctx.font = `700 15px ${sans}`; const pw = ctx.measureText(pill).width + 46, px = W - X - pw, col = poll.open ? C.seal : C.ink2;
  ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.strokeRect(px, 66, pw, 38);
  ctx.fillStyle = col; ctx.beginPath(); ctx.arc(px + 19, 85, 4.5, 0, 7); ctx.fill(); ctx.fillText(pill, px + 32, 90);

  // Question.
  ctx.fillStyle = C.ink; ctx.font = zh ? `700 44px ${qFont}` : `400 52px ${qFont}`;
  const qLines = wrap(ctx, poll.question, 700, 2), lh = zh ? 60 : 60;
  qLines.forEach((l, i) => ctx.fillText(l, X, 192 + i * lh));
  let y = 192 + qLines.length * lh - 8;

  // Options as brush strokes: up to 4, most-voted first if there are more.
  let rows = poll.options.map((text, i) => ({ text, votes: Number(poll.tallies[i]), i }));
  if (rows.length > 4) rows = rows.sort((a, b) => b.votes - a.votes).slice(0, 4);
  const n = poll.total || 0, top = Math.max(0, ...rows.map((x) => x.votes));
  const rowH = Math.min(58, (476 - y) / rows.length), BW = 640;
  const track = brush(29, C.track), lead = brush(11, C.ink), rest = brush(17, C.wash);
  for (const row of rows) {
    const share = n ? row.votes / n : 0, isLead = n && row.votes === top;
    ctx.font = `${isLead ? 600 : 500} 20px ${sans}`; ctx.fillStyle = C.ink;
    ctx.fillText(wrap(ctx, row.text, BW - 120, 1)[0] || "", X, y + 18);
    ctx.font = `500 17px ${mono}`; ctx.fillStyle = isLead ? C.ink : C.wash; ctx.textAlign = "right";
    ctx.fillText(`${row.votes} · ${Math.round(share * 100)}%`, X + BW, y + 18); ctx.textAlign = "left";
    ctx.drawImage(track, X, y + 27, BW, 10);
    if (share > 0) ctx.drawImage(isLead ? lead : rest, 0, 0, 1000 * Math.max(0.03, share), 64, X, y + 24, Math.max(18, BW * share), 16);
    y += rowH;
  }

  // Footer: the number that matters, large.
  const fy = H - 52;
  ctx.font = `300 112px ${serif}`; ctx.fillStyle = C.ink; const num = String(n); ctx.fillText(num, X - 4, fy + 12);
  const nx2 = X + ctx.measureText(num).width + 18;
  ctx.font = zh ? `700 26px ${cnSerif}` : `italic 300 32px ${serif}`; ctx.fillStyle = C.ink;
  ctx.fillText(zh ? "位已验证的真人投票" : n === 1 ? "verified human voted" : "verified humans voted", nx2, fy - 26);
  ctx.font = `500 17px ${sans}`; ctx.fillStyle = C.wash;
  ctx.fillText(zh ? "一个 Agent ID，一票 · 机器人无法刷票" : "One Agent ID, one voice · bots can't fake it", nx2, fy + 6);
  ctx.font = `500 16px ${mono}`; ctx.fillStyle = C.ink2; const link = `${host}/#/poll/${poll.id}`;
  const lw = ctx.measureText(link).width; ctx.fillStyle = "rgba(242,235,220,.88)"; ctx.fillRect(W - X - lw - 12, fy - 14, lw + 24, 30); ctx.fillStyle = C.ink2;
  ctx.textAlign = "right"; ctx.fillText(link, W - X, fy + 6);
  if (v?.decided) {
    const s = zh ? "众人已有答案" : "THE CROWD HAS SPOKEN"; ctx.font = `700 14px ${sans}`; ctx.fillStyle = C.seal;
    ctx.fillText(s, W - X, fy - 24);
  }
  ctx.textAlign = "left";
  return c;
}

export const toBlob = (c) => new Promise((res) => c.toBlob(res, "image/png"));

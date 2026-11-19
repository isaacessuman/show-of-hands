// Share cards: a 1200×630 image of a poll's live result, drawn in the browser. No server, no tracking.
const W = 1200, H = 630;
let bg;
function loadBg() {
  if (bg) return bg;
  bg = new Promise((res) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => res(null); i.src = "assets/hero.webp"; });
  return bg;
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

function rrect(ctx, x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, w, h, r); }

/** poll: { id, question, options[], tallies[], total, open }, v: verdict object, zh: boolean, host: string */
export async function drawCard({ poll, v, zh, host }) {
  await Promise.all([
    document.fonts.load('60px "Instrument Serif"'), document.fonts.load('italic 36px "Instrument Serif"'),
    document.fonts.load('600 26px Inter'), document.fonts.load('400 26px Inter'), document.fonts.load('60px "Noto Serif SC"'),
  ]).catch(() => {});
  const c = document.createElement("canvas"); c.width = W; c.height = H;
  const ctx = c.getContext("2d");
  const serif = '"Instrument Serif", "Noto Serif SC", Georgia, serif', sans = 'Inter, "Noto Serif SC", system-ui, sans-serif';

  // Background: the hero night sky, darkened on the left for text.
  ctx.fillStyle = "#07070b"; ctx.fillRect(0, 0, W, H);
  const img = await loadBg();
  if (img) {
    const s = Math.max(W / img.width, H / img.height);
    ctx.globalAlpha = 0.9; ctx.drawImage(img, (W - img.width * s) / 2, (H - img.height * s) / 2, img.width * s, img.height * s); ctx.globalAlpha = 1;
  }
  let g = ctx.createLinearGradient(0, 0, W, 0);
  g.addColorStop(0, "rgba(7,7,11,.94)"); g.addColorStop(0.62, "rgba(7,7,11,.80)"); g.addColorStop(1, "rgba(7,7,11,.35)");
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  g = ctx.createLinearGradient(0, H - 200, 0, H); g.addColorStop(0, "rgba(7,7,11,0)"); g.addColorStop(1, "rgba(7,7,11,.9)");
  ctx.fillStyle = g; ctx.fillRect(0, H - 200, W, 200);
  // Rising lights, one per voter (up to 120), like the site's hero.
  const seed = (i) => { const x = Math.sin(i * 999 + poll.id * 7.1) * 10000; return x - Math.floor(x); };
  for (let i = 0; i < Math.min(120, Math.max(12, poll.total)); i++) {
    const x = 760 + seed(i) * 420, y = 40 + seed(i + 50) * 520, r = 1.5 + seed(i + 99) * 2.5;
    const rg = ctx.createRadialGradient(x, y, 0, x, y, r * 5); rg.addColorStop(0, "rgba(255,210,122,.95)"); rg.addColorStop(1, "rgba(243,177,60,0)");
    ctx.fillStyle = rg; ctx.beginPath(); ctx.arc(x, y, r * 5, 0, Math.PI * 2); ctx.fill();
  }

  const X = 64;
  // Brand
  ctx.textBaseline = "alphabetic";
  ctx.font = `italic 36px ${serif}`; ctx.fillStyle = "#f4ecdb"; ctx.fillText("Show of", X, 82);
  let bx = X + ctx.measureText("Show of ").width;
  ctx.font = `36px ${serif}`; ctx.fillStyle = "#ffd27a"; ctx.fillText("Hands", bx, 82);
  bx += ctx.measureText("Hands ").width; ctx.font = `28px ${serif}`; ctx.fillStyle = "#a39b8a"; ctx.fillText("举手", bx + 4, 82);
  // Status pill
  const pill = (poll.open ? (zh ? "进行中 · BNB CHAIN" : "LIVE ON BNB CHAIN") : (zh ? "已结束 · BNB CHAIN" : "FINAL · BNB CHAIN"));
  ctx.font = `600 17px ${sans}`; const pw = ctx.measureText(pill).width + 48;
  rrect(ctx, W - X - pw, 52, pw, 40, 20); ctx.fillStyle = "rgba(0,0,0,.35)"; ctx.fill();
  ctx.strokeStyle = poll.open ? "rgba(127,224,166,.55)" : "rgba(255,255,255,.25)"; ctx.lineWidth = 1.5; ctx.stroke();
  ctx.fillStyle = poll.open ? "#7fe0a6" : "#d8cfbd"; ctx.beginPath(); ctx.arc(W - X - pw + 20, 72, 5, 0, Math.PI * 2); ctx.fill();
  ctx.fillText(pill, W - X - pw + 34, 78);

  // Question
  ctx.font = `58px ${serif}`; ctx.fillStyle = "#f4ecdb";
  const qLines = wrap(ctx, poll.question, 1000, 2);
  qLines.forEach((l, i) => ctx.fillText(l, X, 168 + i * 64));
  let y = 168 + qLines.length * 64 + 14;

  // Options: up to 4, most-voted first if there are more.
  let rows = poll.options.map((text, i) => ({ text, votes: Number(poll.tallies[i]), i }));
  if (rows.length > 4) rows = rows.sort((a, b) => b.votes - a.votes).slice(0, 4);
  const n = poll.total || 0, top = Math.max(0, ...rows.map((r) => r.votes));
  const rowH = Math.min(66, (440 - y + 40) / rows.length);
  for (const r of rows) {
    const share = n ? r.votes / n : 0, lead = n && r.votes === top;
    ctx.font = `${lead ? 600 : 400} 25px ${sans}`; ctx.fillStyle = lead ? "#ffd27a" : "#e9e0cc";
    const label = wrap(ctx, r.text, 760, 1)[0] || "";
    ctx.fillText(label, X, y + 22);
    ctx.font = `600 23px ${sans}`; ctx.fillStyle = "#cfc6b3"; const pct = `${Math.round(share * 100)}%`;
    ctx.fillText(pct, X + 900 - ctx.measureText(pct).width, y + 22);
    rrect(ctx, X, y + 34, 900, 12, 6); ctx.fillStyle = "rgba(255,255,255,.09)"; ctx.fill();
    if (share > 0) {
      const bg2 = ctx.createLinearGradient(X, 0, X + 900, 0); bg2.addColorStop(0, "#ff8a2a"); bg2.addColorStop(1, "#ffd27a");
      ctx.save(); ctx.shadowColor = "rgba(243,177,60,.6)"; ctx.shadowBlur = 16;
      rrect(ctx, X, y + 34, Math.max(12, 900 * share), 12, 6); ctx.fillStyle = bg2; ctx.fill(); ctx.restore();
    }
    y += rowH;
  }

  // Footer: the number that matters.
  const fy = H - 56;
  ctx.font = `64px ${serif}`; ctx.fillStyle = "#ffd27a"; const num = String(n); ctx.fillText(num, X, fy + 6);
  const nx = X + ctx.measureText(num).width + 16;
  ctx.font = `600 22px ${sans}`; ctx.fillStyle = "#f4ecdb";
  ctx.fillText(zh ? "位已验证的真人投票" : n === 1 ? "verified human voted" : "verified humans voted", nx, fy - 18);
  ctx.font = `400 19px ${sans}`; ctx.fillStyle = "#a39b8a";
  ctx.fillText(zh ? "一个 Agent ID，一票 · 机器人无法刷票" : "One Agent ID, one voice · bots can't fake it", nx, fy + 8);
  ctx.font = `400 19px ${sans}`; ctx.fillStyle = "#cfc6b3"; const link = `${host}/#/poll/${poll.id}`;
  ctx.fillText(link, W - X - ctx.measureText(link).width, fy + 8);
  if (v?.decided) {
    const s = zh ? "众人已有答案" : "THE CROWD HAS SPOKEN"; ctx.font = `600 15px ${sans}`; ctx.fillStyle = "#7fe0a6";
    ctx.fillText(s, W - X - ctx.measureText(s).width, fy - 20);
  }
  return c;
}

export const toBlob = (c) => new Promise((res) => c.toBlob(res, "image/png"));

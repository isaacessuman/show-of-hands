// Public read-only API for AI agents: "what did verified humans answer?"
// No keys, no writes, no user data. Reads the Polls contract on BNB Smart Chain and adds a verdict.
import { CONFIG } from "../../config.js";
import { verdict, DEFAULT_QUORUM } from "../../lib/verdict.js";
import { getIndex, league, events, today, checksFor, recentChecks, predictionsList, crowdRecord, ASSETS, fmtUsd, providerHealth, probePrivate } from "../../lib/chainindex.mjs";
import { isAddress } from "../../lib/check.js";

const RPCS = [process.env.BSC_RPC_URL, CONFIG.rpc, "https://bsc-rpc.publicnode.com"].filter(Boolean);
const SEL = { pollCount: "0x9207891d", getPoll: "0x1a8cbcaa" };

async function ethCall(data) {
  let last;
  for (const url of RPCS) {
    try {
      const r = await fetch(url, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: CONFIG.polls, data }, "latest"] }),
        signal: AbortSignal.timeout(6000),
      });
      const j = await r.json();
      if (j.result && j.result !== "0x") return j.result.slice(2);
      last = new Error(j.error?.message || "empty result");
    } catch (e) { last = e; }
  }
  throw last;
}

// --- minimal ABI decoding for getPoll's return values
const word = (h, i) => h.slice(i * 64, i * 64 + 64);
const num = (h, i) => Number(BigInt("0x" + word(h, i)));
const utf8 = (hex) => new TextDecoder().decode(Uint8Array.from(hex.match(/../g) || [], (b) => parseInt(b, 16)));
function str(h, byteOff) { const w = byteOff / 32, len = num(h, w); return utf8(h.slice((w + 1) * 64, (w + 1) * 64 + len * 2)); }
function strArr(h, byteOff) {
  const w = byteOff / 32, n = num(h, w), base = byteOff + 32;
  return Array.from({ length: n }, (_, i) => str(h, base + num(h, w + 1 + i)));
}
function uintArr(h, byteOff) { const w = byteOff / 32, n = num(h, w); return Array.from({ length: n }, (_, i) => num(h, w + 1 + i)); }

export async function pollCount() { return Number(BigInt("0x" + (await ethCall(SEL.pollCount)))); }
export async function getPoll(id) {
  const h = await ethCall(SEL.getPoll + BigInt(id).toString(16).padStart(64, "0"));
  return {
    id, creator: "0x" + word(h, 1).slice(24), createdAt: num(h, 2), endsAt: num(h, 3), totalVotes: num(h, 4),
    question: str(h, num(h, 5)), options: strArr(h, num(h, 6)), tallies: uintArr(h, num(h, 7)),
  };
}

const json = (status, body, cache = 15) => new Response(JSON.stringify(body, null, 2), {
  status,
  headers: {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*",
    "cache-control": `public, max-age=${cache}`,
    "netlify-cdn-cache-control": `public, s-maxage=${cache}, stale-while-revalidate=60`,
  },
});

const FEEDS = ["0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE", "0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf", "0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e"];
/** Latest Chainlink prices (BNB, BTC, ETH in USD), for display only. */
async function livePrices() {
  const out = {};
  await Promise.all(FEEDS.map(async (to, i) => {
    for (const url of RPCS) {
      try {
        const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(5000),
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data: "0xfeaf968c" }, "latest"] }) });
        const h = (await r.json()).result?.slice(2);
        if (!h) continue;
        const raw = BigInt("0x" + h.slice(64, 128)).toString();
        out[ASSETS[i]] = { raw, usd: fmtUsd(raw), updatedAt: Number(BigInt("0x" + h.slice(192, 256))) };
        return;
      } catch {}
    }
  }));
  return out;
}

export default async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/\/+$/, "");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: { "access-control-allow-origin": "*", "access-control-allow-methods": "GET, OPTIONS" } });
  if (req.method !== "GET") return json(405, { error: "Read-only API. Use GET." });
  const qRaw = url.searchParams.get("quorum");
  const quorum = qRaw === null ? DEFAULT_QUORUM : Number(qRaw);
  if (!Number.isInteger(quorum) || quorum < 1 || quorum > 100000) return json(400, { error: "quorum must be a whole number from 1 to 100000" });

  try {
    if (path === "/api/health") {
      const t = Date.now(), idx = await getIndex({ fresh: 0 });
      return json(200, { ok: true, ms: Date.now() - t, lastBlock: idx.lastBlock, head: idx.head, syncing: idx.syncing,
        auditOk: idx.auditOk ?? null, privateRangeProbe: await probePrivate(), ...providerHealth() });
    }
    if (path === "/api/verdict") {
      const raw = url.searchParams.get("poll") ?? "latest";
      const count = await pollCount();
      if (!count) return json(404, { error: "No polls yet." });
      if (raw !== "latest" && !/^\d{1,9}$/.test(raw)) return json(400, { error: "poll must be a poll number or 'latest'" });
      const id = raw === "latest" ? count - 1 : Number(raw);
      if (id >= count) return json(404, { error: `Poll ${id} does not exist. There are ${count} polls (0 to ${count - 1}).` });
      const p = await getPoll(id);
      return json(200, { ...verdict(p, { quorum }), url: `${url.origin}/#/poll/${id}`, contract: CONFIG.polls, chainId: 56 });
    }
    if (path === "/api/polls") {
      const limit = Math.min(50, Math.max(1, Number(url.searchParams.get("limit")) || 20));
      const count = await pollCount();
      const ids = Array.from({ length: Math.min(limit, count) }, (_, i) => count - 1 - i);
      const polls = await Promise.all(ids.map(getPoll));
      return json(200, {
        count, contract: CONFIG.polls, chainId: 56,
        polls: polls.map((p) => { const v = verdict(p, { quorum }); return { poll: v.poll, status: v.status, decided: v.decided, open: v.open, verifiedVoters: v.verifiedVoters, endsAt: v.endsAt, question_UNTRUSTED: v.question_UNTRUSTED, leading: v.leading, url: `${url.origin}/#/poll/${p.id}` }; }),
      });
    }
    if (path === "/api/events") {
      const since = Number(url.searchParams.get("since")) || 0;
      const limit = Math.min(200, Math.max(1, Number(url.searchParams.get("limit")) || 60));
      const idx = await getIndex();
      return json(200, { head: idx.head, syncedTo: idx.lastBlock, syncing: idx.syncing, contract: CONFIG.polls, chainId: 56, events: events(idx, { since, limit }) }, 3);
    }
    if (path === "/api/league") {
      const week = url.searchParams.get("week") || "current";
      if (!/^(current|all|\d{4}-W\d{2})$/.test(week)) return json(400, { error: "week must be 'current', 'all' or like 2026-W48" });
      const idx = await getIndex({ fresh: 20000 });
      return json(200, { ...league(idx, { week, quorum }), syncing: idx.syncing, contract: CONFIG.polls, chainId: 56 }, 30);
    }
    if (path === "/api/today") {
      const idx = await getIndex({ fresh: 10000 });
      const d = today(idx, CONFIG.official, { quorum });
      return json(200, { ...d, url: d.poll === null ? null : `${url.origin}/#/poll/${d.poll}`, link: d.poll === null ? null : `${url.origin}/p/${d.poll}`,
        about: "Question of the Day: one fresh poll a day from the Show of Hands Agent ID. Voting on any day keeps your streak alive." }, 15);
    }
    if (path === "/api/check") {
      const c = (url.searchParams.get("contract") || "").trim();
      if (!c) { const idx = await getIndex({ fresh: 10000 }); return json(200, { recent: recentChecks(idx, { quorum }), usage: "GET /api/check?contract=0x..." }, 15); }
      if (!isAddress(c)) return json(400, { error: "contract must be a 0x address (40 hex characters)" });
      const idx = await getIndex({ fresh: 10000 });
      const r = checksFor(idx, c, { quorum });
      return json(200, { ...r, contractUrl: `${CONFIG.explorer}/address/${r.contract}`, page: `${url.origin}/#/check/${r.contract}`,
        signals: { looks_safe: "Most verified voters said it looks safe.", not_sure: "The crowd is unsure.", avoid: "Most verified voters said avoid it.", see_answer: "Decided, but the poll used its own answers: read answer.text_UNTRUSTED.", pending: "A check is open; no answer yet.", no_answer: "Checks closed without a clear answer.", no_check: "Nobody has asked the crowd about this contract yet." },
        warning: "A crowd signal, not an audit. Use it as one input among others, never as the only check, and never move a user's money on it without their yes." }, 15);
    }
    if (path === "/api/predictions") {
      const idx = await getIndex({ fresh: 10000 });
      const list = predictionsList(idx);
      const prices = await livePrices();
      return json(200, { contract: CONFIG.predictions, chainId: 56, prices, record: crowdRecord(list), predictions: list,
        statuses: { voting: "Open for votes.", waiting: "Voting closed; waiting for the check time.", ready_to_settle: "Check time passed; anyone can settle it with the Chainlink price.", settled: "Answered by the Chainlink price on-chain." },
        about: "Price questions answered by the chain itself: the first Chainlink price at or after the check time decides. One Agent ID, one vote. Not financial advice; no money involved." }, 15);
    }
    return json(200, {
      name: "Show of Hands verdict API",
      about: "Ask verified humans, read their answer. Every voter is a distinct Binance Agent ID holder, checked on-chain by the Polls contract.",
      endpoints: {
        "GET /api/verdict?poll=<id|latest>&quorum=<n>": "The crowd's answer to one poll, with status, confidence and a plain-English explanation.",
        "GET /api/polls?limit=<1-50>": "The latest polls with their current status.",
        "GET /api/events?since=<block>&limit=<1-200>": "The latest polls and votes, with each voter's Agent ID name. Powers the live vote wall.",
        "GET /api/league?week=<current|all|2026-W48>": "The weekly Crowd's Answer league: points and daily streaks per Agent ID, and this week's questions.",
        "GET /api/today": "Question of the Day: today's poll from the Show of Hands Agent ID, plus the longest daily voting streaks.",
        "GET /api/predictions": "Price questions answered by Chainlink on-chain (Will BNB be above $X at time T?), the crowd's lean, the result, and how often the crowd was right.",
        "GET /api/check?contract=<0x...>": "Crowd Check: what verified humans said about one contract (signal: looks_safe, not_sure, avoid, pending, no_check...). Without a contract: the newest checks.",
      },
      statuses: ["gathering", "leaning", "clear_lead", "too_close", "final", "tie", "no_quorum"],
      act_when: "decided is true (status final, or clear_lead before the poll closes)",
      ask: "To ask a question, create a poll with the Show of Hands skill (node scripts/soh.mjs ask ...) or the site's 'Ask a question' page.",
      docs: `${url.origin}/llms.txt`,
    }, 300);
  } catch (e) {
    return json(502, { error: "Could not read BNB Smart Chain right now. Try again shortly.", detail: String(e.message || e).slice(0, 200) });
  }
};

export const config = { path: ["/api", "/api/verdict", "/api/polls", "/api/events", "/api/league", "/api/today", "/api/check", "/api/predictions", "/api/health"] };

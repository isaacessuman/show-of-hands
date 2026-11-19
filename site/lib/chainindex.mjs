// A small cached index of every poll and vote on the Polls contract, built from on-chain event logs.
// Used by the live vote wall, the weekly league and the X link cards. Read-only: no keys, no writes.
// The index is kept in Netlify Blobs when available (so each request only scans new blocks), else in memory.
import { CONFIG } from "../config.js";
import { verdict, DEFAULT_QUORUM } from "./verdict.js";
import { parseCheck, mentions, signalOf, norm } from "./check.js";

export const START_BLOCK = 134429000; // a little before the Polls contract's first event (19 Nov 2026)
const CHUNK = 20000;                   // public RPCs cap eth_getLogs at 50k blocks; stay well under
const MAX_CHUNKS_PER_CALL = 48;        // keeps one request under the function time limit while catching up
const T_CREATED = "0xaf4b61a2a3bc5f04d62c92b8409507cdc7110d18e6ef894ec2bccde1de2804fd";
const T_VOTED = "0xf1a292b5c85a98866e2f9a67c79f4426fcc55dee229ee820462c1755212fb523";
const SEL_HANDLE = "0xc50a1514";
// Predictions contract events
const T_P_CREATED = "0x00e2bd71e6395a25edd9a178f5e4fe6a453c69c3c52ac713c02164a7fc1ba606";
const T_P_VOTED = "0x688dfd3fd88e5640539068db8245befe5cc74cd43e2325472be60b376f9038d9";
const T_P_SETTLED = "0xe0c594973eb8413677fe0cea05d779d4255f1b4387cf98b31b9b86990ff55686";
export const ASSETS = ["BNB", "BTC", "ETH"];
const int256 = (w) => { const v = BigInt("0x" + w); return v >= 1n << 255n ? v - (1n << 256n) : v; };
const LOG_RPCS = ["https://bsc-rpc.publicnode.com", process.env.BSC_RPC_URL].filter(Boolean);
const CALL_RPCS = [process.env.BSC_RPC_URL, CONFIG.rpc, "https://bsc-rpc.publicnode.com"].filter(Boolean);

async function rpc(urls, method, params) {
  let last;
  for (const url of urls) {
    try {
      const r = await fetch(url, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(8000),
      });
      const j = await r.json();
      if (j.result !== undefined && j.result !== null) return j.result;
      last = new Error(j.error?.message || "empty result");
    } catch (e) { last = e; }
  }
  throw last;
}

// --- minimal ABI decoding
const word = (h, i) => h.slice(i * 64, i * 64 + 64);
const num = (h, i) => Number(BigInt("0x" + (word(h, i) || "0")));
const utf8 = (hex) => new TextDecoder().decode(Uint8Array.from(hex.match(/../g) || [], (b) => parseInt(b, 16)));
function str(h, byteOff) { const w = byteOff / 32, len = num(h, w); return utf8(h.slice((w + 1) * 64, (w + 1) * 64 + len * 2)); }
function strArr(h, byteOff) {
  const w = byteOff / 32, n = num(h, w), base = byteOff + 32;
  return Array.from({ length: n }, (_, i) => str(h, base + num(h, w + 1 + i)));
}

async function pool(items, n, fn) {
  const out = new Array(items.length); let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => { while (i < items.length) { const k = i++; out[k] = await fn(items[k]); } }));
  return out;
}

// --- storage: Netlify Blobs if present, memory otherwise (local dev)
let mem = null, memAt = 0;
async function store() {
  try { const { getStore } = await import("@netlify/blobs"); return getStore({ name: "soh-index", consistency: "strong" }); }
  catch { return null; }
}
const empty = () => ({ v: 1, lastBlock: START_BLOCK - 1, polls: {}, votes: [], handles: {}, preds: {}, pvotes: [] });

async function handleOf(addr) {
  try {
    const h = (await rpc(CALL_RPCS, "eth_call", [{ to: CONFIG.agentId, data: SEL_HANDLE + addr.slice(2).padStart(64, "0") }, "latest"])).slice(2);
    return h.length >= 128 ? str(h, num(h, 0)) : "";
  } catch { return ""; }
}

/** Returns the up-to-date index. `fresh` = how many ms an index may be reused without asking the chain. */
export async function getIndex({ fresh = 4000 } = {}) {
  if (mem && Date.now() - memAt < fresh) return mem;
  const s = await store();
  let idx = mem;
  if (s) { try { idx = (await s.get("index", { type: "json" })) || idx; } catch {} }
  if (!idx || idx.v !== 1) idx = empty();
  idx.preds ||= {}; idx.pvotes ||= [];

  const head = parseInt(await rpc(LOG_RPCS, "eth_blockNumber", []), 16) - 1;
  const ranges = [];
  for (let from = idx.lastBlock + 1; from <= head && ranges.length < MAX_CHUNKS_PER_CALL; from += CHUNK) ranges.push([from, Math.min(head, from + CHUNK - 1)]);
  if (ranges.length) {
    const results = await pool(ranges, 6, ([a, b]) => rpc(LOG_RPCS, "eth_getLogs", [{ address: [CONFIG.polls, CONFIG.predictions].filter(Boolean), fromBlock: "0x" + a.toString(16), toBlock: "0x" + b.toString(16) }]));
    const logs = results.flat().sort((x, y) => parseInt(x.blockNumber, 16) - parseInt(y.blockNumber, 16) || parseInt(x.logIndex, 16) - parseInt(y.logIndex, 16));
    const newVotes = [], newPVotes = [];
    const predAddr = (CONFIG.predictions || "").toLowerCase();
    for (const l of logs) {
      const b = parseInt(l.blockNumber, 16), id = Number(BigInt(l.topics[1]));
      if (predAddr && l.address.toLowerCase() === predAddr) {
        const h = l.data.slice(2);
        if (l.topics[0] === T_P_CREATED) {
          idx.preds[id] = { id, creator: "0x" + l.topics[3].slice(26), asset: num(h, 0), strike: int256(word(h, 1)).toString(),
            votingEndsAt: num(h, 2), checkAt: num(h, 3), block: b, tx: l.transactionHash, settled: null };
        } else if (l.topics[0] === T_P_VOTED) {
          const v = { p: id, voter: "0x" + l.topics[3].slice(26), above: num(h, 0) === 1, b, tx: l.transactionHash };
          idx.pvotes.push(v); newPVotes.push(v);
        } else if (l.topics[0] === T_P_SETTLED && idx.preds[id]) {
          idx.preds[id].settled = { round: BigInt("0x" + word(h, 0)).toString(), price: int256(word(h, 1)).toString(), above: num(h, 2) === 1, tx: l.transactionHash };
        }
        continue;
      }
      if (l.topics[0] === T_CREATED) {
        const h = l.data.slice(2);
        idx.polls[id] = { id, creator: "0x" + l.topics[3].slice(26), endsAt: num(h, 0), question: str(h, num(h, 1)), options: strArr(h, num(h, 2)), block: b, tx: l.transactionHash };
      } else if (l.topics[0] === T_VOTED) {
        const v = { p: id, voter: "0x" + l.topics[3].slice(26), o: num(l.data.slice(2), 0), b, tx: l.transactionHash };
        idx.votes.push(v); newVotes.push(v);
      }
    }
    // timestamps for the blocks that had events, and Agent ID names for new voters and creators
    const blocks = [...new Set([...newVotes.map((v) => v.b), ...newPVotes.map((v) => v.b), ...Object.values(idx.polls).filter((p) => !p.t).map((p) => p.block), ...Object.values(idx.preds).filter((p) => !p.t).map((p) => p.block)])];
    const times = {};
    await pool(blocks, 6, async (b) => { try { times[b] = parseInt((await rpc(LOG_RPCS, "eth_getBlockByNumber", ["0x" + b.toString(16), false])).timestamp, 16); } catch {} });
    newVotes.forEach((v) => (v.t = times[v.b] || 0));
    newPVotes.forEach((v) => (v.t = times[v.b] || 0));
    [...Object.values(idx.polls), ...Object.values(idx.preds)].forEach((p) => { if (!p.t && times[p.block]) p.t = times[p.block]; });
    const who = [...new Set([...newVotes.map((v) => v.voter), ...newPVotes.map((v) => v.voter), ...Object.values(idx.polls).map((p) => p.creator), ...Object.values(idx.preds).map((p) => p.creator)])].filter((a) => !(a in idx.handles));
    await pool(who, 6, async (a) => { idx.handles[a] = await handleOf(a); });
    idx.lastBlock = ranges[ranges.length - 1][1];
    if (s) { try { await s.setJSON("index", idx); } catch {} }
  }
  idx.head = head;
  idx.syncing = idx.lastBlock < head;
  mem = idx; memAt = Date.now();
  return idx;
}

/** Poll objects in the same shape the verdict logic expects, with tallies counted from vote events. */
export function pollsFrom(idx) {
  const out = {};
  for (const p of Object.values(idx.polls)) out[p.id] = { ...p, tallies: p.options.map(() => 0), totalVotes: 0, createdAt: p.t || 0 };
  for (const v of idx.votes) { const p = out[v.p]; if (p && p.tallies[v.o] !== undefined) { p.tallies[v.o]++; p.totalVotes++; } }
  return out;
}

export const handleName = (idx, a) => idx.handles[a] || "";
// Public output shows an Agent ID name OR a shortened address, never a name next to a full wallet address:
// the hackathon rules forbid packaging Agent ID as a way to look up other people's wallets by name.
const label = (idx, a) => handleName(idx, a) || shortAddr(a);
export const shortAddr = (a) => a.slice(0, 6) + "…" + a.slice(-4);

// --- weekly league
export function isoWeek(sec) {
  const d = new Date(sec * 1000), day = (d.getUTCDay() + 6) % 7;
  const monday = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - day) / 1000;
  const th = new Date((monday + 3 * 86400) * 1000), y = th.getUTCFullYear();
  const jan4 = Date.UTC(y, 0, 4) / 1000, jan4Mon = jan4 - ((new Date(jan4 * 1000).getUTCDay() + 6) % 7) * 86400;
  return { key: `${y}-W${String(Math.round((monday - jan4Mon) / 604800) + 1).padStart(2, "0")}`, start: monday, end: monday + 604800 };
}

export const SCORING = { vote: 1, match: 2, predict: 1, correct: 3 };

/** Daily streaks (UTC days with at least one vote). A streak stays alive until a whole day passes with no vote. */
export function streaks(idx, nowSec = Math.floor(Date.now() / 1000)) {
  const days = {};
  for (const v of [...idx.votes, ...(idx.pvotes || [])]) (days[v.voter] ||= new Set()).add(Math.floor((v.t || nowSec) / 86400));
  const today = Math.floor(nowSec / 86400), out = {};
  for (const [voter, set] of Object.entries(days)) {
    const d = [...set].sort((a, b) => a - b);
    let best = 1, run = 1;
    for (let i = 1; i < d.length; i++) { run = d[i] === d[i - 1] + 1 ? run + 1 : 1; best = Math.max(best, run); }
    const last = d[d.length - 1];
    out[voter] = { streak: last >= today - 1 ? run : 0, best, votedToday: last === today, days: d.length };
  }
  return out;
}

/**
 * Points: 1 for every vote, plus 2 more when the poll closes with a clear crowd answer ("final") and you voted for it.
 * There is nothing to win and no money involved: it is a public record of who shows up and reads the crowd well.
 */
export function league(idx, { week = "current", nowSec = Math.floor(Date.now() / 1000), quorum = DEFAULT_QUORUM } = {}) {
  const polls = pollsFrom(idx);
  const winners = {};
  for (const p of Object.values(polls)) {
    const v = verdict(p, { quorum, nowSec });
    p.verdict = v;
    if (v.status === "final") winners[p.id] = p.tallies.indexOf(Math.max(...p.tallies));
  }
  const cur = isoWeek(nowSec);
  const wk = week === "current" ? cur : week === "all" ? null : null;
  let range = wk;
  if (week !== "current" && week !== "all") {
    const m = /^(\d{4})-W(\d{2})$/.exec(week);
    if (m) { // find the Monday of that ISO week
      const jan4 = Date.UTC(+m[1], 0, 4) / 1000, mon = jan4 - ((new Date(jan4 * 1000).getUTCDay() + 6) % 7) * 86400 + (+m[2] - 1) * 604800;
      range = { key: week, start: mon, end: mon + 604800 };
    }
  }
  const rows = {}, weeksOf = {};
  for (const v of idx.votes) {
    (weeksOf[v.voter] ||= new Set()).add(isoWeek(v.t || nowSec).key);
    if (range && !(v.t >= range.start && v.t < range.end)) continue;
    const r = (rows[v.voter] ||= { key: v.voter, who: label(idx, v.voter), named: !!handleName(idx, v.voter), points: 0, votes: 0, matches: 0 });
    r.votes++; r.points += SCORING.vote;
    if (winners[v.p] === v.o) { r.matches++; r.points += SCORING.match; }
  }
  // predictions: 1 point for each one you answer, 3 more when reality agrees with you (settled by Chainlink)
  for (const v of idx.pvotes || []) {
    (weeksOf[v.voter] ||= new Set()).add(isoWeek(v.t || nowSec).key);
    if (range && !(v.t >= range.start && v.t < range.end)) continue;
    const r = (rows[v.voter] ||= { key: v.voter, who: label(idx, v.voter), named: !!handleName(idx, v.voter), points: 0, votes: 0, matches: 0 });
    r.predictions = (r.predictions || 0) + 1; r.points += SCORING.predict;
    const s = idx.preds[v.p]?.settled;
    if (s && s.above === v.above) { r.correct = (r.correct || 0) + 1; r.points += SCORING.correct; }
  }
  const st = streaks(idx, nowSec);
  const leaders = Object.values(rows)
    .map((r) => ({ predictions: 0, correct: 0, ...r, weeks: weeksOf[r.key]?.size || 0, streak: st[r.key]?.streak || 0, bestStreak: st[r.key]?.best || 0 }))
    .sort((a, b) => b.points - a.points || b.matches - a.matches || b.weeks - a.weeks || a.key.localeCompare(b.key))
    .map(({ key, ...r }) => r);
  leaders.forEach((r, i) => (r.rank = i && leaders[i - 1].points === r.points && leaders[i - 1].matches === r.matches ? leaders[i - 1].rank : i + 1));
  const inWeek = (p) => range ? (p.endsAt >= range.start && (p.t || 0) < range.end) : true;
  const questions = Object.values(polls).filter(inWeek).sort((a, b) => b.id - a.id).map((p) => ({
    poll: p.id, question_UNTRUSTED: p.question, options_UNTRUSTED: p.options, tallies: p.tallies, verifiedVoters: p.totalVotes,
    endsAt: p.endsAt, open: p.verdict.open, status: p.verdict.status, creator: label(idx, p.creator),
  }));
  return {
    week: range ? range.key : "all", weekStart: range?.start ?? null, weekEnd: range?.end ?? null, currentWeek: cur.key,
    players: leaders.length, leaders: leaders.slice(0, 100), questions, scoring: SCORING,
    streakLeaders: topStreaks(idx, st),
    rules: "1 point for every vote. 2 more points when a poll closes with a clear crowd answer and you voted for it. 1 point for every price prediction you answer, 3 more when the Chainlink price proves you right. One Agent ID, one entry. No prizes, no money: a public record of who shows up and reads the crowd well.",
  };
}

function topStreaks(idx, st, n = 10) {
  return Object.entries(st).filter(([, s]) => s.streak > 0)
    .sort((a, b) => b[1].streak - a[1].streak || b[1].best - a[1].best || a[0].localeCompare(b[0]))
    .slice(0, n).map(([a, s]) => ({ who: label(idx, a), streak: s.streak, best: s.best, votedToday: s.votedToday }));
}

/** Question of the Day: the newest poll from the project's own Agent ID, preferring one that is still open. */
export function today(idx, official, { nowSec = Math.floor(Date.now() / 1000), quorum = DEFAULT_QUORUM } = {}) {
  const polls = pollsFrom(idx);
  const mine = Object.values(polls).filter((p) => norm(p.creator) === norm(official)).sort((a, b) => b.id - a.id);
  const p = mine.find((x) => nowSec < x.endsAt) || mine[0];
  const st = streaks(idx, nowSec);
  const out = { streakLeaders: topStreaks(idx, st, 5), dayEndsAt: (Math.floor(nowSec / 86400) + 1) * 86400 };
  if (!p) return { poll: null, ...out };
  const v = verdict(p, { quorum, nowSec });
  return { poll: p.id, open: v.open, endsAt: p.endsAt, question_UNTRUSTED: p.question, options_UNTRUSTED: p.options, tallies: p.tallies,
    verifiedVoters: p.totalVotes, status: v.status, decided: v.decided, leading: v.leading, ...out };
}

/** Crowd checks about one contract (newest first), plus a one-word summary an agent can branch on. */
export function checksFor(idx, contract, { nowSec = Math.floor(Date.now() / 1000), quorum = DEFAULT_QUORUM } = {}) {
  const polls = pollsFrom(idx), addr = norm(contract);
  const list = Object.values(polls).filter((p) => parseCheck(p.question) === addr || mentions(p.question, addr)).sort((a, b) => b.id - a.id).map((p) => {
    const v = verdict(p, { quorum, nowSec });
    const winner = v.decided && v.leading ? v.leading.index : null;
    return { poll: p.id, crowdCheck: parseCheck(p.question) === addr, open: v.open, endsAt: p.endsAt, status: v.status, decided: v.decided,
      verifiedVoters: p.totalVotes, question_UNTRUSTED: p.question, options_UNTRUSTED: p.options, tallies: p.tallies,
      answer: winner === null ? null : { index: winner, text_UNTRUSTED: p.options[winner], share: v.leading.share }, signal: signalOf(p.options, winner) };
  });
  const decided = list.find((c) => c.decided);
  const open = list.find((c) => c.open);
  const signal = decided ? decided.signal : open ? "pending" : list.length ? "no_answer" : "no_check";
  return { contract: addr, signal, basedOnPoll: decided ? decided.poll : open ? open.poll : null, checks: list };
}

/** The newest crowd-check polls. */
export function recentChecks(idx, { limit = 12, nowSec = Math.floor(Date.now() / 1000), quorum = DEFAULT_QUORUM } = {}) {
  return Object.values(pollsFrom(idx)).filter((p) => parseCheck(p.question)).sort((a, b) => b.id - a.id).slice(0, limit).map((p) => {
    const v = verdict(p, { quorum, nowSec }), winner = v.decided && v.leading ? v.leading.index : null;
    return { poll: p.id, contract: parseCheck(p.question), open: v.open, endsAt: p.endsAt, status: v.status, verifiedVoters: p.totalVotes,
      question_UNTRUSTED: p.question, options_UNTRUSTED: p.options, tallies: p.tallies, signal: signalOf(p.options, winner) };
  });
}

/** Latest events for the vote wall, newest last. */
export function events(idx, { since = 0, limit = 60 } = {}) {
  const polls = idx.polls, out = [];
  for (const p of Object.values(polls)) if (p.block > since) out.push({ type: "poll", poll: p.id, block: p.block, time: p.t || 0, who: label(idx, p.creator), handle: handleName(idx, p.creator), question_UNTRUSTED: p.question, tx: p.tx });
  for (const v of idx.votes) if (v.b > since) {
    const p = polls[v.p];
    out.push({ type: "vote", poll: v.p, block: v.b, time: v.t || 0, who: label(idx, v.voter), handle: handleName(idx, v.voter), option: v.o, optionText_UNTRUSTED: p?.options[v.o] ?? "", question_UNTRUSTED: p?.question ?? "", tx: v.tx });
  }
  out.sort((a, b) => a.block - b.block || (a.type === "poll" ? -1 : 1));
  return out.slice(-limit);
}

// --- predictions ("Will BNB be above $X at time T?"), settled on-chain from Chainlink
export const fmtUsd = (v) => { const n = Number(BigInt(v)) / 1e8; return "$" + n.toLocaleString("en-US", { minimumFractionDigits: Number.isInteger(n) ? 0 : 2, maximumFractionDigits: 2 }); };
export function predictionStatus(p, nowSec) {
  if (p.settled) return "settled";
  if (nowSec < p.votingEndsAt) return "voting";
  if (nowSec < p.checkAt) return "waiting";
  return "ready_to_settle";
}
export function predictionsList(idx, { nowSec = Math.floor(Date.now() / 1000), limit = 50 } = {}) {
  const tally = {};
  for (const v of idx.pvotes || []) { const t = (tally[v.p] ||= { yes: 0, no: 0 }); v.above ? t.yes++ : t.no++; }
  return Object.values(idx.preds || {}).sort((a, b) => b.id - a.id).slice(0, limit).map((p) => {
    const t = tally[p.id] || { yes: 0, no: 0 }, total = t.yes + t.no, status = predictionStatus(p, nowSec);
    const crowd = total ? (t.yes > t.no ? "above" : t.no > t.yes ? "not_above" : "split") : null;
    const reality = p.settled ? (p.settled.above ? "above" : "not_above") : null;
    return {
      id: p.id, asset: ASSETS[p.asset], assetIndex: p.asset, strike: p.strike, strikeUsd: fmtUsd(p.strike),
      question: `Will ${ASSETS[p.asset]}/USD be above ${fmtUsd(p.strike)} at ${new Date(p.checkAt * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC?`,
      votingEndsAt: p.votingEndsAt, checkAt: p.checkAt, status, yes: t.yes, no: t.no, verifiedVoters: total, crowd,
      settled: p.settled ? { price: p.settled.price, priceUsd: fmtUsd(p.settled.price), round: p.settled.round, above: p.settled.above, tx: p.settled.tx } : null,
      crowdWasRight: reality && crowd && crowd !== "split" ? crowd === reality : null, creator: label(idx, p.creator),
    };
  });
}
/** How often the crowd's majority was right about settled predictions. */
export function crowdRecord(list) {
  const done = list.filter((p) => p.crowdWasRight !== null);
  return { settled: done.length, crowdRight: done.filter((p) => p.crowdWasRight).length };
}

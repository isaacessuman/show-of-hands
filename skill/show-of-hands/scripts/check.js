// Crowd Check: a poll that asks verified humans whether one contract on BNB Chain looks safe.
// Pure helpers shared by the site, the API and the skill. No network.

export const CHECK = {
  en: { q: (addr, name) => `Crowd check: is ${name ? name + " " : "this contract "}(${addr}) on BNB Chain safe to use?`, options: ["Looks safe", "Not sure", "Avoid"] },
  zh: { q: (addr, name) => `众人鉴定：BNB Chain 上的${name ? " " + name + " " : "这个合约"}(${addr}) 安全吗？`, options: ["看起来安全", "不确定", "避开"] },
};
const SIGNALS = ["looks_safe", "not_sure", "avoid"];
const ADDR = /0x[0-9a-fA-F]{40}/;

export const isAddress = (s) => /^0x[0-9a-fA-F]{40}$/.test(String(s || "").trim());
export const norm = (a) => String(a).trim().toLowerCase();

/** The contract a poll asks about, or null. A crowd check starts with "Crowd check" / "众人鉴定" and names one address. */
export function parseCheck(question) {
  const q = String(question || "");
  if (!/^\s*(crowd check|众人鉴定)/i.test(q)) return null;
  const m = q.match(ADDR);
  return m ? norm(m[0]) : null;
}

/** Does a poll mention this contract at all (a crowd check, or any other question naming it)? */
export const mentions = (question, addr) => String(question || "").toLowerCase().includes(norm(addr));

/** Map the winning option to a signal when the poll uses the standard answers; otherwise "see_answer". */
export function signalOf(options, winner) {
  if (winner === null || winner === undefined || winner < 0) return null;
  for (const L of Object.values(CHECK)) {
    if (options.length === L.options.length && options.every((o, i) => o.trim().toLowerCase() === L.options[i].toLowerCase())) return SIGNALS[winner];
  }
  return "see_answer";
}

/** Clean a project name for the template: short, single line, no addresses, no control characters. */
export function cleanName(name) {
  return String(name || "").replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, " ").replace(ADDR, "").replace(/[()]/g, "").replace(/\s+/g, " ").trim().slice(0, 40);
}

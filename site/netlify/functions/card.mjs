// GET /api/card/<poll>.png — a live 1200x630 image of one poll, used as the X / Telegram link preview.
import { existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Resvg } from "@resvg/resvg-js";
import { cardSvg } from "../../lib/card.mjs";
import { getPoll, pollCount } from "./api.mjs";

function fontDir() {
  const here = (() => { try { return dirname(fileURLToPath(import.meta.url)); } catch { return ""; } })();
  const c = [join(process.cwd(), "netlify/fonts"), join(process.cwd(), "site/netlify/fonts"), here && join(here, "../fonts"), here && join(here, "netlify/fonts"), "/var/task/netlify/fonts", "/var/task/site/netlify/fonts"].filter(Boolean);
  return c.find((d) => existsSync(join(d, "card-sans.ttf")));
}
let fonts;

export default async (req) => {
  const m = /\/api\/card\/(\d{1,9})\.png$/.exec(new URL(req.url).pathname);
  if (!m) return new Response("Use /api/card/<poll>.png", { status: 400 });
  try {
    const id = Number(m[1]);
    if (id >= (await pollCount())) return new Response("No such poll", { status: 404 });
    const poll = await getPoll(id);
    if (!fonts) { const d = fontDir(); fonts = d ? readdirSync(d).filter((f) => f.endsWith(".ttf")).map((f) => join(d, f)) : []; }
    const host = new URL(req.url).host.replace(/^www\./, "");
    const png = new Resvg(cardSvg(poll, { host }), { fitTo: { mode: "width", value: 1200 }, font: { fontFiles: fonts, loadSystemFonts: false, defaultFontFamily: "SOH Sans" } }).render().asPng();
    return new Response(png, { headers: { "content-type": "image/png", "cache-control": "public, max-age=60", "netlify-cdn-cache-control": "public, s-maxage=60, stale-while-revalidate=300", "access-control-allow-origin": "*" } });
  } catch (e) {
    return new Response("Could not draw this card right now.", { status: 502 });
  }
};

export const config = { path: "/api/card/*" };

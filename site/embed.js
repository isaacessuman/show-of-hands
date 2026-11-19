/* Show of Hands embed. Usage:
   <script src="https://showofhands-jushou.netlify.app/embed.js" data-poll="0" data-theme="dark" async></script>
   Options: data-poll (number or "latest"), data-theme ("dark" | "light"), data-lang ("en" | "zh"). */
(function () {
  var me = document.currentScript;
  if (!me) return;
  var origin = new URL(me.src).origin;
  var poll = (me.getAttribute("data-poll") || "latest").replace(/[^0-9a-z]/gi, "");
  var p = new URLSearchParams({ poll: poll });
  if (me.getAttribute("data-theme")) p.set("theme", me.getAttribute("data-theme"));
  if (me.getAttribute("data-lang")) p.set("lang", me.getAttribute("data-lang"));
  var f = document.createElement("iframe");
  f.src = origin + "/embed.html?" + p.toString();
  f.title = "Show of Hands poll";
  f.loading = "lazy";
  f.setAttribute("referrerpolicy", "strict-origin-when-cross-origin");
  f.style.cssText = "width:100%;max-width:520px;height:330px;border:0;display:block;color-scheme:normal;background:transparent";
  me.parentNode.insertBefore(f, me.nextSibling);
  window.addEventListener("message", function (e) {
    if (e.origin !== origin || e.source !== f.contentWindow || !e.data || e.data.soh !== "height") return;
    var h = Number(e.data.h);
    if (h > 50 && h < 2000) f.style.height = h + "px";
  });
})();

// node site/src/build.mjs
// Writes site/changelog/**, site/docs/** and site/changelog/rss.xml from changelog.mjs and docs.mjs.
// No dependencies. The output is committed; Vercel serves site/ as static files.
import { mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import entries from "./changelog.mjs";
import { sections, pages } from "./docs.mjs";

const SITE = join(dirname(fileURLToPath(import.meta.url)), "..");

// Every version the changelog covers. "0.1.15 – 0.1.18" covers 0.1.15, 0.1.16, 0.1.17 and 0.1.18.
const covered = new Set(entries.flatMap((e) => {
  const [a, b = a] = e.versions.split(/\s*–\s*/);
  const [maj, min, lo] = a.split("."), hi = +b.split(".")[2];
  return Array.from({ length: hi - +lo + 1 }, (_, i) => `${maj}.${min}.${+lo + i}`);
}));

// node site/src/build.mjs --check 0.1.20: exit 1 unless the changelog has that version. release.sh runs it.
const ci = process.argv.indexOf("--check");
if (ci > 0) {
  const v = process.argv[ci + 1]?.replace(/^v/, "");
  if (!covered.has(v)) { console.error(`site/src/changelog.mjs has no entry for ${v}. Add one (or add it to the day's entry), then run node site/src/build.mjs and commit.`); process.exit(1); }
  process.exit(0);
}
const ORIGIN = "https://www.runmaxwell.com";
const GH = "https://github.com/robinsadeghpour/maxwell";

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const strip = (h) => h.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
const slugify = (s) => strip(s).toLowerCase().replace(/&amp;/g, "and").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const fmtDate = (d) => new Date(d + "T12:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });

function write(rel, html) {
  const p = join(SITE, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, html);
}

const ICONS = `<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <symbol id="demon" viewBox="0 0 7 7"><path fill="currentColor" d="M0 0h1v1H0zM6 0h1v1H6zM0 1h2v1H0zM5 1h2v1H5zM1 2h5v1H1zM1 3h1v1H1zM3 3h1v1H3zM5 3h1v1H5zM1 4h5v1H1zM2 5h3v1H2zM2 6h1v1H2zM4 6h1v1H4z"/></symbol>
  <symbol id="gh" viewBox="0 0 16 16"><path fill="currentColor" d="M8 0a8 8 0 0 0-2.5 15.6c.4 0 .5-.2.5-.4v-1.5c-2.2.5-2.7-1-2.7-1-.4-.9-.9-1.2-.9-1.2-.7-.5.1-.5.1-.5.8.1 1.2.8 1.2.8.7 1.3 1.9.9 2.3.7.1-.5.3-.9.5-1.1-1.8-.2-3.6-.9-3.6-4 0-.9.3-1.6.8-2.1-.1-.2-.4-1 .1-2.1 0 0 .7-.2 2.2.8a7.5 7.5 0 0 1 4 0c1.5-1 2.2-.8 2.2-.8.4 1.1.2 1.9.1 2.1.5.6.8 1.3.8 2.1 0 3.1-1.9 3.8-3.6 4 .3.3.6.8.6 1.5v2.2c0 .2.1.5.6.4A8 8 0 0 0 8 0Z"/></symbol>
  <symbol id="rss" viewBox="0 0 16 16"><path fill="currentColor" d="M2 2.5a.5.5 0 0 1 .5-.5A11.5 11.5 0 0 1 14 13.5a.5.5 0 0 1-1 0A10.5 10.5 0 0 0 2.5 3a.5.5 0 0 1-.5-.5Zm0 4.5a.5.5 0 0 1 .5-.5 7 7 0 0 1 7 7 .5.5 0 0 1-1 0 6 6 0 0 0-6-6A.5.5 0 0 1 2 7Zm1.5 4a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Z"/></symbol>
  <symbol id="find" viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1.5" d="M7 12.5a5.5 5.5 0 1 0 0-11 5.5 5.5 0 0 0 0 11Zm4-1.5 3.5 3.5"/></symbol>
</svg>`;

const FAVICON = `data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='-1 -1 9 9'%3E%3Crect x='-1' y='-1' width='9' height='9' rx='2' fill='%230a0a0b'/%3E%3Cpath fill='%23ededef' d='M0 0h1v1H0zM6 0h1v1H6zM0 1h2v1H0zM5 1h2v1H5zM1 2h5v1H1zM1 3h1v1H1zM3 3h1v1H3zM5 3h1v1H5zM1 4h5v1H1zM2 5h3v1H2zM2 6h1v1H2zM4 6h1v1H4z'/%3E%3Cpath fill='%23f0a33a' d='M2 3h1v1H2zM4 3h1v1H4z'/%3E%3C/svg%3E`;

const band = (inner, attrs = "") => `<div class="band"${attrs}><div class="frame"><i class="x l"></i><i class="x r"></i>${inner}</div></div>`;

function shell({ title, description, path, current, body, script = "" }) {
  const url = ORIGIN + path;
  const nav = [["/#features", "Features", "hide-s"], ["/docs", "Docs"], ["/changelog", "Changelog"], [GH, "GitHub", "hide-s"]]
    .map(([h, t, c]) => `<a${c ? ` class="${c}"` : ""} href="${h}"${current === t ? ' aria-current="page"' : ""}>${t}</a>`).join("");
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:image" content="${ORIGIN}/og.png">
<meta property="og:type" content="website">
<meta property="og:url" content="${url}">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="#0a0a0b">
<link rel="canonical" href="${url}">
<link rel="alternate" type="application/rss+xml" title="Maxwell changelog" href="/changelog/rss.xml">
<link rel="icon" href="${FAVICON}">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500&family=JetBrains+Mono:wght@400;500&display=swap">
<link rel="stylesheet" href="/assets/pages.css">
</head>
<body>
${ICONS}
<main>
  <div class="band" style="border-top:0"><div class="frame">
    <header class="nav"><a href="/"><svg aria-hidden="true"><use href="#demon"/></svg>Maxwell</a><nav>${nav}</nav></header>
  </div></div>
${body}
${band(`<footer class="foot"><span>Maxwell is free and open source under the MIT licence. Named after Maxwell's demon.</span><nav><a href="/docs">Docs</a><a href="/changelog">Changelog</a><a href="${GH}">GitHub</a><a href="${GH}/releases">Releases</a></nav></footer>`)}
</main>
${script}
</body>
</html>
`;
}

/* ---------------- changelog ---------------- */

function entryHTML(e, { linkTitle }) {
  const vers = `v${e.versions.replace(" – ", " – v")}`;
  const title = linkTitle ? `<a href="/changelog/${e.slug}">${e.title}</a>` : e.title;
  return band(`<section class="entry" id="${e.slug}">
  <aside><div><time datetime="${e.date}">${fmtDate(e.date)}</time><span class="ver">${vers}</span></div></aside>
  <article>
    <h2>${title}</h2>
    ${e.figure}
    <div class="prose">${e.body.trim()}</div>
    ${e.figure2 ? `<div style="margin-top:28px">${e.figure2}</div>` : ""}
    ${e.fixes?.length ? `<div class="fixes"><h4>Fixes and improvements</h4><ul>${e.fixes.map((f) => `<li><span>${f}</span></li>`).join("")}</ul></div>` : ""}
  </article>
</section>`);
}

const clHeader = band(`<header class="ph">
  <div><h1>Changelog</h1><p>New features, fixes and improvements in Maxwell. Installed copies offer each release as Restart to update.</p></div>
  <div class="subs"><a class="pill" href="/changelog/rss.xml"><svg aria-hidden="true"><use href="#rss"/></svg>RSS</a><a class="pill" href="${GH}/releases"><svg aria-hidden="true"><use href="#gh"/></svg>Releases</a></div>
</header>`);

write("changelog/index.html", shell({
  title: "Changelog · Maxwell",
  description: "New features, fixes and improvements in Maxwell, the session manager for Claude Code.",
  path: "/changelog", current: "Changelog",
  body: clHeader + entries.map((e) => entryHTML(e, { linkTitle: true })).join("\n"),
}));

entries.forEach((e, i) => {
  const newer = entries[i - 1], older = entries[i + 1];
  const pager = band(`<nav class="pager">${older ? `<a href="/changelog/${older.slug}"><small>Older</small>${older.title}</a>` : "<span></span>"}${newer ? `<a class="nx" href="/changelog/${newer.slug}"><small>Newer</small>${newer.title}</a>` : `<a class="nx" href="/changelog"><small>All updates</small>Changelog</a>`}</nav>`);
  write(`changelog/${e.slug}/index.html`, shell({
    title: `${e.title} · Maxwell changelog`,
    description: strip(e.body).split(". ")[0] + ".",
    path: `/changelog/${e.slug}`, current: "Changelog",
    body: band(`<div class="crumb" style="padding:28px clamp(20px,5vw,64px) 0;margin:0"><a href="/changelog">Changelog</a><span>/</span><span>${fmtDate(e.date)}</span></div>`, ' style="border-top:0"') + entryHTML(e, { linkTitle: false }) + pager,
  }));
});

write("changelog/rss.xml", `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
<title>Maxwell changelog</title>
<link>${ORIGIN}/changelog</link>
<atom:link href="${ORIGIN}/changelog/rss.xml" rel="self" type="application/rss+xml"/>
<description>New features, fixes and improvements in Maxwell.</description>
${entries.map((e) => `<item>
<title>${esc(e.title)}</title>
<link>${ORIGIN}/changelog/${e.slug}</link>
<guid>${ORIGIN}/changelog/${e.slug}</guid>
<pubDate>${new Date(e.date + "T12:00:00Z").toUTCString()}</pubDate>
<description>${esc(e.body.trim() + (e.fixes?.length ? `<h4>Fixes and improvements</h4><ul>${e.fixes.map((f) => `<li>${f}</li>`).join("")}</ul>` : ""))}</description>
</item>`).join("\n")}
</channel>
</rss>
`);

/* ---------------- docs ---------------- */

const order = sections.flatMap((s) => s.pages.map((slug) => ({ slug, section: s.title })));
for (const { slug } of order) if (!pages[slug]) throw new Error(`docs: no page "${slug}"`);

// ids and hover anchors on h2/h3; collect h2s for the TOC
function anchorize(html) {
  const toc = [], seen = new Set();
  const out = html.replace(/<h([23])>([\s\S]*?)<\/h\1>/g, (_, n, inner) => {
    let id = slugify(inner), i = 2;
    while (seen.has(id)) id = `${slugify(inner)}-${i++}`;
    seen.add(id);
    if (n === "2") toc.push({ id, text: strip(inner) });
    return `<h${n} id="${id}"><a class="anchor" href="#${id}" aria-label="Link to this section">#</a>${inner}</h${n}>`;
  });
  return { html: out, toc };
}

const searchIndex = [];
for (const { slug, section } of order) {
  const p = pages[slug];
  searchIndex.push({ t: p.title, s: section, u: `/docs/${slug}`, x: strip(p.lede) });
  for (const h of anchorize(p.body).toc) searchIndex.push({ t: h.text, s: `${section} › ${p.title}`, u: `/docs/${slug}#${h.id}`, x: "" });
}

const sidebar = (currentSlug) => `<div class="side-in">
  <div class="search"><button type="button" data-search><svg aria-hidden="true"><use href="#find"/></svg>Search docs<kbd>/</kbd></button></div>
  ${sections.map((s) => `<h6>${s.title}</h6><ul>${s.pages.map((slug) => `<li><a href="/docs/${slug}"${slug === currentSlug ? ' aria-current="page"' : ""}>${pages[slug].title}</a></li>`).join("")}</ul>`).join("")}
</div>`;

const docsScript = `<dialog class="sd" aria-label="Search docs"><input type="search" placeholder="Search docs" aria-label="Search docs" autocomplete="off" spellcheck="false"><ul role="listbox"></ul></dialog>
<script>
(() => {
  const IDX = ${JSON.stringify(searchIndex)};
  const dlg = document.querySelector("dialog.sd"), input = dlg.querySelector("input"), list = dlg.querySelector("ul");
  let hits = [], sel = 0;
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  function render() {
    const q = input.value.trim().toLowerCase();
    hits = (q ? IDX.map((d) => {
      const t = d.t.toLowerCase(), x = (d.x + " " + d.s).toLowerCase();
      const score = t.startsWith(q) ? 3 : t.includes(q) ? 2 : x.includes(q) ? 1 : 0;
      return [score, d];
    }).filter(([s]) => s).sort((a, b) => b[0] - a[0]).map(([, d]) => d) : IDX.filter((d) => !d.u.includes("#"))).slice(0, 12);
    sel = Math.min(sel, Math.max(hits.length - 1, 0));
    list.innerHTML = hits.length ? hits.map((d, i) => '<li><a role="option" href="' + d.u + '" aria-selected="' + (i === sel) + '">' + esc(d.t) + "<small>" + esc(d.s) + "</small></a></li>").join("") : '<li class="none">Nothing matches.</li>';
  }
  function open() { if (dlg.open) return; input.value = ""; sel = 0; render(); dlg.showModal(); input.focus(); }
  document.querySelectorAll("[data-search]").forEach((b) => b.addEventListener("click", open));
  document.addEventListener("keydown", (e) => {
    const typing = /INPUT|TEXTAREA/.test(document.activeElement?.tagName);
    if ((e.key === "/" && !typing) || (e.key === "k" && (e.metaKey || e.ctrlKey))) { e.preventDefault(); open(); }
  });
  input.addEventListener("input", () => { sel = 0; render(); });
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); sel = (sel + (e.key === "ArrowDown" ? 1 : -1) + hits.length) % Math.max(hits.length, 1); render(); list.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: "nearest" }); }
    if (e.key === "Enter" && hits[sel]) { location.href = hits[sel].u; dlg.close(); }
  });
  dlg.addEventListener("click", (e) => { if (e.target === dlg) dlg.close(); });
  const links = [...document.querySelectorAll(".toc a")];
  if (links.length && "IntersectionObserver" in window) {
    const heads = links.map((a) => document.getElementById(a.hash.slice(1)));
    const mark = () => {
      let cur = heads[0];
      for (const h of heads) if (h.getBoundingClientRect().top < 120) cur = h;
      links.forEach((a, i) => a.classList.toggle("on", heads[i] === cur));
    };
    addEventListener("scroll", mark, { passive: true }); mark();
  }
})();
</script>`;

function docLayout(currentSlug, main, toc = []) {
  const tocHTML = toc.length ? `<aside class="toc"><div><h6>On this page</h6><ul>${toc.map((h) => `<li><a href="#${h.id}">${esc(h.text)}</a></li>`).join("")}</ul></div></aside>` : "";
  return band(`<details class="menu-s"><summary>Menu</summary>${sidebar(currentSlug)}</details><div class="docs${toc.length ? "" : " wide"}"><nav class="side" aria-label="Docs">${sidebar(currentSlug)}</nav>${main}${tocHTML}</div>`);
}

rmSync(join(SITE, "docs"), { recursive: true, force: true });

order.forEach(({ slug, section }, i) => {
  const p = pages[slug];
  const { html, toc } = anchorize(p.body.trim());
  const prev = order[i - 1], next = order[i + 1];
  const cards = `<div class="cards">${prev ? `<a href="/docs/${prev.slug}"><small>Previous</small><b>${pages[prev.slug].title}</b></a>` : ""}${next ? `<a class="nx" href="/docs/${next.slug}"><small>Next</small><b>${pages[next.slug].title}</b></a>` : ""}</div>`;
  const main = `<article class="doc"><div class="inner">
    <div class="crumb"><a href="/docs">Docs</a><span>/</span><span>${section}</span></div>
    <h1>${p.title}</h1>
    <p class="lede">${p.lede}</p>
    ${p.figure || ""}
    <div class="prose">${html}</div>
    ${cards}
    <p class="edit"><a href="${GH}/blob/main/site/src/docs.mjs">Edit this page on GitHub</a></p>
  </div></article>`;
  write(`docs/${slug}/index.html`, shell({
    title: `${p.title} · Maxwell docs`, description: strip(p.lede),
    path: `/docs/${slug}`, current: "Docs", body: docLayout(slug, main, toc), script: docsScript,
  }));
});

const home = `<article class="dh">
  <h1>Maxwell docs</h1>
  <p class="lede">Maxwell is a native Mac app for running many Claude Code sessions at once. It shows you what needs you, and lets you forget the rest.</p>
  <div class="quick">
    <a href="/docs/install"><small>01</small><b>Install</b><span>Download, open, install the hooks. Two minutes.</span></a>
    <a href="/docs/groups"><small>02</small><b>Read the groups</b><span>Six groups, and you only look at the first two.</span></a>
    <a href="/docs/safe-to-close"><small>03</small><b>Close with proof</b><span>The checks a session passes before it's safe.</span></a>
  </div>
  <div class="secs">${sections.map((s) => `<div><h2>${s.title}</h2><p>${s.blurb}</p><ul>${s.pages.map((slug) => `<li><a href="/docs/${slug}">${pages[slug].title}</a></li>`).join("")}</ul></div>`).join("")}</div>
</article>`;
write("docs/index.html", shell({
  title: "Docs · Maxwell", description: "How to install, use and extend Maxwell, the session manager for Claude Code.",
  path: "/docs", current: "Docs", body: docLayout(null, home), script: docsScript,
}));

// llms.txt: the docs as a plain index, for agents
write("llms.txt", `# Maxwell\n\n> The session manager for Claude Code. A native Mac app.\n\n${sections.map((s) => `## ${s.title}\n\n${s.pages.map((slug) => `- [${pages[slug].title}](${ORIGIN}/docs/${slug}): ${strip(pages[slug].lede)}`).join("\n")}`).join("\n\n")}\n\n## Changelog\n\n${entries.map((e) => `- [${e.title}](${ORIGIN}/changelog/${e.slug}) (${e.date}, v${e.versions})`).join("\n")}\n`);

/* ---------------- home page pill, sitemap, 404 ---------------- */

const latest = entries[0];
const homePath = join(SITE, "index.html");
const home0 = readFileSync(homePath, "utf8");
const pill = `<!-- latest -->\n      <a class="new" href="/changelog/${latest.slug}"><b>v${latest.versions.split(/\s*–\s*/).pop()}</b><span>${latest.title}</span><i aria-hidden="true">→</i></a>\n      <!-- /latest -->`;
if (!/<!-- latest -->[\s\S]*?<!-- \/latest -->/.test(home0)) throw new Error("index.html: no <!-- latest --> marker");
writeFileSync(homePath, home0.replace(/<!-- latest -->[\s\S]*?<!-- \/latest -->/, pill));

const urls = ["/", "/changelog", ...entries.map((e) => `/changelog/${e.slug}`), "/docs", ...order.map((o) => `/docs/${o.slug}`)];
write("sitemap.xml", `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((u) => `<url><loc>${ORIGIN}${u}</loc>${u.startsWith("/changelog/") ? `<lastmod>${entries.find((e) => u.endsWith(e.slug)).date}</lastmod>` : ""}</url>`).join("\n")}\n</urlset>\n`);
write("robots.txt", `User-agent: *\nAllow: /\nSitemap: ${ORIGIN}/sitemap.xml\n`);

write("404.html", shell({
  title: "Not found · Maxwell", description: "This page doesn't exist.", path: "/404", current: "",
  body: band(`<header class="ph" style="padding-bottom:96px"><div><p class="ver" style="display:inline-block;margin:0 0 18px">404</p><h1>Nothing here</h1><p>This page moved or never existed. The docs and the changelog are the best places to look.</p><div class="subs" style="margin-top:28px"><a class="pill" href="/docs">Docs</a><a class="pill" href="/changelog">Changelog</a><a class="pill" href="/">Home</a></div></div></header>`),
}));

// Releases on GitHub that the changelog doesn't mention yet (skipped without gh or network).
try {
  const tags = execFileSync("gh", ["release", "list", "-R", "robinsadeghpour/maxwell", "--limit", "100", "--json", "tagName", "--jq", ".[].tagName"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 8000 })
    .split("\n").filter(Boolean).map((t) => t.replace(/^v/, ""));
  const first = "0.1.12"; // the first public release; older tags were private builds
  const cmp = (a, b) => a.split(".").map(Number).reduce((r, n, i) => r || n - +b.split(".")[i], 0);
  const missing = tags.filter((t) => cmp(t, first) >= 0 && !covered.has(t));
  if (missing.length) console.warn(`Not in the changelog yet: ${missing.map((t) => "v" + t).join(", ")}`);
} catch {}

console.log(`changelog: ${entries.length} entries · docs: ${order.length} pages · home pill: ${latest.title}`);

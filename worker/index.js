// The download counter in front of https://conda.qiyuan.me (deploying it: wrangler.toml).
// Requests pass through to the R2 bucket unchanged; a package file served whole counts one
// download of its package; the channel's front page gets a Downloads column. Our own pipelines
// download from https://conda-ci.qiyuan.me, a second address of the same bucket; no route sends its
// requests here.

// <name>-<version>-<build>.conda: conda allows no '-' in a version or a build string.
const PACKAGE_FILE = /\/([^/]+)-[^/-]+-[^/-]+\.(?:conda|tar\.bz2)$/;
const FRONT_PAGE = new Set(["/", "/index.html"]);

const SCHEMA = ["CREATE TABLE IF NOT EXISTS downloads (package TEXT PRIMARY KEY, n INTEGER NOT NULL)"];
const COUNT = "INSERT INTO downloads (package, n) VALUES (?1, 1) ON CONFLICT (package) DO UPDATE SET n = n + 1";

export default {
  async fetch(request, env, ctx) {
    const path = new URL(request.url).pathname;
    if (request.method === "GET" && FRONT_PAGE.has(path)) return frontPage(request, env.DB);
    const response = await fetch(request);
    const name = request.method === "GET" && response.status === 200 && PACKAGE_FILE.exec(path)?.[1];
    if (name) ctx.waitUntil(count(env.DB, name));
    return response;
  },
};

// The tables are created on first use, and any batch may be the first.
async function batch(db, ...statements) {
  return (await db.batch([...SCHEMA.map((sql) => db.prepare(sql)), ...statements])).slice(SCHEMA.length);
}

async function count(db, name) {
  await batch(db, db.prepare(COUNT).bind(name));
}

async function frontPage(request, db) {
  // Unconditional, so a 304 can never hand the browser a page with yesterday's counts.
  const plain = new Request(request);
  plain.headers.delete("If-None-Match");
  plain.headers.delete("If-Modified-Since");
  const [response, counts] = await Promise.all([fetch(plain), downloadCounts(db)]);
  if (response.status !== 200 || !counts) return response;

  let name = "";
  const page = new HTMLRewriter()
    .on("th:nth-of-type(2)", { element: (th) => th.after('<th class="s">Downloads</th>', { html: true }) })
    .on("td.packagename", { element: () => { name = ""; }, text: (t) => { name += t.text; } })
    .on("td.version", {
      element: (td) => td.after(`<td class="s">${counts.get(name.trim()) ?? 0}</td>`, { html: true }),
    })
    .transform(response);
  const headers = new Headers(page.headers);
  headers.delete("ETag");
  headers.delete("Last-Modified");
  headers.set("Cache-Control", "no-cache");
  return new Response(page.body, { status: page.status, headers });
}

async function downloadCounts(db) {
  try {
    const [rows] = await batch(db, db.prepare("SELECT package, n FROM downloads"));
    return new Map(rows.results.map((r) => [r.package, r.n]));
  } catch (e) {
    console.error("download counts unavailable:", e); // the page still goes out, without the column
    return null;
  }
}

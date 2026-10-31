// The download counter in front of https://conda.qiyuan.me (RELEASE_CHECKLIST.md, "The channel
// host"). Requests pass through to the R2 bucket unchanged; a package file served whole counts one
// download of its package, unless counting is paused (while we release, so that our own CI's
// downloads are not counted); the channel's front page gets a Downloads column.

// <name>-<version>-<build>.conda: conda allows no '-' in a version or a build string.
const PACKAGE_FILE = /\/([^/]+)-[^/-]+-[^/-]+\.(?:conda|tar\.bz2)$/;
const FRONT_PAGE = new Set(["/", "/index.html"]);

// pause holds at most one row: counting is paused until that Unix time.
const SCHEMA = [
  "CREATE TABLE IF NOT EXISTS downloads (package TEXT PRIMARY KEY, n INTEGER NOT NULL)",
  "CREATE TABLE IF NOT EXISTS pause (id INTEGER PRIMARY KEY CHECK (id = 1), until INTEGER NOT NULL)",
];
const COUNT_UNLESS_PAUSED = `
  INSERT INTO downloads (package, n)
  SELECT ?1, 1 WHERE NOT EXISTS (SELECT 1 FROM pause WHERE until > unixepoch())
  ON CONFLICT (package) DO UPDATE SET n = n + 1`;

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
  await batch(db, db.prepare(COUNT_UNLESS_PAUSED).bind(name));
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

// The download counter in front of https://conda.qiyuan.me (RELEASE_CHECKLIST.md, "The channel
// host"). Requests pass through to the R2 bucket unchanged; a package file served whole counts one
// download of its package, unless it went to a GitHub-hosted runner (CI); the channel's front page
// gets a Downloads column.

// <name>-<version>-<build>.conda: conda allows no '-' in a version or a build string.
const PACKAGE_FILE = /\/([^/]+)-[^/-]+-[^/-]+\.(?:conda|tar\.bz2)$/;
const FRONT_PAGE = new Set(["/", "/index.html"]);
// The address ranges of GitHub-hosted runners, as https://api.github.com/meta names them. Only the
// IPv4 ones matter: the runners have no IPv6 (actions/runner-images#668).
const RUNNER_LISTS = ["actions", "actions_macos"];

// runner_ranges holds disjoint IPv4 ranges, so the one with the greatest lo <= an address is the
// only candidate to contain it.
const SCHEMA = [
  "CREATE TABLE IF NOT EXISTS downloads (package TEXT PRIMARY KEY, n INTEGER NOT NULL)",
  "CREATE TABLE IF NOT EXISTS runner_ranges (lo INTEGER PRIMARY KEY, hi INTEGER NOT NULL)",
];
const COUNT_UNLESS_RUNNER = `
  INSERT INTO downloads (package, n)
  SELECT ?1, 1 WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT hi FROM runner_ranges WHERE lo <= ?2 ORDER BY lo DESC LIMIT 1)
    WHERE hi >= ?2)
  ON CONFLICT (package) DO UPDATE SET n = n + 1`;

export default {
  async fetch(request, env, ctx) {
    const path = new URL(request.url).pathname;
    if (request.method === "GET" && FRONT_PAGE.has(path)) return frontPage(request, env.DB);
    const response = await fetch(request);
    const name = request.method === "GET" && response.status === 200 && PACKAGE_FILE.exec(path)?.[1];
    if (name) ctx.waitUntil(count(env.DB, name, ipv4(request.headers.get("CF-Connecting-IP"))));
    return response;
  },

  async scheduled(controller, env, ctx) {
    ctx.waitUntil(refreshRunnerRanges(env.DB));
  },
};

// The tables are created on first use, and any batch may be the first.
async function batch(db, ...statements) {
  return (await db.batch([...SCHEMA.map((sql) => db.prepare(sql)), ...statements])).slice(SCHEMA.length);
}

// An address that is not IPv4 (null) is never a runner's.
async function count(db, name, address) {
  await batch(db, db.prepare(COUNT_UNLESS_RUNNER).bind(name, address));
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

async function refreshRunnerRanges(db) {
  const response = await fetch("https://api.github.com/meta", {
    headers: { "User-Agent": "conda.qiyuan.me download counter" },
  });
  if (!response.ok) throw new Error(`api.github.com/meta: HTTP ${response.status}`);
  const meta = await response.json();
  const ranges = disjoint(RUNNER_LISTS.flatMap((list) => meta[list] ?? []).filter((c) => !c.includes(":")).map(cidrRange));
  // Keep the old list rather than store an empty one.
  if (!ranges.length) throw new Error(`api.github.com/meta: no IPv4 range in ${RUNNER_LISTS}`);
  // One batch is one transaction: readers see the old list or the new one, never a partial one.
  await batch(
    db,
    db.prepare("DELETE FROM runner_ranges"),
    db.prepare("INSERT INTO runner_ranges (lo, hi) SELECT value ->> 0, value ->> 1 FROM json_each(?1)")
      .bind(JSON.stringify(ranges)),
  );
}

function ipv4(ip) {
  const bytes = ip?.split(".") ?? [];
  return bytes.length === 4 ? bytes.reduce((x, b) => x * 256 + Number(b), 0) : null;
}

function cidrRange(cidr) {
  const [ip, length] = cidr.split("/");
  const size = 2 ** (32 - length);
  const lo = Math.floor(ipv4(ip) / size) * size;
  return [lo, lo + size - 1];
}

function disjoint(ranges) {
  ranges.sort((a, b) => a[0] - b[0]);
  const out = [];
  for (const [lo, hi] of ranges) {
    const last = out.at(-1);
    if (last && lo <= last[1] + 1) last[1] = Math.max(last[1], hi);
    else out.push([lo, hi]);
  }
  return out;
}

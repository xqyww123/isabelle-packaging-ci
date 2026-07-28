#!/usr/bin/env python3
"""Delete owner-selected superseded packages from conda.qiyuan.me without
downloading any package.

Design and review record: CONDA_CHANNEL_SWEEP_PLAN.md (MLML working tree, v2).
The channel's authoritative store is Cloudflare R2 bucket "conda"; per-subdir
metadata is exactly index.html + repodata.json + repodata_from_packages.json.

Usage (credentials must be in the environment, via a subshell so they do not
linger:  (source ~/Current/MLML/secret.sh && python3 sweep-old-versions.py ...)):

  sweep-old-versions.py selftest            # offline self-checks, no network
  sweep-old-versions.py plan [PLANFILE]     # compute candidates, write plan file
  sweep-old-versions.py execute PLANFILE    # validate selection, edit metadata,
                                            # push, delete files, verify
      [--confirm DELETE]                    # non-tty substitute for the prompt;
                                            # pass only after the owner approved
                                            # this exact plan file

A file is a *candidate* iff a strictly higher version (conda VersionOrder) of
the same package exists in the same subdir.  Version ties (07 == 7, 1.0 ==
1.0.0) all survive; the newest (or only) version of a package is never
deletable.  Only candidates may appear in the plan file; execute aborts on
anything else.

Every failure is an abort; the only irreversible step (deletefile) comes last,
after the owner's plan file and a typed DELETE confirmation.
"""

import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NoReturn

try:
    from conda.models.version import VersionOrder
    from conda.models.match_spec import MatchSpec
except ImportError:
    sys.exit(
        "error: this python cannot import conda.models — run under an "
        "environment with the `conda` package (see RELEASE_CHECKLIST.md, "
        "channel sweep section)."
    )

ENDPOINT = "https://532d99283b5aa1e02486ee3fdcb163d5.r2.cloudflarestorage.com"
BUCKET = "conda"
CHANNEL_URL = "https://conda.qiyuan.me"
SUBDIRS = ["noarch", "linux-64", "linux-aarch64", "osx-64", "osx-arm64", "win-64"]
METADATA_FILES = ["index.html", "repodata.json", "repodata_from_packages.json"]

# Every repo whose CI can write to the channel (concurrency gate 1).  A new
# publishing repo MUST be added here and in RELEASE_CHECKLIST.md.
PUBLISH_REPOS = [
    "xqyww123/Isa-Mini",
    "xqyww123/Isabelle-MCP",
    "xqyww123/Isabelle_RPC",
    "xqyww123/Isabelle_Semantic_Embedding",
    "xqyww123/auto_sledgehammer",
    "xqyww123/Performant_Isabelle_ML",
    "xqyww123/isabelle-packaging-ci",
]
PUBLISH_WORKFLOW_RE = re.compile(r"release|publish|conda|wheel", re.I)


def die(msg) -> NoReturn:
    sys.exit(f"ABORT: {msg}")


# ---------------------------------------------------------------- tooling


def find_rclone():
    import os

    rclone = os.environ.get("RCLONE") or shutil.which("rclone")
    if not rclone:
        die("rclone not found (set $RCLONE or PATH); needs >= 1.74, see checklist")
    out = subprocess.run([rclone, "version"], capture_output=True, text=True)
    m = re.search(r"rclone v(\d+)\.(\d+)", out.stdout)
    if not m or (int(m.group(1)), int(m.group(2))) < (1, 74):
        die(f"rclone >= 1.74 required (Ubuntu's 1.60 is broken against R2); got: "
            f"{out.stdout.splitlines()[0] if out.stdout else '?'}")
    return rclone


def rclone_env():
    import os

    ak = os.environ.get("CONDA_R2_ACCESS_KEY_ID")
    sk = os.environ.get("CONDA_R2_SECRET_ACCESS_KEY")
    if not ak or not sk:
        die("CONDA_R2_ACCESS_KEY_ID / CONDA_R2_SECRET_ACCESS_KEY not in the "
            "environment — run inside `(source ~/Current/MLML/secret.sh && ...)`")
    env = dict(os.environ)
    env.update(
        RCLONE_CONFIG_R2_TYPE="s3",
        RCLONE_CONFIG_R2_PROVIDER="Cloudflare",
        RCLONE_CONFIG_R2_REGION="auto",
        RCLONE_CONFIG_R2_ENDPOINT=ENDPOINT,
        RCLONE_CONFIG_R2_ACCESS_KEY_ID=ak,
        RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=sk,
    )
    return env


class R2:
    def __init__(self):
        self.rclone = find_rclone()
        self.env = rclone_env()

    def _run(self, *args, binary=False):
        r = subprocess.run(
            [self.rclone, *args, "--s3-no-check-bucket"],
            capture_output=True, env=self.env, text=not binary,
        )
        if r.returncode != 0:
            err = r.stderr if isinstance(r.stderr, str) else r.stderr.decode()
            die(f"rclone {' '.join(args)} failed (exit {r.returncode}):\n{err}")
        return r.stdout

    def lsf_timed(self, subdir):
        """[(mtime_str, filename)] for all files directly in the subdir."""
        out = self._run("lsf", f"R2:{BUCKET}/{subdir}/", "--files-only",
                        "--format", "tp")
        rows = []
        for line in out.splitlines():
            t, _, p = line.partition(";")
            if p:
                rows.append((t, p))
        return rows

    def cat(self, subdir, fn):
        return self._run("cat", f"R2:{BUCKET}/{subdir}/{fn}", binary=True)

    def push(self, local, subdir, fn):
        self._run("copyto", str(local), f"R2:{BUCKET}/{subdir}/{fn}")

    def exists(self, subdir, fn):
        out = self._run("lsf", f"R2:{BUCKET}/{subdir}/{fn}")
        return out.strip() == fn

    def deletefile(self, subdir, fn):
        self._run("deletefile", f"R2:{BUCKET}/{subdir}/{fn}")


# ------------------------------------------------- candidates & validation


def parse_conda_filename(fn):
    """{name}-{version}-{build}.conda -> (name, version, build)."""
    if not fn.endswith(".conda"):
        die(f"not a .conda filename: {fn}")
    stem = fn[: -len(".conda")]
    parts = stem.rsplit("-", 2)
    if len(parts) != 3 or not all(parts):
        die(f"cannot parse conda filename: {fn}")
    return tuple(parts)


def compute_candidates(files):
    """files: iterable of .conda filenames in ONE subdir.
    Returns {filename: newest_version} for every file whose version is
    STRICTLY below all maximal versions of its package.  Ties survive."""
    by_name = {}
    for fn in files:
        name, version, _build = parse_conda_filename(fn)
        by_name.setdefault(name, []).append((fn, version))
    out = {}
    for name, entries in by_name.items():
        maxv = max((VersionOrder(v) for _, v in entries))
        for fn, v in entries:
            if VersionOrder(v) < maxv:  # strict; ties are not candidates
                out[fn] = str(maxv)
    return out


def repodata_entries(parsed):
    return {**parsed.get("packages", {}), **parsed.get("packages.conda", {})}


# ------------------------------------------------------ concurrency gates


def gh_publish_runs(extra_json_fields=()):
    """All in_progress/queued publish-shaped runs across PUBLISH_REPOS."""
    hits = []
    for repo in PUBLISH_REPOS:
        for status in ("in_progress", "queued"):
            r = subprocess.run(
                ["gh", "run", "list", "-R", repo, "--status", status,
                 "--json", ",".join(("workflowName", "displayTitle", "createdAt")
                                    + tuple(extra_json_fields)),
                 "--limit", "20"],
                capture_output=True, text=True,
            )
            if r.returncode != 0:
                die(f"gh run list failed for {repo} — the publish gate must "
                    f"fail closed:\n{r.stderr}")
            for run in json.loads(r.stdout or "[]"):
                if PUBLISH_WORKFLOW_RE.search(run["workflowName"]):
                    hits.append((repo, run["workflowName"], run["displayTitle"]))
    return hits


def gate_no_publish_running(when):
    hits = gh_publish_runs()
    if hits:
        lines = "\n".join(f"  {r}: {w} ({t})" for r, w, t in hits)
        die(f"publish run in flight ({when}):\n{lines}\nretry after it finishes")
    print(f"gate[{when}]: no publish run in flight across {len(PUBLISH_REPOS)} repos")


def gate_modtime(r2, subdir):
    """No .conda may be newer than repodata.json: CI uploads packages first and
    pushes the index minutes later, so a newer .conda means a publish is in
    flight or died half-way.  Blind to publish re-runs (rclone copy skips
    already-present files), hence gate_no_publish_running is also mandatory."""
    rows = r2.lsf_timed(subdir)
    repot = dict((p, t) for t, p in rows).get("repodata.json")
    if repot is None:
        die(f"{subdir}: repodata.json missing on R2")
    newer = [p for t, p in rows if p.endswith(".conda") and t > repot]
    if newer:
        die(f"{subdir}: .conda newer than repodata.json (publish in flight or "
            f"failed half-way): {newer}")


def gh_publish_runs_since(start_iso):
    hits = []
    for repo in PUBLISH_REPOS:
        r = subprocess.run(
            ["gh", "run", "list", "-R", repo,
             "--json", "workflowName,createdAt,status", "--limit", "20"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            die(f"gh run list failed for {repo} (post-sweep check):\n{r.stderr}")
        for run in json.loads(r.stdout or "[]"):
            if (PUBLISH_WORKFLOW_RE.search(run["workflowName"])
                    and run["createdAt"] >= start_iso):
                hits.append((repo, run["workflowName"], run["status"]))
    return hits


# ------------------------------------------------------- metadata editing


def canonical(parsed):
    return json.dumps(parsed, sort_keys=True, separators=(",", ":")).encode()


def edit_repodata(baseline_bytes, selected, label):
    """Delete `selected` filenames' entries.  Returns (new_bytes, deleted_keys).
    Abort gates: removed==[], deleted == selected ∩ present (equality), and the
    semantic anchor: parse(edited) == parse(baseline) minus selected."""
    parsed = json.loads(baseline_bytes)
    if parsed.get("removed", []) != []:
        die(f"{label}: repodata 'removed' is non-empty — mechanism precondition "
            f"gone, fall back to the full re-index procedure")
    deleted = {}
    for section in ("packages", "packages.conda"):
        sec = parsed.get(section, {})
        for fn in list(sec):
            if fn in selected:
                deleted[fn] = sec.pop(fn)
    expected = set(selected) & set(repodata_entries(json.loads(baseline_bytes)))
    if set(deleted) != expected:
        die(f"{label}: deleted keys {sorted(deleted)} != plan∩present {sorted(expected)}")

    # style probe (never an abort): keep conda_index's byte style if we can
    style_ok = canonical(json.loads(baseline_bytes)) == baseline_bytes
    new_bytes = canonical(parsed)
    if not style_ok:
        print(f"note: {label}: baseline not in canonical style (conda-index "
              f"output changed); writing canonical JSON — harmless, no byte "
              f"consumer exists")

    # semantic anchor, on independently re-parsed bytes
    reparsed = json.loads(new_bytes)
    ref = json.loads(baseline_bytes)
    for section in ("packages", "packages.conda"):
        for fn in expected:
            ref.get(section, {}).pop(fn, None)
    if reparsed != ref:
        die(f"{label}: semantic anchor failed — edit affected something beyond "
            f"the selected entries")
    return new_bytes, deleted


def edit_index_html(baseline, selected, label):
    """Remove each selected file's whole <tr>...</tr> block by substring
    position (block boundaries share lines with neighbours)."""
    html = baseline.decode()
    removed_total = 0
    for fn in selected:
        needle = f'<a href="{fn}">'
        n = html.count(needle)
        if n == 0:
            print(f"note: {label}: {fn} not in index.html (already gone) — ok")
            continue
        if n != 1:
            die(f"{label}: {fn} appears {n} times in index.html")
        i = html.index(needle)
        start = html.rindex("<tr>", 0, i)
        end = html.index("</tr>", i) + len("</tr>")
        block = html[start:end]
        if block.count("<tr>") != 1 or block.count("</tr>") != 1:
            die(f"{label}: malformed <tr> block for {fn}")
        html = html[:start] + html[end:]
        removed_total += len(block)
    if len(html) + removed_total != len(baseline.decode()):
        die(f"{label}: index.html edit size mismatch")
    for fn in selected:
        if fn in html:
            die(f"{label}: {fn} still present in edited index.html")
    return html.encode()


# -------------------------------------------------------- dependency check


def check_dependencies(all_entries_by_subdir, selected_by_subdir):
    """Warning-level solvability check, not a full solver: for each platform,
    the surviving universe is platform ∪ noarch; every surviving entry's
    in-channel dependency must still have a satisfying version.  External
    (conda-forge) dependencies are skipped."""
    channel_names = set()
    for entries in all_entries_by_subdir.values():
        channel_names.update(e["name"] for e in entries.values())

    def surviving(subdir):
        sel = selected_by_subdir.get(subdir, set())
        return {fn: e for fn, e in all_entries_by_subdir[subdir].items()
                if fn not in sel}

    violations = []
    for subdir in SUBDIRS:
        if subdir == "noarch":
            continue
        universe = {**surviving("noarch"), **surviving(subdir)}
        for fn, e in universe.items():
            for spec_str in e.get("depends", []):
                try:
                    spec = MatchSpec(spec_str)
                except Exception:
                    print(f"note: unparsable spec {spec_str!r} in {fn} — skipped")
                    continue
                if spec.name not in channel_names:
                    continue
                ok = any(
                    spec.match({"name": c["name"], "version": c["version"],
                                "build": c.get("build", ""),
                                "build_number": c.get("build_number", 0)})
                    for c in universe.values() if c["name"] == spec.name
                )
                if not ok:
                    violations.append((subdir, fn, spec_str))
    if violations:
        lines = "\n".join(f"  {sd}: {fn} needs {sp}" for sd, fn, sp in violations)
        die(f"deletion would leave unsatisfiable in-channel dependencies "
            f"(owner must decide):\n{lines}")
    print("dependency check: all in-channel constraints still satisfiable "
          "(platform ∪ noarch, per platform)")


# ------------------------------------------------------------ subcommands


def load_channel(r2):
    """(conda_files_by_subdir, entries_by_subdir, baselines_by_subdir)."""
    files, entries, baselines = {}, {}, {}
    for sd in SUBDIRS:
        rows = r2.lsf_timed(sd)
        names = [p for _, p in rows]
        non_conda = sorted(n for n in names if not n.endswith(".conda"))
        if non_conda != sorted(METADATA_FILES):
            die(f"{sd}: metadata file set is {non_conda}, expected exactly "
                f"{sorted(METADATA_FILES)} — a new repodata variant appeared; "
                f"fall back to the full re-index procedure")
        files[sd] = [n for n in names if n.endswith(".conda")]
        baselines[sd] = {fn: r2.cat(sd, fn) for fn in METADATA_FILES}
        for fn in ("repodata.json", "repodata_from_packages.json"):
            if json.loads(baselines[sd][fn]).get("removed", []) != []:
                die(f"{sd}/{fn}: 'removed' is non-empty — mechanism precondition "
                    f"gone, fall back to the full re-index procedure")
        entries[sd] = repodata_entries(json.loads(baselines[sd]["repodata.json"]))
    return files, entries, baselines


def cross_check(files, entries):
    """Filename parse must agree with repodata wherever an entry exists.
    Prints coverage so a thinner guard rail on idempotent re-runs is visible."""
    covered = total = 0
    for sd, fns in files.items():
        for fn in fns:
            total += 1
            name, version, build = parse_conda_filename(fn)
            e = entries[sd].get(fn)
            if e is None:
                continue
            covered += 1
            if (e["name"], e["version"], e["build"]) != (name, version, build):
                die(f"{sd}/{fn}: filename parse {name} {version} {build} != "
                    f"repodata entry {e['name']} {e['version']} {e['build']}")
    print(f"cross-check: repodata entries covered {covered}/{total} files")


def cmd_plan(planfile):
    r2 = R2()
    files, entries, _ = load_channel(r2)
    cross_check(files, entries)
    lines = [
        "# sweep plan generated {}Z".format(
            datetime.datetime.now(datetime.timezone.utc)
            .strftime("%Y-%m-%d %H:%M:%S")),
        "# Every line is a CANDIDATE (a strictly newer version exists in the",
        "# same subdir).  DELETE the lines you do NOT want removed, keep the",
        "# rest, then run:  sweep-old-versions.py execute " + planfile,
    ]
    n = 0
    for sd in SUBDIRS:
        for fn, newest in sorted(compute_candidates(files[sd]).items()):
            lines.append(f"{sd}/{fn}    # superseded by {newest}")
            n += 1
    Path(planfile).write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"\n{n} candidate(s) written to {planfile}")


def read_plan(planfile):
    sel = {}
    for raw in Path(planfile).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        sd, _, fn = line.partition("/")
        if sd not in SUBDIRS or not fn:
            die(f"bad plan line: {raw!r}")
        sel.setdefault(sd, set()).add(fn)
    if not sel:
        die("plan file selects nothing")
    return sel


def confirm(selected, confirm_flag):
    print("\nFINAL DELETION LIST:")
    for sd in SUBDIRS:
        for fn in sorted(selected.get(sd, ())):
            print(f"  {sd}/{fn}")
    if sys.stdin.isatty():
        if input("\ntype DELETE to proceed: ") != "DELETE":
            die("not confirmed")
    elif confirm_flag != "DELETE":
        die("stdin is not a tty; pass --confirm DELETE (only after the owner "
            "approved this exact plan)")


def cmd_execute(planfile, confirm_flag):
    start_iso = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")
    selected = read_plan(planfile)
    r2 = R2()

    gate_no_publish_running("before execute")
    files, entries, baselines = load_channel(r2)
    for sd in selected:
        gate_modtime(r2, sd)
    cross_check(files, entries)

    # selection legality: every selected file must be a current candidate
    for sd, sel in selected.items():
        cands = compute_candidates(files[sd])
        bad = sel - set(cands)
        if bad:
            die(f"{sd}: not candidates (newest/only version, unknown, or "
                f"already gone — after an interruption, restart from `plan`): "
                f"{sorted(bad)}")

    # guard-rail visibility: on a re-run after a pushed-metadata interruption,
    # selected files have no repodata entry left to cross-check against
    sel_total = sum(len(s) for s in selected.values())
    sel_cov = sum(1 for sd, s in selected.items() for fn in s if fn in entries[sd])
    print(f"cross-check: repodata entries covered {sel_cov}/{sel_total} "
          f"selected files")

    check_dependencies(entries, selected)
    confirm(selected, confirm_flag)

    workdir = Path(tempfile.mkdtemp(prefix="sweep-"))
    log_rows = []
    for sd, sel in selected.items():
        base = baselines[sd]
        edited = {}
        for fn in ("repodata.json", "repodata_from_packages.json"):
            edited[fn], _ = edit_repodata(base[fn], sel, f"{sd}/{fn}")
        edited["index.html"] = edit_index_html(base["index.html"], sel,
                                               f"{sd}/index.html")

        # pre-push race window shrink: gate again, baseline must be unchanged
        gate_no_publish_running(f"before push {sd}")
        gate_modtime(r2, sd)
        if r2.cat(sd, "repodata.json") != base["repodata.json"]:
            die(f"{sd}: remote repodata changed since baseline — a publish "
                f"landed; rerun the sweep from scratch")

        # metadata first, package files after: fresh clients stop seeing the
        # old versions before any file disappears
        for fn in METADATA_FILES:
            p = workdir / sd / fn
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(edited[fn])
            r2.push(p, sd, fn)
        print(f"{sd}: metadata pushed")

        for fn in sorted(sel):
            if r2.exists(sd, fn):
                r2.deletefile(sd, fn)
                print(f"{sd}: deleted {fn}")
            else:
                print(f"{sd}: {fn} already absent — skipped")
            newest = compute_candidates(files[sd]).get(fn, "?")
            log_rows.append((sd, fn, newest))

    verify(r2, selected, baselines)

    late = gh_publish_runs_since(start_iso)
    if late:
        print(f"note: publish run(s) started during the sweep window: {late}\n"
              f"re-running external verification (absence only — a legitimate "
              f"new publish may have added entries)...")
        verify(r2, selected, baselines, strict=False)
        print("if a publish resurrected old files, simply rerun this sweep")

    today = start_iso[:10]
    print("\nRELEASE_CHECKLIST.md deletion-log rows "
          "(Package | Version | Subdir | Why | When):")
    for sd, fn, newest in log_rows:
        name, version, _build = parse_conda_filename(fn)
        print(f"| `{name}` | {version} | {sd} | owner-selected sweep; "
              f"superseded by {newest} | {today} |")


def verify(r2, selected, baselines, strict=True):
    """External verification anchored on the owner's plan (never on the edited
    artifacts): 404 per file; strict mode also demands live key set ==
    baseline keys − selection (non-strict only demands the selection absent —
    used after a legitimate publish may have added entries)."""
    for sd, sel in selected.items():
        for fn in sorted(sel):
            code = subprocess.run(
                ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                 f"{CHANNEL_URL}/{sd}/{fn}"],
                capture_output=True, text=True).stdout
            if code != "404":
                die(f"verify: {sd}/{fn} returned HTTP {code}, expected 404")
            if r2.exists(sd, fn):
                die(f"verify: {sd}/{fn} still on R2")
        live = subprocess.run(
            ["curl", "-fsS", f"{CHANNEL_URL}/{sd}/repodata.json"],
            capture_output=True).stdout
        live_keys = set(repodata_entries(json.loads(live)))
        base_keys = set(repodata_entries(
            json.loads(baselines[sd]["repodata.json"])))
        expected = base_keys - sel
        if strict and live_keys != expected:
            die(f"verify: {sd} live repodata keys differ from baseline−plan: "
                f"unexpected={sorted(live_keys - expected)} "
                f"missing={sorted(expected - live_keys)}")
        if not strict and (live_keys & sel):
            die(f"verify: {sd} selected entries resurfaced in live repodata: "
                f"{sorted(live_keys & sel)} — a publish resurrected them; "
                f"rerun the sweep")
        print(f"verify: {sd} ok ({len(sel)} gone, {len(expected)} intact)")


# ---------------------------------------------------------------- selftest


def cmd_selftest():
    # version ties survive: strict-less-than-all-maximal-elements
    assert VersionOrder("2026.07.26.1711") == VersionOrder("2026.7.26.1711")
    assert VersionOrder("1.0") == VersionOrder("1.0.0")
    c = compute_candidates([
        "p-2026.07.26.1711-h0_0.conda", "p-2026.7.26.1711-h1_0.conda",
        "p-2026.07.25-h0_0.conda",
        "q-1.0-a_0.conda", "q-1.0.0-b_0.conda",
        "rocksdict-0.3.29-py311_0.conda", "rocksdict-0.3.29-py314_0.conda",
        "only-1.0-x_0.conda",
    ])
    assert c == {"p-2026.07.25-h0_0.conda": "2026.07.26.1711"}, c

    # filename parsing, hyphenated names
    assert parse_conda_filename("isabelle-semantic-embedding-0.2.0-hb0f4dca_0.conda") \
        == ("isabelle-semantic-embedding", "0.2.0", "hb0f4dca_0")
    assert parse_conda_filename("isabelle-2025.2-0.conda") == ("isabelle", "2025.2", "0")

    # index.html block removal with same-line block boundaries (the real
    # channel's layout: `</tr>    <tr>` on one line)
    html = ('<table><tr>\n  <td><a href="a-1.0-x_0.conda">a</a></td>\n'
            '  <td>1</td></tr>    <tr>\n  <td><a href="a-2.0-x_0.conda">a</a>'
            '</td>\n  <td>2</td></tr></table>').encode()
    out = edit_index_html(html, {"a-1.0-x_0.conda"}, "selftest").decode()
    assert 'a-1.0-x_0.conda' not in out and 'a-2.0-x_0.conda' in out
    assert out.count("<tr>") == 1 and out.count("</tr>") == 1

    # surgical edit: semantic anchor + equality assertion + idempotent re-run
    base = canonical({
        "info": {"subdir": "noarch"},
        "packages": {},
        "packages.conda": {
            "a-1.0-x_0.conda": {"name": "a", "version": "1.0", "build": "x_0"},
            "a-2.0-x_0.conda": {"name": "a", "version": "2.0", "build": "x_0"}},
        "removed": [], "repodata_version": 1})
    new, deleted = edit_repodata(base, {"a-1.0-x_0.conda"}, "selftest")
    assert set(deleted) == {"a-1.0-x_0.conda"}
    assert set(repodata_entries(json.loads(new))) == {"a-2.0-x_0.conda"}
    # re-run on already-edited data: plan∩present is empty, nothing deleted
    new2, deleted2 = edit_repodata(new, {"a-1.0-x_0.conda"}, "selftest")
    assert deleted2 == {} and new2 == new
    print("selftest: all assertions passed")


def main():
    ap = argparse.ArgumentParser(
        description="Delete owner-selected superseded packages from "
                    "conda.qiyuan.me without downloading any package.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    p = sub.add_parser("plan")
    p.add_argument("planfile", nargs="?", default="sweep-plan.txt")
    e = sub.add_parser("execute")
    e.add_argument("planfile")
    e.add_argument("--confirm", default=None,
                   help="literal DELETE; non-tty substitute for the prompt")
    args = ap.parse_args()
    if args.cmd == "selftest":
        cmd_selftest()
    elif args.cmd == "plan":
        cmd_plan(args.planfile)
    else:
        cmd_execute(args.planfile, args.confirm)


if __name__ == "__main__":
    main()

# conda rollout — where we are

Companion to `RELEASE_CHECKLIST.md`. That file holds the durable rules; this one holds the
**current state and the decisions already made**, so a fresh session can resume without
re-litigating anything.

Last updated: 2026-10-04 — the fourth release wave (2026-10-03/04): performant-ml 0.2.0,
auto-sledgehammer 0.2.0, rpc 0.5.0 and 0.5.1, semantic-embedding 0.5.0, minilang 0.7.0,
isabelle-ai 0.3.0; see "Notes from the fourth wave". Between the second wave and this one
the table below had gone stale: rpc 0.4.1 (2026-08-08), semantic-embedding 0.3.0 and
minilang 0.6.0 (2026-07-26, the layered semantic DB), isabelle-ai 0.2.0, mcp 0.4.0 and
0.6.0, and the first `isabelle-semantic-data` were published without moving their rows.
conda is ahead of PyPI for every package with a PyPI presence (rpc publishes to conda
only since 0.4.1; the embedding package and minilang stayed at 0.2.0 and 0.5.0 on PyPI,
by the owner's decision of 2026-10-03).

---

## Published on https://conda.qiyuan.me

| Package | Version | Shape |
|---|---|---|
| `isabelle` | 2025.2 | per-platform, 5 subdirs (predates this rollout) |
| `isabelle-performant-ml` | 0.2.0 | noarch generic, two sessions (`Performant_Isabelle_ML`, `Performant_Isabelle_HOL`) + the prebuilt native library for 5 platforms |
| `auto-sledgehammer` | 0.2.0 | noarch generic, session |
| `isabelle-rpc` | 0.5.1 | noarch python, session + Python host; conda only since 0.4.1 (PyPI stays at 0.4.0) |
| `isabelle-mcp` | 0.6.0 | noarch python, no session, no hooks; PyPI 0.6.0 |
| `isabelle-minilang` | 0.7.0 | noarch python, session + AoA; PyPI `IsaMini` 0.5.0 (not updated) |
| `rocksdict` | 0.3.29 | third-party repackage, 5 subdirs x CPython 3.11-3.14 |
| `json-spec` | 0.12.0 | third-party repackage, noarch — conda-forge has NO usable version |
| `isabelle-semantic-embedding` | 0.5.0 | **per-platform, 5 subdirs**, abi3 (3.12-3.14); PyPI 0.2.0 (not updated) |
| `isabelle-semantic-data` | 2026.07.26.1711 | noarch generic, **data**: the read-only system layer of the semantic DB; version = export timestamp |
| `isabelle-ai` | 0.3.0 | noarch generic, **metapackage** — minilang + mcp + semantic-data, no files of its own |
| `isabelle-nunchaku` | 0.5.2 | component, **linux-64 only** — binaries come from the `xqyww123/nunchaku` fork's release, not built here |

`isabelle-nunchaku` is the one package still published on a single subdir. 0.5.3 changes
that: the fork's CI builds nunchaku **and the smbc the component now bundles** on all five
platforms and attaches twenty-five release assets (ten binaries, ten `.sha256` sidecars,
five `versions-<platform>.txt` records), and `release-nunchaku.yml` builds the five subdirs
on native runners. Which solver versions and which bytes is not restated here — it is
`component/solvers.pins` in the fork, and both repositories assert against that one file.
Until 0.5.3 is published this row stays at 0.5.2 / linux-64.

**The rollout is complete.** Every package in the original plan is published, and every one
of them has been installed from the live channel on Linux and on Windows.

`isabelle-rpc` 0.3.4 is the first release that works on Windows at all: `fork_and_launch__`
called `os.fork()`, which does not exist there, so every Windows launch died with
`AttributeError`. It shipped that way through 0.3.3 because the one CI step that would have
executed it was skipped on Windows. Enabling that step is what surfaced it — along with a
CRLF `etc/settings` defect and two ML path defects, in sequence, each hidden behind the
previous one.

(Historical note: 0.1.1 of `isabelle-semantic-embedding` outlived its win-64 defect
deletion on the four non-Windows subdirs until the 2026-07-22 sweep removed it. See
RELEASE_CHECKLIST.md for the bar that permitted the defect deletion.)

Verify from outside CI:
```sh
curl -fsS https://conda.qiyuan.me/noarch/repodata.json \
  | python3 -c "import json,sys;d=json.load(sys.stdin);pk={**d.get('packages',{}),**d.get('packages.conda',{})};[print(v['name'],v['version']) for v in sorted(pk.values(),key=lambda x:x['name'])]"
```

## In flight

- **A new `isabelle-semantic-data`** from the owner's 2026-10-03 database. The snapshot
  tarball is built (9.98 GB, `contrib/Semantic_Embedding/Isabelle_Semantic_Embedding.tar.zst`
  in the owner's working tree) but its Hugging Face upload stalled three times on a hotel
  network (bytes stop flowing after a few hundred MB, no retries logged); it waits for a
  better network. Then: `release-semantic-db` dry run, then `dry_run=false`. Order
  matters: the exporter is installed from the channel, and 0.5.0 is on it now, so the
  export keeps the fields 0.4/0.5 added.
- (Closed 2026-10-05.) Semantic_Embedding's PyPI gate for 0.5.0 (wheels run 37188265593)
  was **rejected** by the owner's decision; that run therefore ends as `failure` with
  `verify-published` skipped, and PyPI stays at 0.2.0 — see the fourth-wave notes.

2026-07-22, after the second wave: the channel was swept — 16 stale files deleted across
all six subdirs (rpc 0.3.1–0.3.4, mcp 0.3.0, minilang 0.4.0, auto-sledgehammer 0.1.0,
semantic-embedding 0.1.1/0.1.2), under what was then framed as a latest-version-only
retention policy. Per-file log in `RELEASE_CHECKLIST.md`.

2026-07-28: superseded-version deletion **reworded from that automatic-retention framing
to owner-selected sweeps** — no automatic policy; the owner picks from computed candidates
(files with a strictly newer version in the same subdir). New tool:
`scripts/sweep-old-versions.py` edits the per-subdir metadata surgically — no package
downloads, machine-gated against concurrent publish runs, verification anchored on the
owner's plan file. Design + three-reviewer adversarial-debate record:
`CONDA_CHANNEL_SWEEP_PLAN.md` in the owner's working tree; user manual: the "Sweeping
superseded versions" section of `RELEASE_CHECKLIST.md`. First run deleted 7 files
(isabelle-ai 0.1.0, isabelle-minilang 0.5.0, isabelle-semantic-embedding 0.2.0 × 5
platform subdirs), all externally verified; every package on the channel again has
exactly one version.

## Notes from the fourth wave (2026-10-03/04)

The content released is each repository's state at the moment the owner said "release"
(2026-10-03), plus the edits approved for the release itself. Order as in
RELEASE_CHECKLIST.md §9; every package went dry run → annotated tag → tag run, and every
publish job's audit read `audited 6 subdir(s)`.

- **The isabelle-performant-ml series moved to 0.2.x**, and the three recipes that capped
  it at `<0.2.0` (auto-sledgehammer, isabelle-rpc, isabelle-semantic-embedding) moved to
  `>=0.2.0,<0.3.0` in the same wave. Load-bearing for auto-sledgehammer (its session is a
  child of `Performant_Isabelle_HOL`, new in 0.2.0); for the other two the cap had to move
  or isabelle-minilang would have been unsolvable.
- **isabelle-rpc 0.5.1 exists because of a concurrent development commit.** While the
  wave was running, another session moved `IsaTerm` into `Isabelle_RPC_Host` (rpc
  `f9896eb`) and made Isa-Mini import it from there (`c402ea8`). Isa-Mini's `main` then
  needed an rpc newer than the 0.5.0 just published; the owner chose to publish the class
  as 0.5.1 and release minilang 0.7.0 from `main` with the floor `isabelle-rpc >=0.5.1`,
  rather than release minilang from a commit off `main`.
- **minilang's first dry run failed in `verify`**: `Minilang_AoA.thy` had gained
  `ML_file "proof_store_AoA.ML"` on 2026-08-09 and the recipe's hand-enumerated `Agent/`
  whitelist had not followed. The verify step ("every shipped session BUILDS from the
  installed package") is what caught it; nothing broken was published. The enumeration
  stays (it exists to keep `secret.sh` and dev code out of a public channel), so this is
  a list to update whenever that theory's `ML_file` lines change.
- **semantic-embedding's first dry run failed on a timing test**:
  `test_vecarith.py::test_the_kernel_releases_the_gil` on the macOS universal2 leg
  (stall 2.65 ms against a 3.50 ms call, threshold 0.5), green on the three other legs
  and green on a fresh dispatch the next day. A scheduler-jitter flake of a test that
  already takes the best of three rounds; not changed in this wave.
- **A `pipefail` SIGPIPE race in `publish-conda.yml`** failed the isabelle-rpc 0.5.1
  publish once: `rclone version | head -1` exits `head` after one line and rclone dies
  with 141 if it is still writing. Fixed (`sed -n 1p`, also the four `--version | head -1`
  lines in `build.yml`); the publish was re-run and succeeded. Nothing had been uploaded.
- **isabelle-ai 0.3.0's floors are unchanged** (`minilang >=0.6.0`, `mcp >=0.3.0`,
  `semantic-data >=2026.07.26`): every embedding-library name that minilang 0.6.0's
  shipped code uses still exists in 0.5.0 with the same signature, so the pair does not
  stop working and the recipe's floor doctrine says leave it. Its smoke now asserts
  `isabelle-semantics status` prints `system : conda …` — the installed library really
  reads the installed data payload — because `status` exits 0 either way.
- **PyPI was deliberately not updated.** `Isabelle_Semantic_Embedding` 0.5.0 requires
  `isabelle-rpc>=0.5.0`, which PyPI does not have (rpc is conda-only since 0.4.1), so the
  post-publish `dependencies resolve` check would fail forever and `pip install ==0.5.0`
  could never succeed; `IsaMini` 0.7.0 would need that embedding release. conda is ahead,
  which the rule permits.
- `main` of Performant_Isabelle_ML carries one commit past the released `ea3fef5`
  (`67a504b`, Event_Log.never_raising, another session's), unpushed at the time of
  writing; the superproject's submodule pointer for it was therefore not moved.

## Notes from the second wave (2026-07-22)

- **The PyPI floors were load-bearing, not cosmetic**: minilang 0.5.0 calls
  `Connection.set_current`, which exists only from isabelle-rpc 0.4.0, so BOTH its
  pyproject and recipe floors moved to `>=0.4.0`. semantic-embedding 0.2.0 raised the same
  floor for coherence (it is the rpc-0.4.0 companion) though it calls no 0.4.0-only API.
- **Tag-triggered PyPI publishes stop at the `pypi` environment gate** (Isabelle-MCP
  ci.yml, Semantic_Embedding wheels.yml). Approve with
  `gh api -X POST repos/OWNER/REPO/actions/runs/RUN/pending_deployments ...` — the token
  can, and a watcher that polls `pending_deployments` catches the stall instead of waiting
  on a run that will never finish by itself.
- **`IsaMini` on PyPI resumed at 0.5.0** after stalling at 0.3.5 (2025-05). Isa-Mini has
  no PyPI workflow; the upload was `twine` by hand with `TWINE_PASSWORD` from
  `~/secret.sh`, conda published first per the never-behind-PyPI rule.
- isabelle-performant-ml was deliberately NOT released: its two commits since v0.1.0
  changed only CI and a SKILL file, not package content. isabelle-ai's floors
  (`minilang >=0.4.0`, `mcp >=0.3.0`) still hold; no republish.

## Notes on the two packages that landed last

**`isabelle-ai`** lives HERE, in `conda/metapackage/isabelle-ai/`, not in a component repo:
the "recipe beside its source" rule presupposes a source, and this has none. Its own
directory rather than `conda/third-party/`, whose name carries "upstream's artifact, pinned
by sha256" — none of which applies. Floors, not exact pins: a metapackage that pins `==`
must be republished for every release of either half. Empty by construction, and the
workflow asserts exactly that — no file outside `info/`, `depends` equal to those two and
nothing more, `subdir: noarch`. Dry-run green on the first attempt.

**`isabelle-minilang`'s Windows registration was never minilang's bug.** Its Windows smoke
failed with "the component is not registered" while `etc/components` listed its four
dependencies, which read as a defect in its own post-link hook. It was not: the probe
(`minilang-win-hook-probe.yml`, which strips the `>nul 2>&1` the real hook needs) showed
`isabelle components -u` exiting 2 on `*** Illegal char <\n>` in a path belonging to
`isabelle-semantic-embedding`'s jar. That is the SAME CRLF defect that got 0.1.1's win-64
build deleted — `components -u` validates the whole component set, so one dependency's
carriage return takes the caller down with it. Publishing 0.1.2 and deleting the bad build
fixed minilang's registration with no change to minilang. Re-running the failed smoke was
the whole fix.

The general shape, since it cost three separate investigations: **a failure in package A's
hook may belong to package B**, because `isabelle components` is a whole-set operation.
Suspect the dependencies before the hook.

---

## Decisions already made — do not reopen

- **One repo = one conda package.** A repo's Python and Isabelle halves are one project and
  ship together.
- **Each component owns its own CI** (`release-conda.yml` in its own repo). Only the R2
  publish step is shared, via `publish-conda.yml` here. Copies of the release workflow are
  allowed to drift; the drift that is a *defect* is "same operation spelled two ways".
- **Recipes live in each component repo**, not centrally. A central `components.toml` was
  written and deleted — it only existed to feed a centralised pipeline we rejected.
- **`isabelle-repl` is NOT published** — it needs a patch we deliberately do not carry in
  the `isabelle` package. Isa-Mini's ROOT was split so its shipped session does not need it.
- **`isabelle-minilang` must contain AoA.** AoA is Isa-Mini's main product; a minilang
  package without it would be misnamed. That is why it is last in the order.
- **`isabelle-ai`, not `isabelle-aoa`**, for the metapackage: `isabelle-mcp` has no
  dependency edge to minilang, so only a metapackage can bind them.
- **Versions** track each project's existing line: `isabelle-rpc` 0.3.1 (PyPI 0.3.0),
  `isabelle-minilang` 0.4.0, `isabelle-mcp` 0.3.0. Only `auto-sledgehammer` starts at 0.1.0.
  conda must never fall **behind** PyPI.
- **Publishing is `copy`, never `sync`.** Many publishers share one channel and `sync`
  deletes what it does not see locally.
- **Third-party repackaging is acceptable** when conda-forge lacks a platform — the wheel is
  upstream's own artifact, pinned by sha256. Maintenance is a checklist item, not a build.
- **Precompiled natives are acceptable for `semantic-embedding`, but OUR pipeline must build
  them** — no downloading someone else's binary, no shelling a PyPI wheel. `wheels.yml`
  already builds them on native runners; the conda job consumes that, called via
  `workflow_call` rather than copied.
- Existing published packages are **never** retracted or rebuilt. Improvements apply from
  each package's next release. Deletion has exactly two grounds, both procedural in
  `RELEASE_CHECKLIST.md`'s "Deleting from the channel" section: the defect bar (an
  artifact that renders the tool unusable AND misattributes the cause, deletable only
  after the fixed version is published — used once, for `isabelle-semantic-embedding`
  0.1.1 **win-64 only**: a CRLF `etc/settings` left `isabelle build` unable to build any
  session on Windows, HOL included, with an error naming a jar path rather than the
  package) and owner-selected sweeps of superseded versions (since 2026-07-28).

---

## Lessons from this session that are NOT yet obvious from the code

The generalisable rules are in `RELEASE_CHECKLIST.md`. These are the ones about *how the
work went wrong*, which is the part that repeats.

### A green test can be green for the wrong reason

Repeatedly, the thing that caught a real bug was a **negative control** — running the same
test against the pre-fix code and confirming it fails.

- The proof-cache test passed twice before it was valid: once because the theory was never
  actually reprocessed (Isabelle keys on content, not mtime), once because an
  `auto_sledgehammer` call in the test appended to the cache and masked the truncation the
  test existed to detect.
- Matrix case "I" in an earlier plan reported a pass for a configuration that *could not
  fail* — the guard short-circuited before reaching the code under test.

Before believing a pass, ask: what would a broken implementation have printed?

### A "portable" expression that works on one platform by coincidence

Two instances in one afternoon:

- `find -maxdepth 3` for `.dist-info` matched on Windows (`Lib/site-packages`, depth 3) and
  failed on every unix leg (`lib/python3.X/site-packages`, depth 4) — on a perfectly good
  package.
- `rattler-build-$(uname -m)-apple-darwin` 404s on macOS (`uname` says `arm64`, the asset is
  `aarch64`) while working on linux-aarch64 purely because uname says `aarch64` there.

When a platform-dependent expression is right on one leg and wrong on another, the passing
leg is usually the coincidence.

### GitHub Actions specifics that cost a round trip each

- `include:` does **not** make a cross product. Entries whose keys are absent from the base
  matrix are merged into every combination in order, each overwriting the last — five
  platform entries produced three jobs all wearing the *last* platform. Use an
  object-valued matrix key.
- Step outputs do not cross jobs; export a job `outputs:` block.
- A reusable workflow gets the **calling** repo's secrets. Pass them explicitly so
  `required: true` is armed.
- macOS runners' system python is PEP 668 managed — `pip install` needs
  `--break-system-packages` there.

### rattler-build specifics

- No `bash` in the build environment on **Windows** ("interpreter `bash` was not found").
  Writing the build script in `python` removes the whole class.
- `--build-num`, not `--build-number`.
- `source.file_name:` renaming a wheel breaks pip, which parses the filename for
  name/version/abi/platform.
- `dynamic_linking.binary_relocation: false` is **required** when repackaging a foreign
  wheel: rattler-build rewrites load commands by default, and upstream wheels are not
  linked with spare header padding, so `install_name_tool` fails on macOS. The rewrite was
  never wanted — a PyPI wheel is self-contained by construction.

### Two Isabelle-specific traps worth remembering

- `isabelle components -u` exposes a component's **whole** ROOT, so an unshipped session in
  it breaks *every* build in a user's environment.
- On Windows, the first `isabelle` call is the one that cannot run a Scala tool: Cygwin
  heals itself on that call, but the Java classpath is computed before the heal finishes.
  Hooks therefore need a throwaway bash-only call before `components`.

---

## Resuming

The two items under "In flight" are what is left of the fourth wave: the data package
(upload the snapshot to Hugging Face from a network that can carry 4 GB, then
`release-semantic-db` dry run → `dry_run=false`) and the pending PyPI gate.

**Expect dry runs to fail, and let them.** semantic-embedding's first release took about
eight; this wave took one or two per package, each failure on something real (a stale
whitelist, a concurrent commit) or on CI noise (a timing test, a SIGPIPE race). The failure
point moved forward each time rather than any single run being wasted. Budget for that
rather than treating a red dry run as a setback. Four of the six `release-conda.yml`
workflows default `dry_run` to **false** — always pass `-f dry_run=true` explicitly.

Repo notes: `Isabelle_RPC` and `Isabelle_Semantic_Embedding` use `master`, the others use
`main`. `Semantic_Embedding` was **renamed on GitHub** to `Isabelle_Semantic_Embedding`.

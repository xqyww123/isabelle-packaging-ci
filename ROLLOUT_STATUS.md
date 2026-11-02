# conda rollout — where we are

How to release: the SKILL conda-release (`.claude/skills/conda-release/SKILL.md`). Rules for
package and workflow authors: `PACKAGING_RULES.md`. Channel operations: `CHANNEL_OPERATIONS.md`.
This file holds the **current state and the decisions already made**, so a fresh session can
resume without re-litigating anything.

Last updated: 2026-11-01 — isabelle 2026 (build 0), the official Isabelle2026 with its
official heaps and no patches (`PACKAGING_DESIGN.md` §11). Release run 41282713954 of
commit 4077e12: `audited 6 subdir(s)`, the smoke test green on all five platforms. No
other package accepts it yet (see "In flight").

Before that, 2026-10-28 — isabelle-mcp 0.7.0 (build 1), the `claude mcp add`
argument-order fix for `isabelle-mcp install --isabelle-bin`, and isabelle-ai 0.3.0
(build 2) with the mcp floor raised to it; `publish-conda.yml`'s banner step repaired on
the way (the 2026-10-28 note below).

Before that, 2026-10-09 — the fourth release wave (2026-10-03..09): performant-ml 0.2.0,
auto-sledgehammer 0.2.0, rpc 0.5.0 and 0.5.1, semantic-embedding 0.5.0, minilang 0.7.0,
isabelle-ai 0.3.0 (build 1), semantic-data 2026.10.09.0024; see "Notes from the fourth wave". Between the second wave and this one
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
| `isabelle` | 2026; 2025.2 | per-platform, 5 subdirs. 2026 is the official release unchanged; 2025.2 predates this rollout and is the only version the packages below accept (`isabelle >=2025.2,<2025.3`) |
| `isabelle-performant-ml` | 0.2.0 | noarch generic, two sessions (`Performant_Isabelle_ML`, `Performant_Isabelle_HOL`) + the prebuilt native library for 5 platforms |
| `auto-sledgehammer` | 0.2.0 | noarch generic, session |
| `isabelle-rpc` | 0.5.1 | noarch python, session + Python host; conda only since 0.4.1 (PyPI stays at 0.4.0) |
| `isabelle-mcp` | 0.7.0 (build 1) | noarch python, no session, no hooks; PyPI 0.6.0 (0.7.0 waits at the `pypi` gate, see "In flight") |
| `isabelle-minilang` | 0.7.0 | noarch python, session + AoA; PyPI `IsaMini` 0.5.0 (not updated) |
| `rocksdict` | 0.3.29 | third-party repackage, 5 subdirs x CPython 3.11-3.14 |
| `json-spec` | 0.12.0 | third-party repackage, noarch — conda-forge has NO usable version |
| `isabelle-semantic-embedding` | 0.5.0 | **per-platform, 5 subdirs**, abi3 (3.12-3.14); PyPI 0.2.0 (not updated) |
| `isabelle-semantic-data` | 2026.10.09.0024 | noarch generic, **data**: the read-only system layer of the semantic DB; version = export timestamp; **8.99 GiB** (1.44M records with their vectors), built off-runner — see the fourth-wave notes |
| `isabelle-ai` | 0.3.0 (build 2) | noarch generic, **metapackage** — minilang + mcp + semantic-data, no files of its own; its floors are the channel's newest at every release (`minilang >=0.7.0`, `mcp >=0.7.0`, `semantic-data >=2026.10.09`) |
| `isabelle-nunchaku` | 0.5.2 | component, **linux-64 only**; **no longer released** (owner, 2026-10-31): its workflow and recipe are removed, the published 0.5.2 stays |

**The rollout is complete.** Every package in the original plan is published, and every one
of them has been installed from the live channel on Linux and on Windows.

`isabelle-rpc` 0.3.4 is the first release that works on Windows at all: `fork_and_launch__`
called `os.fork()`, which does not exist there, so every Windows launch died with
`AttributeError`. It shipped that way through 0.3.3 because the one CI step that would have
executed it was skipped on Windows. Enabling that step is what surfaced it — along with a
CRLF `etc/settings` defect and two ML path defects, in sequence, each hidden behind the
previous one.

(Historical note: 0.1.1 of `isabelle-semantic-embedding` outlived its win-64 defect
deletion on the four non-Windows subdirs until the 2026-07-22 sweep removed it. The bar
that permitted the defect deletion: `CHANNEL_OPERATIONS.md`, "Defect deletions".)

## In flight

- Releases that accept isabelle 2026: none yet. Each package that depends on `isabelle`
  needs one: the SKILL conda-release, "11. A new Isabelle release"; `isabelle-ai` goes last
  (`RELEASE_CHECKLIST.md`, "9. Release", item 4).
- isabelle-mcp 0.7.0's PyPI publish: the v0.7.0 ci.yml run 40616658139 (Isabelle-MCP)
  waits at the `pypi` environment gate, unapproved by the owner's order (only the conda
  release was ordered). It can wait at most 30 days; after that, publishing needs
  `gh workflow run ci.yml -R xqyww123/Isabelle-MCP --ref v0.7.0`, which reaches the same
  gate. Until then PyPI serves 0.6.0, which still has the `--isabelle-bin` bug.
- (Closed 2026-10-09.) The new `isabelle-semantic-data` 2026.10.09.0024 is published
  (run 37869695496: `audited 6 subdir(s)`, smoke green). It was built on cslh19 and
  handed to CI through the `prebuilt` input — see the fourth-wave notes for why.
- (Closed 2026-10-05.) Semantic_Embedding's PyPI gate for 0.5.0 (wheels run 37188265593)
  was **rejected** by the owner's decision; that run therefore ends as `failure` with
  `verify-published` skipped, and PyPI stays at 0.2.0 — see the fourth-wave notes.

2026-07-22, after the second wave: the channel was swept — 16 stale files deleted across
all six subdirs (rpc 0.3.1–0.3.4, mcp 0.3.0, minilang 0.4.0, auto-sledgehammer 0.1.0,
semantic-embedding 0.1.1/0.1.2), under what was then framed as a latest-version-only
retention policy. Per-file log: "Deletion log" below.

2026-07-28: superseded-version deletion **reworded from that automatic-retention framing
to owner-selected sweeps** — no automatic policy; the owner picks from computed candidates
(files with a strictly newer version in the same subdir). New tool:
`scripts/sweep-old-versions.py` edits the per-subdir metadata surgically — no package
downloads, machine-gated against concurrent publish runs, verification anchored on the
owner's plan file. Design + three-reviewer adversarial-debate record:
`CONDA_CHANNEL_SWEEP_PLAN.md` in the owner's working tree; user manual:
`CHANNEL_OPERATIONS.md`, "Sweeping superseded versions". First run deleted 7 files
(isabelle-ai 0.1.0, isabelle-minilang 0.5.0, isabelle-semantic-embedding 0.2.0 × 5
platform subdirs), all externally verified; every package on the channel again has
exactly one version.

2026-10-09: `isabelle-ai-0.3.0-h4616a5c_0.conda` (build 0, the stale floors) deleted
with the same tool, whose candidate rule now also covers a lower build number of the
same version. The 15 other candidates it listed that day (every pre-wave version, see
the fourth-wave notes) were left in place — the owner's choice, one file only.

2026-10-28: isabelle-mcp 0.7.0 has **two builds** on the channel, both from commit
7675c88. The tag run (Isabelle-MCP run 40616658488) uploaded build 0 and then failed at
`publish-conda.yml`'s banner step, which 85dc11b had added and which had never run in CI,
so the index was not pushed. Two causes: the publish job checked out nothing, so the
banner files existed for no caller; and its assertion grepped for `conda install -c`,
which the banner never says. Fixed in 01ad592: the job now first checks out its own repo
at `job.workflow_repository` / `job.workflow_sha` and dry-runs the banner on a stub page
before the upload. "Re-run failed jobs" could not pick up that fix (it pins the reusable
workflow to the first attempt's commit), so build 1 was dispatched from the v0.7.0 tag
(run 40621147956); the pull step indexed the stranded build 0 along with it. Build 0 is
a sweep candidate (superseded by build 1). The first in-repo caller after the fix,
isabelle-ai 0.3.0 build 2 (run 40622793605), also passed; its build 1 is likewise a sweep
candidate now.

## Notes from the fourth wave (2026-10-03/04)

The content released is each repository's state at the moment the owner said "release"
(2026-10-03), plus the edits approved for the release itself. Dependencies first; every
package went dry run → annotated tag → tag run, and every
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
- **isabelle-ai 0.3.0 was published twice, and the first one is gone.** Build 0
  (2026-10-05) kept the 0.2.0 floors (`minilang >=0.6.0`, `mcp >=0.3.0`,
  `semantic-data >=2026.07.26`) under the recipe's old doctrine of raising a floor only
  when the pair stops working below it. The owner overruled that on 2026-10-09: a
  metapackage whose floors lag is one `conda update isabelle-ai` does nothing with, so
  every isabelle-ai release carries the channel's newest versions. Build 1 (same version, `build_number=1`, the input the
  workflow has for exactly this; dry run 37886355252, publish 37886735015, smoke green)
  floors `minilang >=0.7.0`, `mcp >=0.6.0`, `semantic-data >=2026.10.09`; build 0 was
  deleted the same day with the sweep tool (below). The smoke now also asserts
  `isabelle-semantics status` prints `system : conda …` — the installed library really
  reads the installed data payload — because `status` exits 0 either way.
- **PyPI was deliberately not updated.** `Isabelle_Semantic_Embedding` 0.5.0 requires
  `isabelle-rpc>=0.5.0`, which PyPI does not have (rpc is conda-only since 0.4.1), so the
  post-publish `dependencies resolve` check would fail forever and `pip install ==0.5.0`
  could never succeed; `IsaMini` 0.7.0 would need that embedding release. conda is ahead,
  which the rule permits.
- **The data package is built off-runner now.** Its payload grew twelvefold since July
  (1.44M records, a 17 GB vector store; the `.conda` is 8.99 GiB). rattler-build 0.69.1
  packages it fine, then re-indexes the output channel, and rattler_index reads the
  whole archive into memory (`reader.bytes().collect::<Vec<u8>>()`, then in-memory
  sha256/md5; the same code in rattler_index 0.33.2) — measured at a 17.2 GiB peak,
  which reclaimed 15 GiB hosted runners three times (37565271795, 37570530666,
  37573774046; the VM dies 3–8 min after "Checking for symlinks", with the archive
  already written). The workflow therefore takes a `prebuilt` dispatch input: the
  `.conda`, built elsewhere by the same recipe and the channel's own library, is
  fetched from the ANTPG/MLML-data dataset and goes through the unchanged sanity
  check, artifact handoff, publish guard and smoke. The 2026.10.09.0024 package was
  built on cslh19 (export 1 min, rattler-build 8 min, upload ~30 min). Along the way:
  the recipe moves the payload into the prefix instead of letting rattler-build copy
  it (a `source: path:` meant a second 19 GB on disk), the workflow deletes the
  tarball and the extracted database as soon as each is done with and prints `df`
  at every step, and the sanity check streams the archive instead of buffering
  17 GiB through `io.BytesIO` (which cost one more runner, 37868416138). Installing
  the package needs no such memory: measured with micromamba, 614 MiB peak RSS for
  the whole stack, 56 s from a local channel, 18 GB on disk plus the cached archive.
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
must be republished for every release of either half. (Since 2026-10-09 it is
republished at every wave regardless, with its floors raised to the channel's newest;
floors rather than `==` still let the solver move up
between waves.) Empty by construction, and the
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

- **A component's Python and Isabelle halves are one conda package.** They are one project
  and ship together. (A repository may release more than one package.)
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
- **A component registers in the installing user's directory**: its post-link writes
  `$ISABELLE_HOME_USER/etc/components`, Isabelle's supported path, which keeps the base
  package unaware of components. A `components.d` drop-in in the base `etc/settings` was
  rejected. Accepted limitation: on a shared or read-only environment other users do not
  see the registration.
- Existing published packages are **never** retracted or rebuilt. Improvements apply from
  each package's next release. Deletion has exactly two grounds, both procedural in
  `CHANNEL_OPERATIONS.md`, "Deleting from the channel": the defect bar (an
  artifact that renders the tool unusable AND misattributes the cause; used once, for
  `isabelle-semantic-embedding` 0.1.1 win-64 only: "Deletion log" below) and
  owner-selected sweeps of superseded versions (since 2026-07-28).

---

## Resuming

Nothing of the fourth wave is left.

**Expect dry runs to fail, and let them.** semantic-embedding's first release took about
eight; this wave took one or two per package, each failure on something real (a stale
whitelist, a concurrent commit) or on CI noise (a timing test, a SIGPIPE race). The failure
point moved forward each time rather than any single run being wasted. Budget for that
rather than treating a red dry run as a setback.

`Semantic_Embedding` was **renamed on GitHub** to `Isabelle_Semantic_Embedding`.

## Deletion log

| Package | Version | Subdir | Why | When |
|---|---|---|---|---|
| `channel-smoke-test` | 0.1.x | unknown | a test package; its deletion was not logged | unknown |
| `isabelle-semantic-embedding` | 0.1.1 | win-64 | CRLF `etc/settings` → CR in the classpath → `isabelle build` could build no session at all, not even HOL, and the error named a jar path | 2026-07-19, after 0.1.2 shipped |
| `isabelle-rpc` | 0.3.1–0.3.4 | noarch | policy sweep (0.4.0 is latest) | 2026-07-22 |
| `isabelle-mcp` | 0.3.0 | noarch | policy sweep (0.3.1) | 2026-07-22 |
| `isabelle-minilang` | 0.4.0 | noarch | policy sweep (0.5.0) | 2026-07-22 |
| `auto-sledgehammer` | 0.1.0 | noarch | policy sweep (0.1.1) | 2026-07-22 |
| `isabelle-semantic-embedding` | 0.1.1, 0.1.2 | all four unix subdirs; win-64 had only 0.1.2 left | policy sweep (0.2.0) | 2026-07-22 |
| `isabelle-ai` | 0.1.0 | noarch | owner-selected sweep; superseded by 0.2.0 | 2026-07-28 |
| `isabelle-minilang` | 0.5.0 | noarch | owner-selected sweep; superseded by 0.6.0 | 2026-07-28 |
| `isabelle-semantic-embedding` | 0.2.0 | all five platform subdirs | owner-selected sweep; superseded by 0.3.0 | 2026-07-28 |
| `isabelle-ai` | 0.3.0 (build 0) | noarch | owner-selected sweep; superseded by 0.3.0 build 1, the republish with the raised floors | 2026-10-09 |

Rows dated 2026-07-22 say "policy sweep": the automatic-retention framing of the time,
since replaced by owner-selected sweeps.

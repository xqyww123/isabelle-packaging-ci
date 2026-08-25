# Releasing a conda package to https://conda.qiyuan.me

Every item below was learned by getting it wrong. The failures in this stack are
overwhelmingly **silent**: the package installs, `conda list` shows it, and something is
quietly not there. Read accordingly.

Correct a bad release with a **new version**, not a retraction. Deleting from the channel
is exceptional; the two grounds that exist, their procedures, and the log of every
deletion so far are in "Deleting from the channel" below, before the numbered checklist.

## Deleting from the channel

A published filename is permanent: `publish-conda.yml`'s immutability guard assumes
filenames never come back, and a lockfile pinning a deleted build turns "broken
environment" into "environment will not resolve". Exactly two grounds for deletion
exist — **defect deletions** (an artifact so broken it must go) and **owner-selected
sweeps of superseded versions**. Nothing else is ever deleted, and every deletion lands
in the log at the end of this section.

### Defect deletions

The bar needs stating rather than leaving to judgement: an artifact may be deleted when
it does not merely misbehave but **renders the tool unusable and misattributes the
cause**. `isabelle-semantic-embedding` 0.1.1's win-64 build was the first: a CRLF
`etc/settings` put a carriage return in the classpath, `isabelle build` could then build
no session at all — not even HOL — and the error named a jar path, so nothing pointed at
the package responsible.

If you delete one:

1. **Publish the fixed version first.** Never leave a window with no working artifact.
2. Delete only the affected **subdir's** file. Five builds of one version are five
   artifacts; here four were fine.
3. Re-run `conda index` for that subdir and push the regenerated index. Getting this
   half-right is worse than not doing it: repodata that still lists a deleted file
   resolves and then 404s at download. **Verify from outside** afterwards — the object
   must 404 over HTTPS *and* be absent from `repodata.json`; check both, not either.

   No CDN purge is needed, measured rather than assumed: `conda.qiyuan.me` returns
   `cf-cache-status: DYNAMIC` for `repodata.json` and for `.conda` objects alike, i.e.
   Cloudflare proxies without caching. That is also why `publish-conda.yml` has never had
   a purge step. Re-measure before trusting this if the Cloudflare config changes.
4. Say so in this file and in `ROLLOUT_STATUS.md`. A silent exception is how a rule
   becomes folklore.

**Doing it by hand** (there is no workflow, and one deletion does not justify writing one).
Ubuntu's rclone 1.60 is the broken-against-R2 version — fetch ≥ 1.74 to a temp dir. Source
the R2 credentials into `RCLONE_CONFIG_R2_*` so they never reach disk or a log. Then: pull
the subdir, save the current `repodata.json` as a baseline, delete the file **locally**,
re-index, and **diff the new repodata against the baseline before pushing anything** — the
only difference may be the one removed entry, with `info`, `repodata_version` and every
other package untouched. Only then delete on R2 and push `repodata.json`,
`repodata_from_packages.json` and `index.html`. (File first, deliberately: a harmful
artifact should stop being downloadable before anything else. The sweep manual below
inverts the order for harmless old versions.) Never push `.cache/`; it is conda-index's
local sqlite.

### Sweeping superseded versions — user manual

**What this is.** Old versions are deleted **when and as the owner chooses** — there is no
automatic retention policy (reworded 2026-07-28; supersedes the 2026-07-22 "keeps only the
latest version" phrasing). `scripts/sweep-old-versions.py` computes the **candidates** —
files with a strictly newer `VersionOrder` version of the same package in the same
subdir — and the owner selects among them. Version ties (`2026.07.26` vs `2026.7.26`,
`1.0` vs `1.0.0` — conda compares them equal) all survive; a package's newest or only
version in a subdir is never deletable. Deleting superseded versions deliberately trades
lockfile reproducibility away; this is a private channel and the owner accepts that.

The script edits the per-subdir metadata surgically and **downloads no package**. Design
and adversarial-review record: `CONDA_CHANNEL_SWEEP_PLAN.md` in the owner's working tree.
The pull-everything-and-re-index procedure above remains the one for **defect
deletions** — a policy split, not a mechanical one: by the time a defect deletion is
legal its file is usually superseded too (defect rule 1 above), so the script would
accept it. What the script does refuse is any non-candidate, including a defective build
of a package's *newest* version.

**Prerequisites** — 1, 2 and 4 are checked at startup with an abort pointing here; a
broken `gh` surfaces fail-closed at `execute`'s first concurrency gate (`plan` does not
need `gh`):

1. rclone ≥ 1.74 (Ubuntu's apt 1.60 is broken against R2):
   `curl -fsSL https://rclone.org/install.sh | sudo bash`, or point `$RCLONE` at a
   downloaded binary.
2. A python that can `import conda.models.version` — any environment with the `conda`
   package installed.
3. A logged-in `gh` — the concurrency gate queries workflow runs.
4. `CONDA_R2_ACCESS_KEY_ID` / `CONDA_R2_SECRET_ACCESS_KEY` in the environment.

**Routine.** From this repo's root; `python3` must be the conda-capable one from
prerequisite 2; `sweep-plan.txt` lands in the current directory. Run in a subshell so the
credentials do not linger in the interactive shell:

```sh
(source ~/Current/MLML/secret.sh && python3 scripts/sweep-old-versions.py plan sweep-plan.txt)
#  zero channel writes; lists every candidate as `subdir/filename  # superseded by X`
# edit sweep-plan.txt: the lines you KEEP are the ones DELETED; '#' comments a line out
(source ~/Current/MLML/secret.sh && python3 scripts/sweep-old-versions.py execute sweep-plan.txt)
#  shows the final list, asks you to type DELETE, then acts
```

Without a tty (an agent running an owner-approved plan), `execute PLAN --confirm DELETE`
replaces the prompt — pass it only after the owner approved that exact plan file.
Afterwards, append the rows `execute` prints to the deletion log below (they match its
five columns) and note the sweep in `ROLLOUT_STATUS.md`.

**What `execute` does, in order** — every failure is an abort, never a warned-past write;
an abort mid-way leaves only the safe direction (metadata already stops listing files that
still exist — see *Interrupted?*):

1. Gates on publish runs (next paragraph) and re-checks the channel-shape assumptions:
   exactly three metadata files per subdir, `removed == []` in repodata. If either fails,
   a new conda-index behaviour has appeared — stop and use the full re-index procedure.
2. Recomputes the candidates and refuses any plan line that is not one (newest/only
   versions, unknown or already-gone files).
3. Checks that no surviving package loses a satisfiable in-channel dependency
   (platform ∪ noarch, per platform).
4. Shows the final list and requires the typed `DELETE` (or the `--confirm` flag above).
5. Edits `repodata.json`, `repodata_from_packages.json`, `index.html`. The abort gate is
   semantic and anchored on your plan: parsed(edited) must equal parsed(baseline) minus
   exactly the selected entries.
6. Pushes the edited metadata **before** deleting any file — fresh clients stop resolving
   the old versions first — then deletes the files one by one.
7. Verifies from outside, anchored on the plan file (never on its own edits): every file
   404s over HTTPS and is gone from R2, and the live `repodata.json` key set equals
   baseline minus plan.

**Concurrency is machine-gated, not a discipline.** A publish that raced the sweep would
re-upload the deleted files from its own full-channel snapshot (`publish-conda.yml` pulls
the whole channel and pushes it back). The script therefore aborts when any
release/publish/conda/wheel-named workflow is in progress or queued across the publishing
repos — checked before executing and again before pushing — and when a `.conda` on R2 is
newer than its subdir's `repodata.json` (the signature of an in-flight or half-failed publish:
publishes upload packages minutes before the index). Both checks are needed: the modtime
signal is blind to publish re-runs, the run listing to unknown repos. After the sweep it
checks whether a publish started meanwhile and re-verifies. If a race slips through
anyway, nothing is lost — the publish resurrects the files, and the fix is to rerun the
sweep.

**Interrupted?** Rerun **from `plan`**: a fully-deleted file is no longer a candidate, so
feeding the old plan file back to `execute` aborts on it. A fresh `plan` re-lists the
leftovers, the already-deleted lines simply no longer appear, and you select again. The
script prints how many of the selected files the repodata cross-check covered, so the
thinner guard rail on such a re-run (entries already gone from repodata) is visible rather
than silent.

**Maintenance duty — the one manual sync point.** A repo that starts publishing to the
channel must be added both to `PUBLISH_REPOS` in the script and to this list: `Isa-Mini`,
`Isabelle-MCP`, `Isabelle_RPC`, `Isabelle_Semantic_Embedding`, `auto_sledgehammer`,
`Performant_Isabelle_ML`, `isabelle-packaging-ci` (all under `xqyww123/`).

### Deletion log

| Package | Version | Subdir | Why | When |
|---|---|---|---|---|
| `isabelle-semantic-embedding` | 0.1.1 | win-64 | CRLF `etc/settings` → CR in the classpath → `isabelle build` could build no session at all, not even HOL, and the error named a jar path | 2026-07-19, after 0.1.2 shipped |
| `isabelle-rpc` | 0.3.1–0.3.4 | noarch | policy sweep (0.4.0 is latest) | 2026-07-22 |
| `isabelle-mcp` | 0.3.0 | noarch | policy sweep (0.3.1) | 2026-07-22 |
| `isabelle-minilang` | 0.4.0 | noarch | policy sweep (0.5.0) | 2026-07-22 |
| `auto-sledgehammer` | 0.1.0 | noarch | policy sweep (0.1.1) | 2026-07-22 |
| `isabelle-semantic-embedding` | 0.1.1, 0.1.2 | all four unix subdirs; win-64 had only 0.1.2 left | policy sweep (0.2.0) | 2026-07-22 |
| `isabelle-ai` | 0.1.0 | noarch | owner-selected sweep; superseded by 0.2.0 | 2026-07-28 |
| `isabelle-minilang` | 0.5.0 | noarch | owner-selected sweep; superseded by 0.6.0 | 2026-07-28 |
| `isabelle-semantic-embedding` | 0.2.0 | all five platform subdirs | owner-selected sweep; superseded by 0.3.0 | 2026-07-28 |

Rows before 2026-07-28 say "policy sweep" — the automatic-retention framing of the time,
since replaced by the owner-selected manual above.

## 1. Pick the shape

| Shape | When | Reference |
|---|---|---|
| `noarch: generic` | Isabelle session only — **no Python files** | `Performant_Isabelle_ML` |
| `noarch: python` | anything containing a Python package | `Isabelle_RPC`, `Isabelle-MCP` |
| per-platform | compiled artifacts | `Semantic_Embedding` (see its plan doc) |

`noarch: generic` installs files at their literal path, so the builder's
`lib/python3.12/site-packages/…` gets baked in: installed under 3.11 it creates a directory
no interpreter reads. Installs green, `import` fails. `run: python >=3.10` does not help —
it *permits* 3.11. `noarch: python` relocates at link time; that is the whole point.

## 2. Dependency names — check what a package IS

The wrong one **resolves, installs green, and dies at import**.

| PyPI | conda-forge |
|---|---|
| `msgpack` | `msgpack-python` |
| `lmdb` | `python-lmdb` (conda `lmdb` = the C library) |
| `xxhash` | `python-xxhash` (conda `xxhash` = the C library) |
| `zstandard` | `zstandard` — **no** `python-zstandard` exists; don't "fix" by analogy |

The version is the tell: PyPI `lmdb` is 2.x, conda `lmdb` is 0.9.x — different software.

```sh
# what is it?
curl -fsS https://api.anaconda.org/package/conda-forge/NAME \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['latest_version'],'|',d['summary'])"
# which platforms?  (rocksdict has no Apple Silicon)
curl -fsS https://api.anaconda.org/package/conda-forge/NAME/files \
  | python3 -c "import sys,json;print(sorted({f['attrs']['subdir'] for f in json.load(sys.stdin)}))"
```

Missing a platform or badly stale → repackage the upstream wheel onto our channel (§8).

**Check the transitive ones too, and check them under the python you will ship.** The
worst case is not an absent package but a *reachable broken* one: conda-forge's `json-spec`
offers 0.10.1, which does `from collections import Mapping` (removed in Python 3.10), and
0.11.0, which pins `importlib-metadata <6` and so cannot be solved at all — so the solver
lands on 0.10.1, the environment resolves, installs green, and dies at import. Nothing
local reproduces it, because locally you have PyPI's fixed version. When you repackage the
fix, **pin its floor in your own recipe**: leaving a transitive dependency implicit leaves
the choice to the solver, and the broken version is the one it can reach.

## 3. Versions

- One repo, one package, one semver.
- If the project also ships to PyPI, **conda must never fall behind**. If PyPI gets ahead,
  `pip install -U` removes conda's `.dist-info` and orphans the Isabelle half beyond
  `conda remove`.
- Don't add `./VERSION` where a version already exists (`Isabelle-MCP` uses
  `__version__`). Two sources of truth drift.
- No `-` in a conda version.

## 4. Component hooks (session packages)

`post-link` runs `isabelle components -u "$PREFIX/share/<name>"`, `pre-unlink` runs `-x`.

- Write **both** `bin/*.sh` and `Scripts/*.bat`, unconditionally. conda picks by running
  platform and silently succeeds when the file is absent → `.sh`-only installs clean on
  Windows and never registers.
- Don't guard with `case "$target_platform" in win-*)` — for noarch that is `noarch`, so
  the branch never matches. Looks applied; isn't.
- Every hook ends `exit 0`. A nonzero post-link rolls the whole install back.
- Windows needs a throwaway warm-up **before** `components`:
  `call "%PREFIX%\isa\bin\isabelle.bat" getenv -b ISABELLE_HOME >nul 2>&1`.
  Cygwin heals on the first `isabelle` call, but that call's classpath is computed before
  the heal — so the first invocation is the one that cannot run a Scala tool, and
  `components` is one.
- Pass a Cygwin path: `Path.check_elem` rejects `:` and `\`. Convert in pure batch
  (`cygpath.exe` prints nothing on the runner). The drive letter needs **no** lowercasing.
- A package that registers from its **own code** must have **no** hooks (`Isabelle-MCP`) —
  a hook would add a second, competing `etc/components` entry.

## 5. ROOT exposure

`isabelle components -u` exposes the component's **whole** ROOT. A session whose directory
or imports are not shipped breaks **every** `isabelle build` in the user's environment,
including unrelated ones. Move test/dev sessions to their own ROOT in an unshipped
subdirectory (`Isa-Mini/Agent/AoA_REPL/ROOT`, `Semantic_Embedding/Test/ROOT`). Verify with
a control — an invented session name must error.

## 6. Python halves

- Build with `$PYTHON -m pip install . --no-deps --no-build-isolation`. That is what makes
  the `.dist-info`; **without it pip cannot see the package** and will install PyPI's copy
  over conda's files.
- Declare `entry_points` in the recipe.
- setuptools' glob **skips hidden entries**: `Foo/**/*` matches nothing under `Foo/.claude/`.
  Spell the dot out — `Foo/.claude/**/*`. The obvious pattern ships an empty directory.
- A user who ran `pip install` first keeps a stale `.dist-info`; no packaging choice fixes
  that — document `pip uninstall NAME` before `conda install`.

## 7. Workflow gotchas

Copy an existing `release-conda.yml`, then read every line — the copies do diverge, and
the divergences are defects.

- `"$CONDA/bin/python" -m conda_index`, never bare `python` (setup-miniconda leaves
  `/usr/bin/python` first). This shipped to two repos.
- `--build-num`, not `--build-number` (rattler-build exits 2).
- Step outputs don't cross jobs — export a job `outputs:` block.
- `conda-forge` must be in the channel list for anything with Python deps.
- Secrets are **per repo** and passed **explicitly**, never `secrets: inherit` (naming them
  re-arms `required: true`, so an unseeded repo fails at resolution with a named error):
  `gh secret set CONDA_R2_{ACCESS_KEY_ID,SECRET_ACCESS_KEY} -R xqyww123/REPO`
- Entry point in tests is `<prefix>/bin/isabelle` or `<prefix>/Scripts/isabelle.bat` —
  **not** `<prefix>/isa/bin/isabelle`, the distribution's unix launcher, which ships on
  Windows too and which Git-Bash calls executable. Dispatch on `$RUNNER_OS`.
- On Windows `isabelle getenv` returns `/cygdrive/c/…`; Git-Bash needs `/c/…`.
- Under Git-Bash, `cmd.exe /c foo.bat` **starts cmd interactively and never runs the
  batch**: MSYS rewrites any argument shaped like a unix path, so `/c` arrives as
  `C:/Program Files/Git/c`. Use `MSYS_NO_PATHCONV=1 cmd.exe //c "$(cygpath -w …)"`. The
  give-away is a Windows banner and a prompt in the log, with no error.
- conda's link scripts are **dotfiles** (`.<pkg>-post-link.bat`). `ls -l` hides them, so a
  listing that reports "no hooks" may just be missing `-a`.
- `conda remove` without `--force` takes base `isabelle` with it, whose own pre-unlink
  deletes the namespaced `ISABELLE_HOME_USER` — so an "entry is gone" check proves nothing.
- `$CONDA/bin/python` is ubuntu-only. On Windows Miniconda is `%CONDA%\python.exe` with no
  `bin/` at all. Dispatch on `$RUNNER_OS` the moment a matrix gains a Windows leg.
- A **multi-line `python -c "…"` body must start at column 0**, which ends the enclosing
  YAML block scalar and makes the whole workflow unparseable. GitHub then runs *nothing*
  and says only "This run likely failed because of a workflow file issue". Keep such
  snippets on one line.
- Calling a reusable workflow whose job declares `id-token: write` requires the **caller**
  to grant it, even when that job is skipped: permissions are validated while the run is
  built, before any `if:`. Otherwise `startup_failure`, with no jobs and no annotation.
  `actionlint` does not catch this — but it does catch most other structural errors, and
  it is worth a run before every dispatch.

## 7b. rattler-build specifics

- rattler-build **does** run conda link scripts in the `tests:` environment — but it
  gives the hook the **invoking user's `HOME`** while the test script gets a rattler temp
  one (measured 2026-08-25, rattler-build 0.69.1). Two consequences. (a) A test that
  probes for the *automatic* post-link's effect reads an unregistered state and is a
  false red; invoke the hooks explicitly, with one environment for hook and probe and a
  `HOME` inside `$PREFIX`. (b) The matching pre-unlink is **never** run at teardown, so
  every `rattler-build build` of a component recipe leaves a permanent entry in
  `$HOME/.isabelle/Isabelle2025-2-conda-<envdir>/etc/components` pointing at a deleted
  temp prefix — after which every `isabelle` call in a conda environment directory of
  that name prints `### Missing Isabelle component: …`. Clean it by hand, or build in a
  container. CI runners are ephemeral, so publish safety is unaffected.
- No `bash` in the build environment on **Windows** ("interpreter `bash` was not found").
  Write the build script in `python` — it removes the whole class and keeps one script for
  every platform.
- `source.file_name:` renaming a wheel breaks pip, which parses the filename for
  name/version/abi/platform.
- `dynamic_linking.binary_relocation: false` when repackaging a foreign wheel: rattler-build
  rewrites load commands by default, upstream wheels have no spare header padding, and
  `install_name_tool` then fails on macOS. The rewrite was never wanted — a PyPI wheel is
  self-contained by construction.
- `include:` in a matrix does **not** make a cross product: entries whose keys are absent
  from the base matrix are merged into every combination in order, each overwriting the
  last. Use an object-valued matrix key.
- macOS runners' system python is PEP 668 managed — `pip install` needs
  `--break-system-packages` there.
- Map release-asset names from the **subdir you know**, not `uname -m`: macOS says `arm64`
  where assets say `aarch64`, and the same expression works on linux-aarch64 by coincidence.
- `--render-only` is a free pre-flight: it catches schema errors and prints the variant
  list, which is how you confirm `build.python.version_independent` actually took (one
  variant, not one per python).
- setuptools >= 77 **normalises the wheel filename to lowercase** (`isabelle_semantic_…`,
  not `Isabelle_Semantic_…`), and so the `.dist-info` inside it. A glob or `find -name`
  written in the PyPI casing matches nothing on POSIX and silently works on Windows, where
  fnmatch normcases. Glob `*.whl` and assert the count; use `find -iname` for dist-info.
- Adding a python to an **already-published** version: build only the new leg. A rebuilt
  `.conda` is not guaranteed byte-identical to the published one, and the publish guard
  refuses the run. Parameterise the matrix rather than re-running it whole.
- A plain YAML scalar cannot contain the two characters **`": "`**. A `python -c` test
  command with `print('found: ', x)` in it fails the *whole recipe* to parse, and the error
  points at the end of the line, not at the colon.
- `build.python.version_independent` relocates like `noarch: python`: `$PREFIX/bin` **and**
  `$PREFIX/Scripts` both become `python-scripts/`, and `site-packages/` loses its
  `lib/pythonX.Y` prefix. Write to bin/ and Scripts/ as usual, but anything **inspecting
  the built artifact** must look under `python-scripts/`.
- Declare console scripts as recipe `entry_points` — with them, conda generates the wrapper
  at link time and it is correctly *absent* from the payload, so assert its absence, not
  its presence.

## 8. Repackaging a third-party dependency

conda-forge missing a platform or badly stale? Repackage upstream's own wheel — cheap, and
not a build to maintain:

```yaml
source: [{url: "https://files.pythonhosted.org/…/PKG-VER-TAG.whl", sha256: "…"}]
build:  {number: 0, script: "$PYTHON -m pip install <the wheel> --no-deps"}
```

One recipe per platform tag. Record why we carry it and when to drop it.

## 9. Release

1. **Dependencies first** — `verify` installs from the live channel, so run deps must
   already be published. Order: `isabelle` → `isabelle-performant-ml` →
   `auto-sledgehammer` → `isabelle-rpc` → `isabelle-semantic-embedding` →
   `isabelle-minilang`. `isabelle-nunchaku` depends only on `isabelle` and can go
   any time after it:

   - Certify per the fork's `regress/README.md` (gate PASS). The gate is now **two
     things**, not one: the Isabelle goal sweep *and* `dune runtest`, which since 0.5.3
     carries three hermetic suites (`regress/cvc5_guard/`, `regress/soundness_guard/`,
     `regress/smbc_models/`) that need no solver and run on every platform's own
     toolchain.

   **The six steps, in this order. The order is load-bearing — three of these are the
   only points at which a broken build can still be stopped rather than published.**

   1. **Rehearse the fork, before any tag exists.**
      `gh workflow run build --repo xqyww123/nunchaku --ref main` — `main.yml` has
      `workflow_dispatch`, and both release job families run on a dispatch. This is the
      *first* execution of the five release legs in their current form, and it is what
      proves the things no local check can: `dune runtest` with the three hermetic
      suites on macOS and under Isabelle's Cygwin, the musl-static link of **both**
      binaries, `git` plus the pinned-commit smbc build inside Isabelle's Cygwin, and
      `.exe`-appending end to end on win-64. Do not tag until both families are green.
   2. **Tag** `v<VERSION>` on `xqyww123/nunchaku`, **annotated** — `git tag -a`, never a
      lightweight tag. The provenance check in `release-nunchaku.yml` resolves the tag
      with `git ls-remote … "refs/tags/v<VERSION>^{}"`, and that peeled ref exists only
      for annotated tags; a lightweight tag fails with "annotated tag not found
      upstream".

      **A defect found after the tag exists is fixed by a NEW PATCH VERSION, never by
      moving the tag.** A moved tag makes `git ls-remote …^{}` name a different commit
      than the already-attached assets were built from, and the fork attaches with
      `--clobber`, so the difference would be hidden rather than caught.
   3. **Wait for the fork's `release-gate` job.** Every release leg creates
      `v<VERSION>` as a **draft** and attaches its own five files:
      `nunchaku-bin-<isabelle-platform>`, `smbc-bin-<isabelle-platform>`, a `.sha256`
      for each, and `versions-<isabelle-platform>.txt` — where `<isabelle-platform>` is
      one of `x86_64-linux`, `arm64-linux`, `x86_64-darwin`, `arm64-darwin`,
      `x86_64-cygwin`. **Twenty-five assets: ten binaries, ten sidecars, five version
      records.** The `release-gate` job diffs the release's asset list against that
      contract and only then runs `gh release edit --draft=false`.

      **Do not dispatch packaging until the release is out of draft.** A draft release
      is not served at `releases/download/…`, which is the URL
      `release-nunchaku.yml`'s staging step fetches — every leg would 404 five legs
      deep and look like "the fork's CI is broken".

      smbc is not optional: the component's wrapper unconditionally exports
      `NUNCHAKU_SMBC`, so a package without it runs a configuration the gate never
      certified. `versions-<platform>.txt` is not optional either: on `x86_64-cygwin`
      it is the **only** content check either repository can make on the two
      Cygwin-ABI binaries, and the staging step asserts its version and 40-hex commit
      fields against the tag on all five legs.
   4. **Packaging dry run.**
      `gh workflow run release-nunchaku --repo xqyww123/isabelle-packaging-ci -f version=<VERSION>`
      (`dry_run` defaults to true). This is the first execution of the recipe's hook
      round-trip and of the packaged wrapper's `--solvers cvc5,smbc` run, on all five
      subdirs, inside the build job — so it is a real gate, not a formality.

      What a dry run still does **not** cover: nothing is installed from the channel
      (`publish` and the post-publish `smoke` are both skipped), so `conda`'s own
      linker never runs the `.bat` hooks and the uninstall half is untested.
   5. **Inside the dry-run window, before `dry_run=false`: measure the installed win-64
      wrapper.** Take the win-64 `.conda` from the dry run's `conda-packages` artifact,
      install it from a local channel on a `windows-latest` runner (the pattern is
      `macos-install-probe.yml:50-92`), and run

      ```
      isabelle.bat env bash -c '"$NUNCHAKU_HOME/nunchaku" --solvers cvc5,smbc --timeout 30 <case>'
      ```

      with `MSYS2_ARG_CONV_EXCL="*"`, asserting that **no** `solver not available` line
      appears. This is the one functional property of the shipped win-64 package that
      nothing in either repository asserts: the wrapper hands the solvers
      extension-less paths, the payload holds `cvc5.exe`/`smbc.exe`, the conda payload
      records no mode bits, and the binary decides availability with
      `test -f && test -x`. Once it is green, fold the invocation into the smoke's
      win-64 branch (`release-nunchaku.yml`) so it stays measured. **Do not add it to
      the gate before it has been measured once.**
   6. **Publish.** Re-dispatch with `-f dry_run=false`. It builds all five subdirs on
      native runners and refuses to publish unless all five arrived. Then read the
      publish job's **audit log** (`audited N subdir(s)`), not its check mark.

      If `publish` fails partway: **re-run failed jobs**, or bump `build_number`. A
      fresh *dispatch* does not substitute — it rebuilds, and a rebuilt `.conda` is
      not byte-identical (`info/index.json` carries a timestamp), so the channel's
      content-comparing guard correctly refuses it and the re-dispatch dead-ends.
2. Dry run: `gh workflow run release-conda.yml -R REPO -f dry_run=true` — stops after
   `verify`, publishes nothing.
3. Tag: `git tag -a vX.Y.Z -m "…" && git push origin vX.Y.Z`. Some repos use `master`.
4. If `publish` fails: fix, then **re-run failed jobs** — the guard compares sha256 over
   https, so a byte-identical re-upload resumes instead of dead-ending.

## 10. What verification must assert

A green install proves very little. Each of these caught a real defect:

- unpack the `.conda` and check the payload (the zip file list alone shows nothing);
- both hook sets present, `.bat` is CRLF, hook path literal matches the install location;
- no hardcoded `lib/pythonX.Y` anywhere;
- the component **is registered** — read `etc/components`, don't infer;
- the session **builds** from the installed package;
- Python half: import, console script on PATH, `importlib.metadata.version`, and
  `pip install NAME` saying "already satisfied";
- pre-unlink **unregisters**, non-vacuously (§7 on `--force`);
- smoke on **windows-latest as well as ubuntu-latest** — Windows failure is silent and
  cannot be inferred from a green Linux leg.

When a test passes, ask what a broken implementation would have done. Several of ours
passed for the wrong reason until a negative control was run against the pre-fix code.

A recurring shape: **the code under test is not on the path the test takes.** A cold-cache
check that only `import`ed the module proved nothing, because the risky open lives inside
a coroutine — it never touched a directory, never read the env var it set, and would have
stayed green against exactly the failure it was named for. Before trusting a check, find
the line it is supposed to execute and confirm the test reaches it.

## 11. After publishing

```sh
curl -fsS https://conda.qiyuan.me/noarch/repodata.json | python3 -m json.tool | head
```

**Update `ROLLOUT_STATUS.md`.** Its "Published on https://conda.qiyuan.me" table names
the version and shape of every package, and a row moves only on publication — so moving
it is a post-publish step, not part of the release commit. For `isabelle-nunchaku` 0.5.3
that means the row goes from `0.5.2 / component, linux-64 only` to
`0.5.3 / component, 5 subdirs`, and the paragraph below the table that explains what
0.5.3 will change becomes a statement of what it did.

Read the publish job's **audit log**, not its check mark: it prints one line per subdir and
`audited N subdir(s)`. It used to be able to pass having inspected nothing.

# Releasing a conda package to https://conda.qiyuan.me

Every item below was learned by getting it wrong. The failures in this stack are
overwhelmingly **silent**: the package installs, `conda list` shows it, and something is
quietly not there. Read accordingly.

Correct a bad release with a **new version**, not a retraction. A published filename is
permanent and CDN-cached, `publish-conda.yml`'s immutability guard assumes filenames never
come back, and a lockfile pinning a deleted build turns "broken environment" into
"environment will not resolve".

**The one exception**, and it needs the bar stated rather than left to judgement: an
artifact may be deleted when it does not merely misbehave but **renders the tool unusable
and misattributes the cause**. `isabelle-semantic-embedding` 0.1.1's win-64 build was the
first: a CRLF `etc/settings` put a carriage return in the classpath, `isabelle build` could
then build no session at all — not even HOL — and the error named a jar path, so nothing
pointed at the package responsible.

If you delete one:

1. **Publish the fixed version first.** Never leave a window with no working artifact.
2. Delete only the affected **subdir's** file. Five builds of one version are five
   artifacts; here four were fine.
3. Re-run `conda index` for that subdir, and purge the CDN cache for **both** the object
   and `repodata.json`. Getting this half-right is worse than not doing it: repodata that
   still lists a deleted file resolves and then 404s at download.
4. Say so in this file and in `ROLLOUT_STATUS.md`. A silent exception is how a rule
   becomes folklore.

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
   `isabelle-minilang`.
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

Read the publish job's **audit log**, not its check mark: it prints one line per subdir and
`audited N subdir(s)`. It used to be able to pass having inspected nothing.

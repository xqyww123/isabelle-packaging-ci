# Releasing a conda package to https://conda.qiyuan.me

Everything here was learned by getting it wrong first. Each item says what breaks and how
we found out, because the failures in this stack are overwhelmingly **silent** — the
package installs, `conda list` shows it, and something is quietly not there.

The channel is a Cloudflare R2 bucket. It never deletes: a published filename is permanent
and CDN-cached, so a bad release is corrected by a new version, not a retraction.

---

## 0. Which shape is this package?

Pick before writing anything. Getting this wrong is not a style error.

| Shape | When | Reference |
|---|---|---|
| `noarch: generic` | Isabelle session only — ROOT, `.thy`, `.ML`. **No Python files.** | `Performant_Isabelle_ML`, `auto_sledgehammer` |
| `noarch: python` | Anything containing a Python package, with or without a session | `Isabelle_RPC` (session + python), `Isabelle-MCP` (python only) |
| per-platform | Compiled artifacts | `Semantic_Embedding` — see its `CONDA_PACKAGING_PLAN.md` |

**`noarch: generic` must never carry Python files.** conda installs generic files at their
literal path (`conda/core/path_actions.py`: `target_short_path = source_path_data.path`),
so the build machine's `lib/python3.12/site-packages/...` is baked in. Installed into a
python 3.11 env it creates a `lib/python3.12/` no interpreter looks at: install succeeds,
`conda list` shows it, `import` raises `ModuleNotFoundError`. `run: python >=3.10` does not
save you — it *permits* 3.11. `noarch: python` relocates site-packages at link time; that
relocation is the entire point.

---

## 1. Dependency names: check what a package IS, not that it exists

conda names differ from PyPI names, and the failure mode is worse than an unsolvable
package — the wrong one **resolves, installs green, and dies at import**.

| PyPI | conda-forge | note |
|---|---|---|
| `msgpack` | `msgpack-python` | there is no `msgpack` on conda-forge |
| `lmdb` | `python-lmdb` | conda `lmdb` is the **C library** |
| `xxhash` | `python-xxhash` | conda `xxhash` is the **C library** |
| `zstandard` | `zstandard` | **do not** "fix" this to `python-zstandard` — no such package |

We shipped `lmdb` once. conda installed LMDB 0.9.35, the package installed cleanly, the
Isabelle session built, and only `import Isabelle_RPC_Host` failed.

**The version is the tell.** PyPI `lmdb` is 2.x while conda `lmdb` is 0.9.x, because they
are different software. Read the summary — "Python binding" vs "database":

```sh
curl -fsS https://api.anaconda.org/package/conda-forge/<name> \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['latest_version'],'|',d['summary'])"
```

Also check **platform coverage**, not just existence — `rocksdict` on conda-forge has
`linux-64`/`osx-64`/`win-64` only, no Apple Silicon:

```sh
curl -fsS https://api.anaconda.org/package/conda-forge/<name>/files \
  | python3 -c "import sys,json;print(sorted({f['attrs']['subdir'] for f in json.load(sys.stdin)}))"
```

If conda-forge is too old or missing a platform, repackaging the upstream wheel onto our
own channel is cheap — see §9.

---

## 2. Versioning

- **Each component has its own semver.** One repo, one package, one version.
- Where the project already publishes to PyPI, the conda version **must never fall behind**
  PyPI's. If PyPI gets ahead, `pip install -U` takes over, its uninstall removes conda's
  `.dist-info`, and the Isabelle half — session, hooks, `etc/components` entry — is orphaned
  beyond conda's reach (`conda remove` then reports `PackagesNotFoundError`). Verified.
- Do not invent a `./VERSION` file where the project already declares a version
  (`Isabelle-MCP` reads `isabelle_mcp.__version__`). Two sources of truth for one number
  is how they drift.
- A conda version may not contain `-`.

---

## 3. The Isabelle component hooks

Session packages register themselves at install time and unregister at removal:

```
bin/.<name>-post-link.sh      isabelle components -u "$PREFIX/share/<name>"
bin/.<name>-pre-unlink.sh     isabelle components -x "$PREFIX/share/<name>"
Scripts/.<name>-post-link.bat     (Windows, CRLF)
Scripts/.<name>-pre-unlink.bat
```

Non-negotiables, each of which cost a debugging round:

- **Write both sets, unconditionally.** conda picks by the RUNNING platform and returns
  success in silence when the file is absent, so a `.sh`-only package installs cleanly on
  Windows and is never registered.
- **Do not guard with `case "$target_platform" in win-*)`.** For noarch that variable is
  `noarch`; the branch never matches. It looks applied and is not.
- **Every hook ends `exit 0`.** A nonzero post-link makes conda roll the whole install
  back (measured on Windows). A failed registration must degrade to a later "unknown
  session", not a failed install.
- **Windows needs a throwaway warm-up first:**
  ```bat
  call "%PREFIX%\isa\bin\isabelle.bat" getenv -b ISABELLE_HOME >nul 2>&1
  call "%PREFIX%\isa\bin\isabelle.bat" components -u "%CYG%" >nul 2>&1
  ```
  Cygwin heals itself on the first `isabelle` call, but that call's Java classpath is
  computed before the heal completes — so the first invocation is precisely the one that
  cannot run a Scala tool, and `components` is a Scala tool
  (`Could not find or load main class isabelle.Components`). A bash-only subcommand
  absorbs the cold start. Both hooks need it: install-then-remove leaves pre-unlink cold.
- **The path must be Cygwin form.** `Path.check_elem` rejects `:` and `\`, so
  `%PREFIX%\share\...` raises "Illegal character" — invisibly, given `exit /b 0`. Convert
  with pure batch (`cygpath.exe` printed nothing on a windows-latest runner). The drive
  letter needs **no** lowercasing: Isabelle accepts `/cygdrive/C/...` and lowercases it
  itself.
- **A package that registers from its own code must NOT have hooks.** `Isabelle-MCP`
  registers from Python at run time; a conda hook would add a second, competing
  `etc/components` entry. Its build step asserts the *absence* of hooks so a copy-paste
  from a sibling recipe fails loudly.

Registration lands in `$ISABELLE_HOME_USER/etc/components`, which the base package
namespaces per environment (`~/.isabelle/Isabelle2025-2-conda-<env>`).

---

## 4. Splitting the ROOT

`isabelle components -u` exposes a component's **whole** ROOT. If it declares a session
whose directory or imports are not shipped, **every** `isabelle build` in the user's
environment fails — including unrelated sessions, because Isabelle reads every registered
ROOT at startup.

Move test/dev sessions into their own ROOT in a subdirectory that is not shipped. Done for
`Isa-Mini` (`Agent/AoA_REPL/ROOT`) and `Semantic_Embedding` (`Test/ROOT`). Verify with a
control: an invented session name must error, or the check proves nothing.

---

## 5. Python packaging details

- Build with `$PYTHON -m pip install . --no-deps --no-build-isolation`. The `pip install`
  is what generates the `.dist-info` — **without it pip cannot see the package at all** and
  will install PyPI's copy over conda's files (and a later `conda remove` then deletes
  pip's). With it, `pip install <name>` reports "already satisfied" and touches nothing.
- Declare `entry_points` in the recipe; conda generates the wrappers per platform.
- **setuptools' glob skips hidden entries.** `Foo/**/*` matches nothing under `Foo/.claude/`.
  Spell the dot component out: `Foo/.claude/**/*`. Measured — the obvious pattern produces
  an empty directory and the belief that it shipped.
- A user who ran `pip install <name>` first keeps a stale `.dist-info` beside conda's;
  `conda list` then misreports it as `pypi_0` and a later `pip uninstall` deletes
  conda-owned files. No packaging choice avoids this — document `pip uninstall` first.

---

## 6. The workflow

Copy an existing `release-conda.yml` **and then read every line**, because the copies do
diverge and the divergences are defects:

- `"$CONDA/bin/python" -m conda_index`, never bare `python` — setup-miniconda leaves
  `/usr/bin/python` first on PATH. This exact bug shipped to two repos.
- `--build-num`, not `--build-number` (rattler-build exits 2 on the latter).
- Step outputs do not cross jobs. Export a job `outputs:` block if a later job needs the
  version.
- `conda-forge` must be in the channel list for any package with Python dependencies;
  `--override-channels` without it fails to solve.
- Secrets are **per repo**: a reusable workflow receives the CALLING repo's secrets, and a
  personal account has no org-level secrets. Pass them explicitly, never `secrets: inherit`
  — naming them re-arms `required: true`, so an unseeded repo fails at resolution time
  with a named error instead of an opaque S3 failure twenty minutes later.
  ```sh
  gh secret set CONDA_R2_ACCESS_KEY_ID     -R xqyww123/<repo>
  gh secret set CONDA_R2_SECRET_ACCESS_KEY -R xqyww123/<repo>
  ```
- The entry point in a smoke test is `<prefix>/bin/isabelle` or
  `<prefix>/Scripts/isabelle.bat` — **not** `<prefix>/isa/bin/isabelle`, which is the
  distribution's unix launcher; it ships on Windows too and Git-Bash calls it executable,
  so an `-x` dispatch picks it and Isabelle dies with "Failed to determine hardware and
  operating system type!". Dispatch on `$RUNNER_OS`.
- On Windows, `isabelle getenv` returns a Cygwin path Git-Bash cannot open
  (`/cygdrive/c/…` vs `/c/…`).
- `conda remove` without `--force` takes the base `isabelle` with it, and isabelle's own
  pre-unlink deletes the whole namespaced `ISABELLE_HOME_USER` — so an "entry is gone"
  assertion passes while proving nothing.

---

## 7. Release sequence

1. **Dependencies first.** A package's `verify` job installs it from the live channel, so
   every run dependency must already be published. The order is forced by the graph:
   `isabelle` → `isabelle-performant-ml` → `auto-sledgehammer` → `isabelle-rpc` →
   `isabelle-semantic-embedding` → `isabelle-minilang`.
2. **Dry run first:** `gh workflow run release-conda.yml -R <repo> -f dry_run=true`. It
   stops after `verify`, which is where the evidence is, and publishes nothing.
3. **Then tag:** `git tag -a vX.Y.Z -m "…" && git push origin vX.Y.Z`. Note some repos use
   `master`, not `main`.
4. Watch all four jobs. If `publish` fails, fix and **re-run the failed jobs** — the
   immutability guard compares sha256 over https and lets a byte-identical re-upload
   through, so a re-run resumes rather than dead-ending.

---

## 8. What verification must actually assert

A green install proves very little. Every one of these caught a real defect:

- the payload contains what it should (unpack the `.conda`, do not trust the file list);
- **both** hook sets are present, the `.bat` is CRLF, and the path literal in the hook
  matches where the files were installed;
- no hardcoded `lib/pythonX.Y` path anywhere in the payload;
- the component is registered — read `$ISABELLE_HOME_USER/etc/components`, do not infer it;
- the session **builds** from the installed package;
- for Python halves: `import`, the console script on PATH, `importlib.metadata.version`
  matching, and `pip install <name>` reporting "already satisfied";
- the pre-unlink **unregisters** — and the check is not vacuous (see §6 on `--force`);
- smoke runs on **windows-latest as well as ubuntu-latest**. Windows registration failure
  is silent, so it cannot be inferred from a green Linux leg.

When a test passes, ask what a broken implementation would have done. Several of ours
passed for the wrong reason until a negative control was run against the pre-fix code.

---

## 9. Repackaging a third-party dependency

When conda-forge lacks a platform or lags badly, repackage the upstream wheel onto our
channel. This is cheap and does not mean maintaining a build — the wheel is upstream's own
artifact:

```yaml
source:
  - url: https://files.pythonhosted.org/…/<pkg>-<ver>-<tag>.whl
    sha256: …
build:
  number: 0
  script: $PYTHON -m pip install <the wheel> --no-deps
```

One recipe per platform tag. Record why we carry it and the condition for dropping it
(normally: conda-forge gains the platform).

---

## 10. After publishing

- Confirm from outside CI:
  ```sh
  curl -fsS https://conda.qiyuan.me/noarch/repodata.json | python3 -m json.tool | head
  ```
- Read the publish job's **audit log**, not its check mark: it prints one line per subdir
  and an `audited N subdir(s)` total. (It used to be able to pass having inspected
  nothing.)
- A published name can never be reused. To correct content, release a new version.

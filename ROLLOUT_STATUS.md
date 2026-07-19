# conda rollout — where we are

Companion to `RELEASE_CHECKLIST.md`. That file holds the durable rules; this one holds the
**current state and the decisions already made**, so a fresh session can resume without
re-litigating anything.

Last updated: 2026-07-19.

---

## Published on https://conda.qiyuan.me

| Package | Version | Shape |
|---|---|---|
| `isabelle` | 2025.2 | per-platform, 5 subdirs (predates this rollout) |
| `isabelle-performant-ml` | 0.1.0 | noarch generic, session |
| `auto-sledgehammer` | 0.1.0 | noarch generic, session |
| `isabelle-rpc` | 0.3.1 | noarch python, session + Python host |
| `isabelle-mcp` | 0.3.0 | noarch python, no session, no hooks |

Verify from outside CI:
```sh
curl -fsS https://conda.qiyuan.me/noarch/repodata.json \
  | python3 -c "import json,sys;d=json.load(sys.stdin);pk={**d.get('packages',{}),**d.get('packages.conda',{})};[print(v['name'],v['version']) for v in sorted(pk.values(),key=lambda x:x['name'])]"
```

## In flight

**`rocksdict` 0.3.29** — repackaged from upstream's PyPI wheels, workflow
`release-rocksdict.yml` in this repo. Last dry run: **12/15 legs green**, including all
three `osx-arm64`. The three `osx-64` legs were still queued (macos-13 runners are scarce);
nothing about them is known to be broken. Next step is to let a dry run finish 15/15, then
re-run with `dry_run=false`.

## Not started

| Package | Version | Blocked on |
|---|---|---|
| `isabelle-semantic-embedding` | 0.1.0+ | rocksdict (now unblocked once published); plan written at `Isabelle_Semantic_Embedding/CONDA_PACKAGING_PLAN.md` |
| `isabelle-minilang` | 0.4.0 | semantic-embedding — its Python half hard-depends on it |
| `isabelle-ai` (metapackage) | — | minilang + mcp |

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
  each package's next release.

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

1. `gh run list -w release-rocksdict -R xqyww123/isabelle-packaging-ci` — get a dry run to
   15/15, then `-f dry_run=false`.
2. Read `Isabelle_Semantic_Embedding/CONDA_PACKAGING_PLAN.md` and implement it. Its open
   questions are listed at the end of that file; the two most likely to bite are
   rattler-build on macOS/Windows runners (now partly answered by the rocksdict work above)
   and how `publish-conda.yml`'s single `artifact:` input handles per-subdir artifacts —
   answered: merge the legs into one `<subdir>/*.conda` artifact in a `collect` job, as
   `release-rocksdict.yml` does.
3. Then `isabelle-minilang`, then the `isabelle-ai` metapackage.

Repo notes: `Isabelle_RPC` and `Isabelle_Semantic_Embedding` use `master`, the others use
`main`. `Semantic_Embedding` was **renamed on GitHub** to `Isabelle_Semantic_Embedding`.

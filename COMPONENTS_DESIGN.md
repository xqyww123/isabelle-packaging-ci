# Component packages — design

Goal: `conda install -c https://conda.qiyuan.me -c conda-forge isabelle-aoa` pulls the
whole AoA stack (the patched `isabelle`, the Isabelle libraries it needs as sessions, and
the Python packages) onto any of the 5 platforms.

Builds on the published base `isabelle` package (see PACKAGING_DESIGN.md).  Everything
here needs **user-only patches** — the `dev` patch category is never required (the AoA
agent was decoupled from Isa_REPL; see "Isa-Mini" below).

## Packages — one per repo, plus a metapackage

| conda package | repo | ships | arch |
| --- | --- | --- | --- |
| `isabelle-performant-ml` | Performant_Isabelle_ML | session | noarch |
| `auto-sledgehammer` | auto_sledgehammer | session | noarch |
| `isabelle-rpc` | Isabelle_RPC | session + Python `isabelle-rpc` | noarch |
| `isabelle-semantic-embedding` | Semantic_Embedding | session + Python (native SIMD ext) | **per-platform** |
| `isabelle-minilang` | Isa-Mini | sessions `Minilang`+`Minilang_AoA` + Python `IsaMini` | noarch |
| `isabelle-mcp` | Isabelle-MCP | Python `isabelle-mcp` only (no session) | noarch |
| `isabelle-aoa` | — | metapackage → depends on the six above | noarch |

One repo = one conda package: a repo's Python and Isabelle halves are one tightly coupled
project and are NOT split.  A package with a session also declares its Python runtime
deps; those resolve from conda-forge except our own six.  Install needs both channels.

Session dependency DAG (= conda `depends`, all on the base `isabelle`):

    isabelle → performant-ml ┬→ isabelle-rpc ─────────────┐
                             ├→ auto-sledgehammer         │
                             └→ semantic-embedding ───────┤
                                                          └→ minilang → aoa

## Registration — `isabelle components -u/-x` (no prebuilt heaps)

We do NOT ship heaps for the components — Isabelle loads dynamically and the user (or
jEdit on first open) builds the heap on demand.  A session package ships only source, at
`$PREFIX/isa/contrib/<name>/` (a valid component dir: it has a `ROOT`), and registers it
with Isabelle's own mechanism:

  * **post-link**: `"$PREFIX/isa/bin/isabelle" components -u "$PREFIX/isa/contrib/<name>"`
    — idempotent (a second run says "Unchanged"; verified).
  * **pre-unlink**: `... components -x "$PREFIX/isa/contrib/<name>"` — clean unregister
    ("Removed component"; verified), for the case where one component is removed but the
    base stays.

Both write `$ISABELLE_HOME_USER/etc/components`; `isabelle build` then discovers the
sessions via `Components.directories()`.  Known limitation, accepted: this is the
*installing user's* dir, so on a shared/read-only env other users do not see the
registration — fine for a single-user research tool (and this is how Isa-Mini's own dev
setup already registers its dev subdirs).  We chose this over a `components.d` drop-in in
the base `etc/settings` because it is Isabelle's supported path and keeps the base
unaware of components.

## Per-env user-dir isolation (in the base package)

Stock `etc/settings` puts USER state (config + on-demand-built session heaps) in
`~/.isabelle/Isabelle2025-2` — SHARED with any stock Isabelle2025-2.  Our Pure is patched,
so those heaps are not interchangeable and the two builds would clobber each other.  The
base package (pack.sh, step 1d) patches `etc/settings` so `ISABELLE_HOME_USER` becomes
`~/.isabelle/Isabelle2025-2-conda-<env>` (env derived from the install prefix, so it holds
without `conda activate`).  The base's **pre-unlink** deletes that whole dir on
`conda remove`, guarded so a stock `~/.isabelle/Isabelle2025-2` can never be touched; the
Windows path handling was verified on a real runner (preunlink-probe.yml).  This is the
one base change the component work needs — no `components.d` hook.

Consequently `isabelle components -u` (above) registers into
`~/.isabelle/Isabelle2025-2-conda-<env>/etc/components`, and the base pre-unlink removes it
along with everything else when the stack goes away.

## The ROOT-pruning rule (Isa-Mini)

Registering a component makes EVERY session in its ROOT visible, and Isabelle fails the
whole structure load if any *sibling* imports an unregistered session (verified:
`*** Bad imports session "X"` makes even `build Y` exit 2).  So a shipped ROOT must
reference only packaged sessions.

Isa-Mini is split accordingly (done): its dev sessions — `Minilang_Translator`,
`Minilang_REPL`, `Minilang_AoA_REPL`, all importing the dev-only, unpackaged `Isa_REPL` —
live in per-subdir ROOTs (`translator/ROOT`, `REPL/ROOT`, `Agent/AoA_REPL/ROOT`).  The
top-level `ROOT` holds only `Minilang` + `Minilang_AoA` (+ `Minilang_Agent_Injector`,
which needs a dev patch to *build* but is inert — its deps are known, so it breaks
nothing).  There is NO top-level `ROOTS`, so those subdir ROOTs are never scanned:
confirmed `isabelle build -n Minilang_AoA` exits 0.

**Packaging rule:** a session package ships the top-level `ROOT` and the theory dirs its
shipped sessions need; it must NOT ship a `ROOTS` file or any dev-only subdir, or the
excluded sessions would be scanned and fail the load.  The other repos are single-session
(or a benign test session) and need no pruning.

## Versioning — independent semver per repo

Rare Isabelle releases but frequent package changes, so each carries its own version, read
at build time from the repo's own source of truth:

  * repos with `pyproject.toml`: its `version` (isabelle-rpc 0.3.1, IsaMini 0.4.0,
    Isabelle_Semantic_Embedding 0.1.0, isabelle-mcp dynamic 0.3.0).
  * the two pure-Isabelle repos (Performant_Isabelle_ML, auto_sledgehammer): a new
    `VERSION` file at the repo root, starting at `0.1.0`.
  * `isabelle-aoa`: its own semver, bumped per stack release.

## The pipeline — one manifest, reuse the existing publish path

`conda/components.toml` lists each package (type, repo path, version source, depends).
The version is read from the repo at build time, so a normal release only edits the repo
version and re-runs; the manifest changes only when adding/removing a component.

Build, then hand everything to release.yml's existing publish path (R2 pull → add →
conda-index → sync → sha256 verify → smoke), unchanged:

  * noarch packages (5 of 6): built once on Linux.
  * `isabelle-semantic-embedding`: **reuse Semantic_Embedding's `wheels.yml`** (its mature
    4-runner native build: Highway/CMake, abi3 3.11–3.14, universal2, MinGW on Windows) to
    produce the per-platform wheels, then wrap each into a conda package.  Do NOT reinvent
    the native build; the same wheels also go to PyPI, so conda and PyPI are one source.
  * Multi-component re-runs must be **idempotent**: a package whose version is already on
    the channel is skipped, not error-ed (unlike the single-package base flow).

## Execution order

1. Base: HOME_USER isolation + pre-unlink cleanup (this is the current base re-release).
2. `isabelle-performant-ml` end-to-end first — root of the DAG; validates the whole path
   (`conda install` it + the base, then `isabelle build -n Performant_Isabelle_ML` finds
   the session via the post-link `components -u`).
3. The rest of the session packages up the DAG, then the Python-carrying ones, then the
   `isabelle-semantic-embedding` native path, then the `isabelle-aoa` metapackage.

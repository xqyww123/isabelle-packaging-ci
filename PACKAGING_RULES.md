# Rules for conda recipes and release workflows

For whoever writes or changes a recipe or a release workflow for https://conda.qiyuan.me (releasing a package: the
SKILL conda-release, `.claude/skills/conda-release/SKILL.md`). Start from the closest existing recipe and workflow and
read every line: most rules are comments next to the code they govern, and the copy carries them.

## Pick the shape

Ask whether conda must pick a different artifact for each platform, or for each Python ABI:

| Shape | When | Example |
|---|---|---|
| `noarch: generic` | one artifact everywhere, no Python package | Performant_Isabelle_ML (native libraries for every platform, picked at run time) |
| `noarch: python` | one artifact everywhere, with a Python package | Isabelle_RPC, Isabelle-MCP |
| per platform, `build.python.version_independent` | compiled per platform, abi3 for every supported Python | Semantic_Embedding |
| per platform and Python | an extension built for one CPython | `conda/third-party/rocksdict` |

Why the one-artifact shape with a Python package is `noarch: python` and not `noarch: generic`: the header comment
of Isabelle_RPC's `conda/recipe.yaml`.

## Dependencies from conda-forge

A PyPI name and the same conda-forge name can be different software. Look up what a name is, and for which platforms:

```sh
curl -fsS https://api.anaconda.org/package/conda-forge/NAME \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['latest_version'],'|',d['summary'])"
curl -fsS https://api.anaconda.org/package/conda-forge/NAME/files \
  | python3 -c "import sys,json;print(sorted({f['attrs']['subdir'] for f in json.load(sys.stdin)}))"
```

Check the transitive dependencies too, under the Python you ship: the solver can reach an old version that installs
and fails at import (the header comment of `conda/third-party/json-spec/recipe.yaml` describes such a case). Then pin
a floor at the version that works, in your own recipe.

## ROOT exposure

Registering a component (`isabelle components -u`) adds every session of its ROOT to the session structure that every
`isabelle build` in the environment reads. A session whose parent or `sessions` names a session that is not registered fails every build there
("Bad parent session", "Bad imports session"). A session whose directory or theory files are not shipped fails the
builds that select it, such as `isabelle build -a`. So a shipped ROOT declares only sessions the package ships whole.
Keep development and test sessions in a ROOT of their own in a subdirectory (Isa-Mini's `Agent/AoA_REPL/ROOT`,
Semantic_Embedding's `Test/ROOT`), and ship no `ROOTS` file that names such a subdirectory.

## Post-link contracts

Reinstalling or upgrading `isabelle` re-links every file under `$PREFIX/isa`, and its pre-unlink deletes the
environment's Isabelle user directory with every component registration in it. Its post-link then re-runs the
post-links of the installed packages that depend on `isabelle` directly, and of no others (`conda/rerun_post_links.py`).
Hence:
- A package whose post-link touches `$PREFIX/isa` or the Isabelle user directory must depend on `isabelle` directly.
- The post-link of a package that depends on `isabelle` directly must be safe to re-run at any time: a re-run restores
  only what installing the package set up (its component registration, its patches), changes nothing else, and
  running it twice has the same effect as running it once.

## Checking a recipe

- `rattler-build build --recipe <recipe> --render-only` builds nothing: it reports schema errors and prints one
  rendered recipe per variant (with `build.python.version_independent`, one, not one per Python).
- Keep `": "` (a colon and a space) out of plain YAML scalars such as test command lines: it makes the whole recipe
  fail to parse, and the error points at the end of the line.
- A local `rattler-build build` with tests runs the package's post-link with your real HOME (the test script gets a
  temporary one) and never runs its pre-unlink: a component's registration stays behind in
  `~/.isabelle/<release>-conda-<env>-<hash>`, the user directory of the deleted test environment. Delete that
  directory, or build in a container.

## Checking a workflow

- Run `actionlint` on every workflow you change. Without shellcheck installed, it reports three things on this
  repository's workflows today that are not yours: the label `macos-13` in `macos-probe.yml` (a runner GitHub no
  longer offers), and `job.workflow_repository` and `job.workflow_sha` in `publish-conda.yml` (GitHub provides them;
  actionlint 1.7.12 does not know them); on the component repositories' workflows it reports nothing. With shellcheck
  installed it also reports about fifty older shellcheck findings here (and a few in Isabelle_RPC and
  Semantic_Embedding); only those in lines you changed are yours.
- To run a `.bat` from Git-Bash, write `MSYS_NO_PATHCONV=1 cmd.exe /c "$bat"` with `bat=$(cygpath -w <file>)`. Without
  `MSYS_NO_PATHCONV=1`, Git-Bash rewrites `/c` into a path and cmd starts interactively without running the batch (the
  log shows a Windows banner and a prompt, and no error). With it, keep the single slash: `//c` would reach cmd as it
  is and fail the same way.
- Run `python3 ~/Current/MLML/contrib/isabelle-packaging-ci/scripts/download-counter.py check <checkout>` on the
  checkout of every repository whose workflows or actions you change. It prints nothing when none of them downloads
  from https://conda.qiyuan.me; each line it prints breaks the rule in "What releasing relies on".

## What releasing relies on

- The release workflow passes `package_name: <package>` to `publish-conda.yml` literally, on a line of its own: the
  SKILL conda-release finds a package's release workflow by that line.
- Steps a release of the package needs beyond the SKILL go into a `RELEASE.md` at the repository's root (in this
  repository: a row in `RELEASE.md`'s table and the file it names).
- A repository that publishes for the first time gets the two R2 secrets and an entry in `PUBLISH_REPOS` of
  `scripts/sweep-old-versions.py`, as `publish-conda.yml`'s header says.
- Everything a workflow downloads from the channel comes from https://conda-ci.qiyuan.me, which serves the same files as
  https://conda.qiyuan.me, the users' address, but whose downloads the download counter does not count. That includes a
  command a workflow reads from a document (replace the address before running it), every tool a workflow runs (pass the
  address explicitly; a tool's default is the users' address), and every command in a `RELEASE.md` that installs package
  files from the channel. https://conda.qiyuan.me appears in a workflow only on comment lines (whose text starts with
  `#`), in `name:` values, and on a line ending with `# the users' address, not a download`. That comment goes only on a
  line that checks text or makes a ranged request (neither is counted), or that defines a variable used only for those
  (`PUBLIC` in `publish-conda.yml`).

## Repackaging a third-party wheel

When conda-forge lacks a platform or a usable version, repackage upstream's wheel, starting from
`conda/third-party/rocksdict/` (compiled, per platform and CPython) or `conda/third-party/json-spec/` (pure Python)
and its release workflow.

## What verification must assert

A green install proves little. Assert:
- the payload, read from the unpacked `.conda` (the archive's own file list shows only its inner archives);
- both hook sets present (the `.sh` hooks in `bin/` and the `.bat` hooks in `Scripts/`), the `.bat` files in CRLF,
  and the path literal in each hook equal to the install location;
- no `lib/pythonX.Y` path in a package that serves more than one Python;
- the component registered, read from `etc/components`;
- every shipped session builds from the installed package;
- the Python half: the import, the console script on PATH, `importlib.metadata.version`, and `pip install <name>`
  answering "already satisfied";
- the pre-unlink unregisters: remove only this package (`conda remove --force`), then read `etc/components` again;
- all of it on `windows-latest` as well as `ubuntu-latest`: a Windows failure is silent.

Before trusting a check, run it once against a broken build (the pre-fix code, or an input made to fail) and see it
fail; find the line it is meant to exercise and confirm the check reaches it.

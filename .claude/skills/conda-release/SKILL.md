---
name: conda-release
description: How to release a package to the conda channel conda.qiyuan.me — find its release workflow, pause the download counter, dry-run and tag or dispatch, watch the run, recover from a failed job, and check after publishing. Read it before you release any package there, or a set of packages for a new Isabelle release. Not for feature packages (the SKILL isabelle-patch-feature), not for writing a recipe or a workflow or changing how one builds (isabelle-packaging-ci's PACKAGING_RULES.md), nor for deleting from the channel (its CHANNEL_OPERATIONS.md).
---

# Releasing a package to conda.qiyuan.me

A package is released by its release workflow: a GitHub Actions workflow in the package's repository that builds
and verifies the package and publishes it through isabelle-packaging-ci's shared `publish-conda.yml`. This SKILL is
the procedure for any package; a package's own extra steps are in its repository's `RELEASE.md` (section 3).

## 1. Conventions

- `<repo>` is the checkout of the package's repository. `OWNER/REPO` is the GitHub repository in
  `git -C <repo> remote get-url origin` (a checkout's directory name can differ from it). `<default branch>` is
  `gh repo view OWNER/REPO --json defaultBranchRef -q .defaultBranchRef.name`. `<workflow file>` is the release
  workflow's file name, such as `release-conda.yml`.
- Git commands use `git -C <repo>`. Every `gh run` and `gh workflow` command passes `-R OWNER/REPO`; `gh repo view`
  and `gh api` name the repository in their argument, as written here.
- A job's log: `gh api repos/OWNER/REPO/actions/jobs/<databaseId>/logs`, with the job's `databaseId` from
  `gh run view <id> -R OWNER/REPO --json jobs` (gh 2.45's `gh run view --log` and `--log-failed` often print nothing,
  and still exit 0).

## 2. Rules

- Release only on the owner's order and only what it names. The version is the one the owner names, unless the
  workflow derives it.
- A published file is permanent: a bad release is fixed forward as section 9 says. Delete nothing from the channel.
- Pushing a `v*` tag publishes.
- Dependencies first: everything the package's recipe requires from the channel must already be there at the
  version it needs (each release's verification installs from the live channel).
- Every `gh workflow run` passes `-f` for every input the workflow's `workflow_dispatch:` declares. If the order, the
  package's `RELEASE.md` and the input's description all leave a value unclear, ask the owner.
- A release may also start a side pipeline that waits at an approval gate (a PyPI publish, …). Leave that gate
  unapproved unless the owner's order says to approve it, and approve it only after the same version is on the
  conda channel.
- Fixing is not releasing: when a step needs a change to a recipe, a workflow or a package's source, report the
  failing step to the owner and go on only when the owner says the fix is in.
- Commits and pushes: `git -C <repo> fetch origin` first. Commit only the files your step changes
  (`git -C <repo> add -- <files>`, then `git -C <repo> commit -m … -- <files>`); if one of them had uncommitted
  edits before you changed it, ask the owner first. Before pushing, if
  `git -C <repo> log --oneline HEAD...origin/<default branch>` lists any commit besides yours, show the list to the
  owner and ask.

## 3. Find the release

- The release workflow:
  `/usr/bin/grep -lE '^ *package_name: <package>$' ~/Current/MLML/contrib/*/.github/workflows/*.yml`
  (`/usr/bin/grep`, because the default grep hides `contrib/`). One file: that is the release workflow, and the
  checkout it sits in is `<repo>`. Nothing: a feature package, released by the SKILL isabelle-patch-feature. Anything
  else: ask the owner.
- If `<repo>` has a `RELEASE.md` at its root, read it first and follow what it says for the package you release. It
  only adds steps; where it contradicts this SKILL, stop and ask the owner.
- The workflow's `on:` says whether a tag push releases it (tag-released, section 5) or only a dispatch
  (dispatch-released, section 6). The workflow also shows where the version comes from: a file it reads (such as
  `VERSION`), an input, or a value it derives. A workflow whose publish job has no `if:` (no condition that skips it
  on a dry run) publishes on every dispatch; the repository's `RELEASE.md` says how to check such a package without
  publishing.

## 4. Before: pause the download counter

Pause the download counter right before anything that downloads package files from the channel (every workflow
run: dispatch, tag push, re-run; and any environment a `RELEASE.md` has you set up outside GitHub's runners):

```sh
(source ~/Current/MLML/secret.sh && python3 ~/Current/MLML/contrib/isabelle-packaging-ci/scripts/download-counter.py pause)
```

A pause ends by itself 6 hours after it was last set. Resume: section 10.

## 5. A tag-released package

1. Bump the version to the one the owner names, unless the default branch already has it. If the repository's
   `CHANGELOG.md` has a `## Unreleased` heading, the same commit turns it into the version's heading, in the form the
   file's earlier headings use (such as `## 0.2.0 (2026-10-03)` or `## 0.7.1`). Commit and push on the default
   branch (section 2).
2. Dry run: `gh workflow run <workflow file> -R OWNER/REPO -f dry_run=true` with every other declared input
   (section 2), started and watched by section 7. Without `--ref` it builds the default branch, so it builds the
   commit of step 1. A dry run is required before every tag: a failed tag run leaves a public tag on a commit that
   never shipped.
3. Tag exactly the tested commit and push the tag; the push is the trigger of section 7:
   `git -C <repo> tag -a v<version> $(gh run view <dry-run id> -R OWNER/REPO --json headSha -q .headSha) -m "Release <version>"`,
   then `git -C <repo> push origin v<version>`. The workflow refuses a tag that disagrees with the version.

## 6. A dispatch

Use this section to release a dispatch-released package, and to start a new run of any package after a failure
(section 9). Start one dispatch and watch it by section 7. Pass `-f dry_run=false` if the workflow declares
`dry_run`, every other declared input (section 2), and the build number section 8 gives. Dispatch a tag-released
package on its tag (`--ref v<version>`), and a dispatch-released package from the default branch.

## 7. Start and watch a run

1. Before the trigger, note the number the trigger will change: for a new run, the newest run id,
   `gh run list -R OWNER/REPO --workflow <workflow file> -L 1 --json databaseId -q '.[0].databaseId // 0'`; for a
   re-run of run `<id>`, its attempt number, `gh api repos/OWNER/REPO/actions/runs/<id> -q .run_attempt`.
2. Trigger: a dispatch (sections 5, 6), a tag push (section 5), `gh run rerun <id> --failed -R OWNER/REPO`, or
   `gh run rerun --job <databaseId> -R OWNER/REPO` with the job's `databaseId` (section 1); pass no run id with
   `--job`, since gh refuses the two together.
3. Repeat the command of step 1 until its number grows. For a new run, check with
   `gh run list -R OWNER/REPO --workflow <workflow file> -L 1 --json databaseId,event,headBranch` that its event and
   branch are the ones you triggered (`workflow_dispatch` on the dispatched ref, or `push` on `v<version>`);
   otherwise stop and ask the owner.
4. `gh run watch <id> -R OWNER/REPO --exit-status`. A release is done when the run is green AND its publish job
   succeeded; a skipped publish job means a dry run, and nothing was published.

## 8. The build number

- The workflow takes it as an input: run `conda search --override-channels -c https://conda.qiyuan.me <package>`
  and pass one above the highest build listed for that version, or 0 if the version is not listed.
- The workflow computes it: pass nothing.
- The workflow neither takes nor computes it (its recipe fixes it): pass nothing; if a file already on the channel
  must be built again, stop and tell the owner.

A new run after a failure keeps the failed run's build number, unless that run's publish job reached "Upload the
packages" or refused a file as already on the channel (section 9, case 1). Then it takes one above that run's
build number, or the number from `conda search` (first bullet) if that is higher. That run's build number is in the
file name on its publish job's `new     :` or `resume  :` line, or in its "ALREADY on the channel" error (the job's
log, section 1; the log's channel listing names other builds too): the digits after the last `_` of the build
string, or the whole build string when it is digits only (as for `isabelle`: `isabelle-2026-0.conda` is build 0).

## 9. When a job fails

Take the first case that fits:
1. The publish job refused a file as "ALREADY on the channel with DIFFERENT content": never re-run. If section 10's
   check shows the release is in fact already published, it is done; otherwise a new run (section 6), its build
   number by section 8.
2. No commit is needed: the cause is a transient failure, a used-up quota, a dependency not yet published, or a
   secret, a token or R2 (report those three to the owner, who fixes them). Once the cause is gone, re-run the run's
   failed jobs by section 7. A re-run keeps the run's commit and build number. If the run can no longer be re-run
   (GitHub no longer offers it, or the re-run fails because the run's artifacts are gone), start it again instead: a
   dry run by dry-running again (section 5, step 2), any other run by a new run (section 6).
3. A commit is needed: report the failing step to the owner (section 2), and once the owner says the fix is in:
   - a dry run: dry-run again (section 5, step 2) and tag the commit that run tested;
   - a tag run whose fix is in the package's own repository and whose publish job did not reach "Upload the
     packages": (1) dry-run the fixed commit (section 5, step 2); (2) cancel every unfinished run of the old tag:
     `gh run list -R OWNER/REPO --branch v<version> --json databaseId,status,workflowName`, then
     `gh run cancel <id> -R OWNER/REPO` for each whose status is not `completed`, and tell the owner which runs you
     cancelled; (3) delete the tag: `git -C <repo> push origin :refs/tags/v<version>` and
     `git -C <repo> tag -d v<version>`; (4) section 5, step 3, keeping the build number;
   - a tag run whose fix is in the package's own repository and whose publish job reached "Upload the packages": a
     new version, which the owner names;
   - otherwise (a tag run whose fix is elsewhere, or a dispatch-released package): a new run (section 6).

## 10. After publishing

- After the last run of everything ordered, check that `conda search` (section 8) lists each new build as the
  newest build of its version. If one is missing, re-run the publish job of any of the release's runs by section 7
  (`--job`); it pulls the channel again and rebuilds the index.
- Tell the owner what you published, and which packages on the channel depend on it directly but were not in the
  order (`depends` in each subdir's `repodata.json`).
- Update isabelle-packaging-ci's `ROLLOUT_STATUS.md`, "Published on https://conda.qiyuan.me", and its "Last updated"
  line, in a commit of its own (section 2).
- Resume the download counter: the command of section 4 with `resume`.

## 11. A new Isabelle release

Release the packages the order lists (if it names a new Isabelle release but no list, ask the owner for the list):
`isabelle` first, by its repository's `RELEASE.md`; then the others, dependencies first. For each, check that:
- its recipe's `isabelle` bound names the new release's series and only that series (moving the bound is porting,
  not releasing: if it still names the old series, stop and tell the owner; never widen it to two series);
- its caps on packages released earlier in the set admit the versions just released (move a cap that excludes one
  before the dry run, in a commit the owner approves).

## References

The package's `RELEASE.md` (section 3); isabelle-packaging-ci's `ROLLOUT_STATUS.md`; the SKILL isabelle-patch-feature.

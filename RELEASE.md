# Releasing Isabelle to conda.qiyuan.me

The `isabelle` package is the official Isabelle release with no patches (`PACKAGING_DESIGN.md`
§11). Patches ship as separate feature packages, released from the patch tool repository
`xqyww123/isabelle_patch_control` (its `RELEASE.md`).

Below, `<R>` is the Isabelle release you package, for example `Isabelle2026`.

Pause the download counter while you release (`RELEASE_CHECKLIST.md`, "The channel host").

## 0. Register the release (once per Isabelle release)

Skip this if `releases/<R>/` exists. Otherwise create, commit and push:

- `releases/<R>/SHA256SUMS`: exactly five lines, `<sha256>  <file>`, for `<R>_linux.tar.gz`,
  `<R>_linux_arm.tar.gz`, `<R>_macos.tar.gz`, `<R>_macos_arm.tar.gz` and `<R>.exe`, copied from
  `https://isabelle.in.tum.de/website-<R>/dist/`.
- `releases/<R>/ISABELLE_ID`: the first 12 hex digits of tag `<R>`'s changeset in
  `https://isabelle.in.tum.de/repos/isabelle/raw-tags`. Never copy it from a bundle: the CI
  checks the bundles against it.

Then check the new release without publishing:

```bash
gh workflow run ci.yml --repo xqyww123/isabelle-packaging-ci -f release=<R>
```

If `scripts/pack.sh` stops at an anchor ("upstream layout changed") or `scripts/check_pristine.py`
reports a difference, the new release's tree differs from what the packaging expects: adapt that
step before going on.

## 1. Pick the build number

```bash
conda search --override-channels -c https://conda.qiyuan.me isabelle
```

The build number `<N>` is one higher than the highest build listed for `<R>`'s conda version
(`2026` for `Isabelle2026`, `2025.2` for `Isabelle2025-2`), or `0` if that version is not
listed.

## 2. Rehearse the feature packages (skip if no feature package exists for `<R>`)

Build the `isabelle` packages with build number `<N>`, without publishing:

```bash
gh workflow run ci.yml --repo xqyww123/isabelle-packaging-ci -f release=<R> -f build_number=<N>
```

When that run is green, dispatch the patch tool repository's `release-features.yml` with
`isabelle_build=<N>`, `isabelle_from=run:<id of that run>` and `publish=false`; its `RELEASE.md`,
"The batch release workflow", explains the other inputs. Go on to step 3 only when the
rehearsal is green. If either run fails, nothing is published: fix the cause and repeat this
step with the same `<N>`. The run's packages are kept for 7 days; after that, dispatch `ci.yml`
again.

## 3. Release

```bash
gh workflow run release.yml --repo xqyww123/isabelle-packaging-ci -f release=<R> -f build_number=<N>
```

The run has three jobs: `build`, `publish`, and `smoke`, which installs the published packages
from the channel on clean machines. Wait until all three are green. A second dispatch waits
until the first run has finished.

If a job fails:

- `build`: nothing is published. If only a GUI check failed with "a release needs a GUI
  verdict", the warning above that error says why Claude did not judge it:
  - a used-up quota: press **Re-run failed jobs** after it resets;
  - "Not logged in" or an expired token: renew the `CLAUDE_CODE_OAUTH_TOKEN` secret
    (`claude setup-token`), then press **Re-run failed jobs**;
  - "could not tell whether only the failing lemma is flagged": press **Re-run failed jobs**
    once; if it says so again, look at the uploaded screenshot and fix whatever hides the marker.

  Otherwise fix the cause and dispatch again with the same `<N>`.
- `publish` or `smoke`, for a cause outside the workflow files (a secret, R2, a transient
  failure): fix it and press **Re-run failed jobs** on the same run, within 7 days. The
  `publish` job accepts a file that is already on the channel with the same bytes, so the
  re-run resumes.
- Anything else: the fix is in a workflow file (a re-run keeps the workflow files of its first
  attempt, `RELEASE_CHECKLIST.md` §9 item 2), the 7 days have passed, or the `publish` job
  refused a file that is already on the channel. Start again from step 2: with the same `<N>`
  if the `publish` job stopped before its "Upload the packages" step, otherwise with `<N>+1`,
  because a rebuilt package never has the same bytes.

A defect found after publishing is also fixed by releasing `<N>+1`; deleting a published build
is exceptional (`RELEASE_CHECKLIST.md`, "Deleting from the channel").

## 4. After publishing

- Follow `RELEASE_CHECKLIST.md` §11: read the `publish` job's audit log, and update
  `ROLLOUT_STATUS.md`.
- If feature packages exist for `<R>`: release them against build `<N>` (`isabelle_build=<N>`,
  `isabelle_from=channel`), as step 8 of section 3.4 of the patch tool repository's SKILL
  `isabelle-patch-feature` (`.claude/skills/isabelle-patch-feature/SKILL.md`) says.
- If `<R>` was not on the channel before (a new Isabelle release, not only a new build): each
  package in the order of `RELEASE_CHECKLIST.md` §9 item 1 accepts only one Isabelle version
  (for example `isabelle >=2025.2,<2025.3`), so each needs a release that accepts `<R>`, in that
  order; `isabelle-ai` goes last (§9 item 4).

Why the CI is built the way it is: `PACKAGING_DESIGN.md`.

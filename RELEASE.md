# Releasing Isabelle to conda.qiyuan.me

> **Not usable yet (2026-10-31).** This procedure is for the CI after its planned upgrade: it
> builds the official Isabelle release with no patches, and `release.yml` and `ci.yml` take the
> Isabelle release as an input `release` (an addition the owner made on 2026-10-31 to decision
> 12, which is written for Isabelle2025-2 only). The upgrade has landed when `release.yml` has
> that input. Until then no `isabelle` build is published, by the owner's ruling of 2026-10-23
> (the patch tool repository's `ai-artifacts/ISABELLE_PATCH_CONTROL_PLAN.md`, §0 item 11;
> decision 12 there lists what the upgrade must do).

The `isabelle` package is the official Isabelle release with no patches. Patches ship as
separate feature packages, released from the patch tool repository
`xqyww123/isabelle_patch_control` (its `RELEASE.md`).

Below, `<R>` is the Isabelle release you package, for example `Isabelle2026`.

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
from the channel on clean machines. Wait until all three are green.

If a job fails:

- `build`: nothing is published. Fix the cause and dispatch again with the same `<N>`.
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
  `isabelle_from=channel`), as step 6 of "Releasing a feature" in the patch tool repository's
  `RELEASE.md` says.
- If `<R>` was not on the channel before (a new Isabelle release, not only a new build): each
  package in the order of `RELEASE_CHECKLIST.md` §9 item 1 accepts only one Isabelle version
  (for example `isabelle >=2025.2,<2025.3`), so each needs a release that accepts `<R>`, in that
  order; `isabelle-ai` goes last (§9 item 4).

Why the CI is built the way it is: `PACKAGING_DESIGN.md`.
